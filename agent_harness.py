#!/usr/bin/env python3
"""
agent_harness.py - Local event bridge between autonomous coding agents and the
Agent Office Godot dashboard.

It hosts a WebSocket server (default ws://127.0.0.1:8765), keeps an in-memory
registry of agents and broadcasts lifecycle events as JSON to every connected
client. Godot (or any client) can send commands back, e.g. DISPATCH_PROMPT.

Two runner modes:

  --mode mock   Simulated agents. An "ambient" loop makes idle agents pick up
                fake tasks, chat at the coffee machine and hold meetings, and
                DISPATCH_PROMPT plays a scripted THINKING -> WORKING -> IDLE run.

  --mode cli    Real processes. Each agent can be bound to a shell command with
                --agent-cmd agent_id='command ...'. A DISPATCH_PROMPT launches
                the command (prompt appended as the last argument, substituted
                for {prompt}, or written to stdin), streams stdout/stderr lines
                as LOG_ENTRY events with ANSI colour codes preserved, and maps
                process start/exit to WORKING/IDLE. Agents without a command fall
                back to the mock runner.

Examples:
  python3 agent_harness.py
  python3 agent_harness.py --mode cli \
      --agent-cmd coder_agent='claude -p --output-format text' \
      --agent-cmd qa_agent="bash -c 'pytest -q --color=yes'" --prompt-mode none

Requires: Python 3.10+, websockets >= 13 (new asyncio API; falls back to the
legacy API on websockets 12).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import random
import re
import shlex
import signal
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Iterable

try:  # websockets >= 13: new asyncio implementation
    from websockets.asyncio.server import ServerConnection, broadcast, serve

    _WS_LEGACY = False
except ImportError:  # pragma: no cover - websockets 12 fallback
    from websockets import broadcast  # type: ignore[no-redef]
    from websockets.server import WebSocketServerProtocol as ServerConnection  # type: ignore
    from websockets.server import serve  # type: ignore[no-redef]

    _WS_LEGACY = True

from websockets.exceptions import ConnectionClosed

__version__ = "0.1.0"
log = logging.getLogger("agent_harness")

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\)")
IDLE_SPOTS = ("Coffee_Machine", "Water_Cooler")
MEETING_TARGET = "Meeting_Room"


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def now_ms() -> int:
    return int(time.time() * 1000)


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
@dataclass
class Agent:
    """One agent in the office. Mutated only through Hub.emit()."""

    agent_id: str
    name: str
    desk: str
    color: str
    role: str = ""
    state: str = "IDLE"
    target: str | None = None
    text: str = ""
    logs: deque[str] = field(default_factory=lambda: deque(maxlen=200))
    lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False)
    queue: asyncio.Queue[str] = field(default_factory=asyncio.Queue, repr=False)
    ambient_task: asyncio.Task[None] | None = field(default=None, repr=False)

    def to_json(self, include_logs: bool = True) -> dict[str, Any]:
        data: dict[str, Any] = {
            "agent_id": self.agent_id,
            "name": self.name,
            "role": self.role,
            "desk": self.desk,
            "color": self.color,
            "state": self.state,
            "target": self.target,
            "text": self.text,
            "busy": self.lock.locked(),
            "queued": self.queue.qsize(),
        }
        if include_logs:
            data["logs"] = list(self.logs)
        return data


DEFAULT_AGENTS: tuple[dict[str, str], ...] = (
    {"agent_id": "coder_agent", "name": "Coder", "role": "Implementation", "desk": "Desk_Coder", "color": "#4fc3f7"},
    {"agent_id": "qa_agent", "name": "QA", "role": "Testing", "desk": "Desk_QA", "color": "#81c784"},
    {"agent_id": "architect_agent", "name": "Architect", "role": "Design", "desk": "Desk_Architect", "color": "#ffb74d"},
)


class Hub:
    """Owns the registry and the set of connected clients."""

    def __init__(self, mode: str) -> None:
        self.mode = mode
        self.agents: dict[str, Agent] = {}
        self.clients: set[ServerConnection] = set()
        self.dispatcher: Callable[[str, str], Awaitable[None]] | None = None

    # -- registry ----------------------------------------------------------
    def register(self, agent_id: str, name: str, desk: str, color: str, role: str = "") -> Agent:
        agent = Agent(agent_id=agent_id, name=name, desk=desk, color=color, role=role)
        self.agents[agent_id] = agent
        return agent

    def snapshot(self) -> dict[str, Any]:
        return {
            "type": "SNAPSHOT",
            "server": {"name": "agent_harness", "version": __version__, "mode": self.mode},
            "agents": [a.to_json() for a in self.agents.values()],
            "ts": now_ms(),
        }

    # -- outbound ----------------------------------------------------------
    def emit(self, event: dict[str, Any]) -> None:
        """Apply an event to the registry, then broadcast it to all clients."""
        etype = event.get("type")
        if etype == "STATE_CHANGE":
            agent = self.agents.get(event["agent_id"])
            if agent:
                agent.state = event["state"]
                agent.text = event.get("text", "")
                if "target" in event:
                    agent.target = event["target"]
        elif etype == "LOG_ENTRY":
            agent = self.agents.get(event["agent_id"])
            if agent:
                agent.logs.append(event["log"])
        elif etype == "COLLABORATE":
            for agent_id in event.get("agents", []):
                agent = self.agents.get(agent_id)
                if agent:
                    agent.state = "COLLAB"
                    agent.target = event.get("target", MEETING_TARGET)
                    agent.text = event.get("text", "")
        event.setdefault("ts", now_ms())
        payload = json.dumps(event, ensure_ascii=False)
        log.debug("broadcast %s", payload)
        if self.clients:
            broadcast(self.clients, payload)

    # convenience wrappers ---------------------------------------------------
    def state(self, agent_id: str, state: str, text: str = "", target: str | None = None) -> None:
        event: dict[str, Any] = {"type": "STATE_CHANGE", "agent_id": agent_id, "state": state}
        if target is not None:
            event["target"] = target
        if text:
            event["text"] = text
        self.emit(event)

    def log_line(self, agent_id: str, line: str, stream: str = "stdout") -> None:
        self.emit({"type": "LOG_ENTRY", "agent_id": agent_id, "log": line, "stream": stream})

    def collaborate(self, agent_ids: list[str], target: str = MEETING_TARGET, text: str = "") -> None:
        event: dict[str, Any] = {"type": "COLLABORATE", "agents": agent_ids, "target": target}
        if text:
            event["text"] = text
        self.emit(event)

    # -- connection handling ----------------------------------------------
    async def handler(self, ws: ServerConnection, *_legacy_path: Any) -> None:
        peer = getattr(ws, "remote_address", None)
        self.clients.add(ws)
        log.info("client connected %s (%d total)", peer, len(self.clients))
        try:
            await ws.send(json.dumps(self.snapshot(), ensure_ascii=False))
            async for raw in ws:
                await self.on_message(ws, raw)
        except ConnectionClosed as exc:
            log.info("client %s closed: %s", peer, exc)
        finally:
            self.clients.discard(ws)
            log.info("client disconnected %s (%d remaining)", peer, len(self.clients))

    async def reply(self, ws: ServerConnection, payload: dict[str, Any]) -> None:
        try:
            await ws.send(json.dumps(payload, ensure_ascii=False))
        except ConnectionClosed:
            pass

    async def on_message(self, ws: ServerConnection, raw: str | bytes) -> None:
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        try:
            msg = json.loads(raw)
            if not isinstance(msg, dict):
                raise ValueError("expected a JSON object")
        except ValueError as exc:
            await self.reply(ws, {"type": "ERROR", "message": f"bad JSON: {exc}"})
            return

        action = msg.get("action")
        if action == "DISPATCH_PROMPT":
            agent_id = str(msg.get("agent_id", ""))
            prompt = str(msg.get("prompt", "")).strip()
            if agent_id not in self.agents:
                await self.reply(ws, {"type": "ERROR", "action": action, "message": f"unknown agent '{agent_id}'"})
                return
            if not prompt:
                await self.reply(ws, {"type": "ERROR", "action": action, "agent_id": agent_id, "message": "empty prompt"})
                return
            log.info("DISPATCH_PROMPT -> %s: %s", agent_id, prompt)
            agent = self.agents[agent_id]
            # A user prompt pre-empts any ambient (simulated) activity.
            if agent.ambient_task and not agent.ambient_task.done():
                agent.ambient_task.cancel()
            await agent.queue.put(prompt)
            await self.reply(ws, {"type": "ACK", "action": action, "agent_id": agent_id,
                                  "prompt": prompt, "queued": agent.queue.qsize()})
        elif action in ("REQUEST_SNAPSHOT", "GET_REGISTRY"):
            await self.reply(ws, self.snapshot())
        elif action == "PING":
            await self.reply(ws, {"type": "PONG", "ts": now_ms()})
        else:
            await self.reply(ws, {"type": "ERROR", "message": f"unknown action '{action}'"})


# ---------------------------------------------------------------------------
# Runners
# ---------------------------------------------------------------------------
class MockRunner:
    """Scripted, fake agent work. Also drives the ambient office simulation."""

    def __init__(self, hub: Hub, speed: float = 1.0) -> None:
        self.hub = hub
        self.speed = max(0.05, speed)

    async def sleep(self, seconds: float) -> None:
        await asyncio.sleep(seconds / self.speed)

    async def run_prompt(self, agent: Agent, prompt: str) -> None:
        hub, aid = self.hub, agent.agent_id
        short = prompt if len(prompt) <= 40 else prompt[:37] + "..."
        files = re.findall(r"[\w./-]+\.(?:py|ts|js|go|rs|gd|md|json)", prompt) or ["main.py"]
        target_file = files[0]

        hub.log_line(aid, f"\x1b[1;36m> {prompt}\x1b[0m")
        hub.state(aid, "THINKING", text=f"Reading: {short}")
        await self.sleep(1.5)
        hub.log_line(aid, "\x1b[2mLoading repository context (42 files)...\x1b[0m")
        hub.state(aid, "THINKING", text="Analyzing AST...")
        await self.sleep(1.5)
        hub.state(aid, "WORKING", target=agent.desk, text=f"Editing {target_file}")
        await self.sleep(2.0)
        hub.log_line(aid, f"\x1b[33mEdit\x1b[0m {target_file}: +12 -4")
        await self.sleep(1.2)
        hub.log_line(aid, "\x1b[2m$ pytest -q\x1b[0m")
        await self.sleep(1.2)
        passed = random.randint(8, 24)
        hub.log_line(aid, f"\x1b[32mRunning tests: {passed} passed, 0 failed.\x1b[0m")
        await self.sleep(0.8)
        hub.log_line(aid, f"\x1b[1;32m\u2714 Done:\x1b[0m {prompt}")
        hub.state(aid, "IDLE", target=random.choice(IDLE_SPOTS), text="Done! Coffee time.")

    # -- ambient simulation --------------------------------------------------
    SOLO_TASKS: dict[str, list[tuple[str, str]]] = {
        "coder_agent": [("Analyzing AST...", "Editing main.py"), ("Reading stack trace...", "Patching auth.py"),
                        ("Planning refactor...", "Refactoring utils.py")],
        "qa_agent": [("Reviewing diff...", "Writing test_auth.py"), ("Triaging flaky test...", "Running pytest")],
        "architect_agent": [("Weighing trade-offs...", "Drafting ADR-007.md"),
                            ("Mapping dependencies...", "Updating diagram.md")],
    }
    CHATTER = ["Anyone seen the CI logs?", "This coffee is compiling...", "Need a refactor break.",
               "Ship it!", "Who broke main?", "Tabs or spaces?"]

    async def ambient_solo(self, agent: Agent) -> None:
        hub, aid = self.hub, agent.agent_id
        think, work = random.choice(self.SOLO_TASKS.get(aid, [("Thinking...", "Working")]))
        try:
            hub.state(aid, "THINKING", text=think)
            await self.sleep(2.0)
            hub.state(aid, "WORKING", target=agent.desk, text=work)
            await self.sleep(3.0)
            for line in self._fake_logs(aid, work):
                hub.log_line(aid, line)
                await self.sleep(random.uniform(0.6, 1.4))
            hub.state(aid, "IDLE", target=random.choice(IDLE_SPOTS),
                      text=random.choice(self.CHATTER) if random.random() < 0.6 else "")
        except asyncio.CancelledError:
            hub.log_line(aid, "\x1b[2m(ambient task interrupted by user prompt)\x1b[0m")
            raise

    async def ambient_collab(self, agents: list[Agent]) -> None:
        hub = self.hub
        ids = [a.agent_id for a in agents]
        names = " & ".join(a.name for a in agents)
        hub.collaborate(ids, MEETING_TARGET, text=f"Sync: {names}")
        await self.sleep(4.0)
        for a in agents:
            hub.log_line(a.agent_id, f"\x1b[35m[meeting]\x1b[0m Discussing API contract with {names}")
        for a in agents:
            hub.state(a.agent_id, "COLLAB", text=random.choice(["Agreed.", "What about edge cases?",
                                                                 "Let's split the PR.", "I'll write the tests."]))
            await self.sleep(1.5)
        await self.sleep(2.0)
        for a in agents:
            hub.state(a.agent_id, "IDLE", target=random.choice(IDLE_SPOTS), text="Good meeting.")

    def _fake_logs(self, agent_id: str, work: str) -> list[str]:
        if agent_id == "qa_agent":
            n = random.randint(10, 30)
            fails = random.choice([0, 0, 0, 1])
            colour = "32" if fails == 0 else "31"
            return ["\x1b[2m$ pytest -q --color=yes\x1b[0m",
                    f"\x1b[{colour}mRunning tests: {n - fails} passed, {fails} failed.\x1b[0m"]
        if agent_id == "architect_agent":
            return [f"\x1b[34m[design]\x1b[0m {work}", "\x1b[2mUpdated 3 sections, 1 diagram\x1b[0m"]
        return [f"\x1b[33m{work}\x1b[0m", "\x1b[2m$ ruff check .\x1b[0m", "\x1b[32mAll checks passed!\x1b[0m"]


class CliRunner:
    """Wraps a real CLI process per agent and streams its output as events."""

    def __init__(self, hub: Hub, commands: dict[str, str], prompt_mode: str = "arg",
                 cwd: str | None = None, timeout: float = 0.0) -> None:
        self.hub = hub
        self.commands = commands
        self.prompt_mode = prompt_mode
        self.cwd = cwd
        self.timeout = timeout
        self.procs: set[asyncio.subprocess.Process] = set()

    def handles(self, agent_id: str) -> bool:
        return agent_id in self.commands

    def build_argv(self, agent_id: str, prompt: str) -> list[str]:
        template = self.commands[agent_id]
        tokens = shlex.split(template)
        if "{prompt}" in template:
            return [t.replace("{prompt}", prompt) for t in tokens]
        if self.prompt_mode == "arg" and prompt:
            return tokens + [prompt]
        return tokens

    async def run_prompt(self, agent: Agent, prompt: str) -> None:
        hub, aid = self.hub, agent.agent_id
        argv = self.build_argv(aid, prompt)
        hub.log_line(aid, f"\x1b[1;36m> {prompt}\x1b[0m")
        hub.log_line(aid, "\x1b[2m$ " + " ".join(shlex.quote(a) for a in argv) + "\x1b[0m")
        hub.state(aid, "THINKING", text=f"Starting {os.path.basename(argv[0])}...")
        env = {**os.environ, "FORCE_COLOR": "1", "CLICOLOR_FORCE": "1", "PYTHONUNBUFFERED": "1"}
        use_stdin = self.prompt_mode == "stdin"
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdin=asyncio.subprocess.PIPE if use_stdin else asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.cwd,
                env=env,
                limit=1 << 20,
                start_new_session=True,  # own process group so we can kill children too
            )
        except (OSError, ValueError) as exc:
            hub.log_line(aid, f"\x1b[31mFailed to start: {exc}\x1b[0m", stream="stderr")
            hub.state(aid, "IDLE", target=random.choice(IDLE_SPOTS), text="Failed to start")
            return

        self.procs.add(proc)
        hub.state(aid, "WORKING", target=agent.desk, text=f"Running {os.path.basename(argv[0])} (pid {proc.pid})")
        if use_stdin and proc.stdin:
            proc.stdin.write(prompt.encode() + b"\n")
            await proc.stdin.drain()
            proc.stdin.close()

        last_bubble = 0.0

        async def pump(stream: asyncio.StreamReader | None, name: str) -> None:
            nonlocal last_bubble
            if stream is None:
                return
            while True:
                raw = await stream.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                hub.log_line(aid, line, stream=name)
                plain = strip_ansi(line).strip()
                # Throttled speech bubble showing the latest output line.
                if plain and time.monotonic() - last_bubble > 3.0:
                    last_bubble = time.monotonic()
                    hub.state(aid, "WORKING", text=plain[:60])

        try:
            pumps = asyncio.gather(pump(proc.stdout, "stdout"), pump(proc.stderr, "stderr"))
            if self.timeout > 0:
                await asyncio.wait_for(pumps, self.timeout)
            else:
                await pumps
            code = await proc.wait()
        except asyncio.TimeoutError:
            hub.log_line(aid, f"\x1b[31mTimed out after {self.timeout:.0f}s, terminating\x1b[0m", stream="stderr")
            await self.terminate(proc)
            code = proc.returncode if proc.returncode is not None else -1
        except asyncio.CancelledError:
            await self.terminate(proc)
            raise
        finally:
            self.procs.discard(proc)

        ok = code == 0
        colour = "32" if ok else "31"
        hub.log_line(aid, f"\x1b[{colour}mProcess exited with code {code}\x1b[0m")
        hub.state(aid, "IDLE", target=random.choice(IDLE_SPOTS),
                  text="Done!" if ok else f"Failed (exit {code})")

    async def terminate(self, proc: asyncio.subprocess.Process) -> None:
        if proc.returncode is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            await asyncio.wait_for(proc.wait(), 3.0)
        except (ProcessLookupError, PermissionError):
            pass
        except asyncio.TimeoutError:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await proc.wait()

    async def shutdown(self) -> None:
        await asyncio.gather(*(self.terminate(p) for p in list(self.procs)), return_exceptions=True)


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
class Harness:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.hub = Hub(args.mode)
        for spec in DEFAULT_AGENTS:
            self.hub.register(**spec)
        self.mock = MockRunner(self.hub, speed=args.speed)
        commands = dict(args.agent_cmd or [])
        unknown = set(commands) - set(self.hub.agents)
        if unknown:
            raise SystemExit(f"--agent-cmd refers to unknown agents: {', '.join(sorted(unknown))}")
        self.cli = CliRunner(self.hub, commands, args.prompt_mode, args.cwd, args.cmd_timeout) \
            if args.mode == "cli" else None
        if self.cli is not None and not commands:
            log.warning("--mode cli without any --agent-cmd: every agent uses the mock runner")
        self.tasks: list[asyncio.Task[Any]] = []
        self.ambient_tasks: set[asyncio.Task[None]] = set()

    async def worker(self, agent: Agent) -> None:
        """Serially executes prompts queued for one agent."""
        while True:
            prompt = await agent.queue.get()
            async with agent.lock:
                runner = self.cli if (self.cli and self.cli.handles(agent.agent_id)) else self.mock
                try:
                    await runner.run_prompt(agent, prompt)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:  # keep the worker alive whatever happens
                    log.exception("runner failed for %s", agent.agent_id)
                    self.hub.log_line(agent.agent_id, f"\x1b[31mRunner error: {exc}\x1b[0m", stream="stderr")
                    self.hub.state(agent.agent_id, "IDLE", text="Runner error")
                finally:
                    agent.queue.task_done()

    def _free_agents(self) -> list[Agent]:
        return [a for a in self.hub.agents.values() if not a.lock.locked() and a.queue.empty()]

    async def _run_ambient(self, agents: list[Agent], coro: Awaitable[None]) -> None:
        for a in agents:  # all free (checked synchronously), so acquire() won't suspend
            await a.lock.acquire()
        try:
            await coro
        except asyncio.CancelledError:
            pass
        finally:
            for a in agents:
                a.ambient_task = None
                a.lock.release()

    async def ambient_loop(self) -> None:
        """Keeps the office lively by giving idle agents things to do."""
        await asyncio.sleep(1.0)
        while True:
            free = self._free_agents()
            if self.args.mode == "cli" and self.cli:  # don't fake activity for real CLI agents
                free = [a for a in free if not self.cli.handles(a.agent_id)]
            if free:
                if len(free) >= 2 and random.random() < 0.3:
                    group = random.sample(free, 2)
                    task = asyncio.create_task(self._run_ambient(group, self.mock.ambient_collab(group)))
                else:
                    group = [random.choice(free)]
                    task = asyncio.create_task(self._run_ambient(group, self.mock.ambient_solo(group[0])))
                for a in group:
                    a.ambient_task = task
                self.ambient_tasks.add(task)
                task.add_done_callback(self.ambient_tasks.discard)
            await asyncio.sleep(random.uniform(0.6, 1.4) * self.args.tick / self.args.speed)

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        stop = loop.create_future()

        def request_stop(signame: str) -> None:
            if not stop.done():
                log.info("received %s, shutting down...", signame)
                stop.set_result(None)

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, request_stop, sig.name)
            except NotImplementedError:  # Windows
                signal.signal(sig, lambda *_: loop.call_soon_threadsafe(request_stop, "signal"))

        for agent in self.hub.agents.values():
            self.tasks.append(asyncio.create_task(self.worker(agent), name=f"worker-{agent.agent_id}"))
        if self.args.mode == "mock" and not self.args.no_ambient:
            self.tasks.append(asyncio.create_task(self.ambient_loop(), name="ambient"))
        elif self.args.mode == "cli" and self.args.ambient:
            self.tasks.append(asyncio.create_task(self.ambient_loop(), name="ambient"))

        async with serve(self.hub.handler, self.args.host, self.args.port, max_size=2 ** 22) as server:
            log.info("agent_harness %s (%s mode, websockets %s API) listening on ws://%s:%d",
                     __version__, self.args.mode, "legacy" if _WS_LEGACY else "asyncio",
                     self.args.host, self.args.port)
            log.info("agents: %s", ", ".join(self.hub.agents))
            await stop
            server.close()
        # Cleanup
        pending = [*self.tasks, *self.ambient_tasks]
        for t in pending:
            t.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        if self.cli:
            await self.cli.shutdown()
        log.info("bye")


def parse_agent_cmd(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected agent_id='command ...'")
    agent_id, cmd = value.split("=", 1)
    agent_id, cmd = agent_id.strip(), cmd.strip()
    if not agent_id or not cmd:
        raise argparse.ArgumentTypeError("expected agent_id='command ...'")
    shlex.split(cmd)  # validate quoting early
    return agent_id, cmd


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Agent Office WebSocket event bridge",
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--mode", choices=("mock", "cli"), default="mock")
    p.add_argument("--agent-cmd", action="append", type=parse_agent_cmd, metavar="AGENT_ID='CMD'",
                   help="bind a shell command to an agent (cli mode); repeatable. Use {prompt} as a placeholder")
    p.add_argument("--prompt-mode", choices=("arg", "stdin", "none"), default="arg",
                   help="how the prompt reaches the command when {prompt} is not used (default: arg)")
    p.add_argument("--cwd", default=None, help="working directory for CLI commands")
    p.add_argument("--cmd-timeout", type=float, default=0.0, help="kill CLI runs after N seconds (0 = never)")
    p.add_argument("--tick", type=float, default=5.0, help="mean seconds between ambient events")
    p.add_argument("--speed", type=float, default=1.0, help="mock time multiplier (2 = twice as fast)")
    p.add_argument("--no-ambient", action="store_true", help="mock mode: disable ambient simulation")
    p.add_argument("--ambient", action="store_true", help="cli mode: simulate agents that have no command")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s", datefmt="%H:%M:%S")
    try:
        asyncio.run(Harness(args).run())
    except OSError as exc:
        log.error("could not start server: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
