#!/usr/bin/env python3
"""
agent_harness.py - Local event bridge between autonomous coding agents and the
Agent Office Godot dashboard.

It hosts a WebSocket server (default ws://127.0.0.1:8765), keeps an in-memory
registry of agents and broadcasts lifecycle events as JSON to every connected
client. Godot (or any client) can send commands back, e.g. DISPATCH_PROMPT.

Two runner modes:

  --mode mock   Simulated agents. An ambient director keeps them mostly at
                their desks in long work sessions (logs trickle in), with the
                odd break-room visit and an occasional meeting; pace is set by
                --tempo calm|normal|busy (default calm). DISPATCH_PROMPT plays a
                scripted THINKING -> WORKING -> IDLE run straight away.

  --mode cli    Real processes. Each agent can be bound to a shell command with
                --agent-cmd agent_id='command ...'. A DISPATCH_PROMPT launches
                the command (prompt appended as the last argument, substituted
                for {prompt}, or written to stdin), streams stdout/stderr lines
                as LOG_ENTRY events with ANSI colour codes preserved, and maps
                process start/exit to WORKING/IDLE. Agents without a command fall
                back to the mock runner.

  --mode live   No fake work: agents only work on real status reports (the
                MCP tool below) and on CLI runs bound with --agent-cmd. Agents
                that aren't busy with a real report live an idle office life
                (coffee, water, vending machine, sofa, foosball, small talk,
                phone) unless --no-ambient is given; screens stay dark and no
                log lines are invented, so real work stands out.

Live status over MCP: unless --no-mcp is given, office_mcp.py serves a remote
MCP connector (Streamable HTTP) at http://127.0.0.1:8766/mcp with one tool,
report_office_status(agent, action, detail). Every request needs
"Authorization: Bearer <token>" (env OFFICE_MCP_TOKEN, or the token generated
into .office_token on first run). In mock and live mode an agent that reports
for real is left alone by the simulation for --live-hold seconds (default
600) or until it reports "finish".

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
import secrets
import unicodedata
import json
import logging
from office_vault import (
    COS_AGENT_ID,
    OfficeVault,
    format_vault_system_addon,
    validate_name as vault_validate_name,
)
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
from pathlib import Path

try:  # websockets >= 13: new asyncio implementation
    from websockets.asyncio.server import ServerConnection, broadcast, serve

    _WS_LEGACY = False
except ImportError:  # pragma: no cover - websockets 12 fallback
    from websockets import broadcast  # type: ignore[no-redef]
    from websockets.server import WebSocketServerProtocol as ServerConnection  # type: ignore
    from websockets.server import serve  # type: ignore[no-redef]

    _WS_LEGACY = True

from websockets.exceptions import ConnectionClosed

__version__ = "0.2.0"
log = logging.getLogger("agent_harness")

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\)")
REC_SPOTS = ("Yoga_Mat_1", "Yoga_Mat_2", "Meditation_Cushion_1", "Meditation_Cushion_2")
SHARED_BREAK_SPOTS = ("Coffee_Machine", "Water_Cooler", "Vending_Machine", "Sofa_1", "Sofa_2") + REC_SPOTS
SHARED_CHAT_SPOTS = ("Chat_Break", "Chat_Corridor")  # + Chat_<room id> per team room
IDLE_SPOTS = SHARED_BREAK_SPOTS  # backwards-compatible name
MEETING_TARGET = "Meeting_Room"
FOOSBALL_SPOTS = ("Foosball_1", "Foosball_2", "Foosball_3", "Foosball_4")
CANTEEN_COUNTER = "Canteen_Counter"
CANTEEN_SEATS = ("Canteen_Seat_1", "Canteen_Seat_2", "Canteen_Seat_3", "Canteen_Seat_4",
                 "Canteen_Seat_5", "Canteen_Seat_6")
CANTEEN_FOOD = ("pizza", "a salad", "a burger", "a fruit bowl", "sushi", "noodles",
                "a sandwich", "fish and chips", "a burrito", "soup and bread")
SHARED_GROUP = "shared"
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
DEFAULT_INBOX_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".office_inbox.json")
DEFAULT_CLAUDE_SESSIONS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".office_claude")
DEFAULT_CLAUDE_SESSIONS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".office_claude_sessions.json")

# Read-only tools auto-allowed for office Claude runs (no permission prompts).
DEFAULT_CLAUDE_ALLOWED_TOOLS: tuple[str, ...] = (
    "Read",
    "Grep",
    "Glob",
    "Bash(git status*)",
    "Bash(git log*)",
    "Bash(git diff*)",
    "Bash(git show*)",
    "Bash(git branch*)",
    "Bash(gh pr list*)",
    "Bash(gh pr view*)",
    "Bash(gh issue list*)",
)

INBOX_CAP = 20          # pending messages per agent
INBOX_HISTORY = 30      # delivered messages remembered per agent (for replies)
MAX_PROMPT = 2000
MAX_REPLY = 2000
MAX_REPLY_LINES = 40
DEFAULT_OFFICE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "office.json")
PALETTE = ("#4fc3f7", "#81c784", "#ffb74d", "#f06292", "#ba68c8", "#4db6ac", "#ffd54f", "#7986cb",
           "#a1887f", "#e57373", "#64b5f6", "#aed581", "#ff8a65", "#9575cd", "#4dd0e1", "#dce775",
           "#f48fb1", "#90a4ae", "#ffcc80", "#80cbc4", "#b39ddb", "#c5e1a5", "#ef9a9a", "#80deea")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def now_ms() -> int:
    return int(time.time() * 1000)


_ESC_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\)|\x1b.?")


def clean_line(text: Any, limit: int = 200) -> str:
    """One line of untrusted text: escape sequences and control/format
    characters removed, whitespace collapsed, length capped (ellipsis)."""
    text = _ESC_RE.sub("", str(text or ""))
    text = "".join(" " if unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp") else ch for ch in text)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "\u2026"


def clean_lines(text: Any, limit: int = MAX_REPLY, max_lines: int = MAX_REPLY_LINES) -> list[str]:
    """Multi-line untrusted text: the total is capped at `limit` characters,
    each line is cleaned like clean_line(), blank runs collapse, and at most
    `max_lines` lines are kept."""
    raw = _ESC_RE.sub("", str(text or "")).replace("\r\n", "\n").replace("\r", "\n")
    if len(raw) > limit:
        raw = raw[: limit - 1] + "\u2026"
    lines: list[str] = []
    for part in raw.split("\n"):
        line = clean_line(part, limit)
        if line or (lines and lines[-1]):
            lines.append(line)
    while lines and not lines[-1]:
        lines.pop()
    if len(lines) > max_lines:
        lines = lines[: max_lines - 1] + ["\u2026"]
    return lines


def age_text(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60} min ago"
    if seconds < 86400:
        return f"{seconds // 3600} h ago"
    return f"{seconds // 86400} d ago"


class Inbox:
    """Per-agent queue of dashboard prompts for real (cloud) bots, which pick
    them up through the check_office_inbox MCP tool. Persisted as JSON so a
    restart does not lose anything. Items: {id, text, created} (epoch s)."""

    def __init__(self, path: str | None) -> None:
        self.path = path  # None = memory only
        self.pending: dict[str, list[dict[str, Any]]] = {}
        self.delivered: dict[str, list[dict[str, Any]]] = {}
        self.load()

    def load(self) -> None:
        if not self.path or not os.path.exists(self.path):
            return
        try:
            with open(self.path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as exc:
            log.warning("could not read inbox %s (%s): starting empty", self.path, exc)
            return
        for key, store in (("pending", self.pending), ("delivered", self.delivered)):
            for aid, items in (data.get(key) or {}).items() if isinstance(data, dict) else ():
                if not isinstance(items, list):
                    continue
                good = [{"id": str(i["id"]), "text": str(i["text"]), "created": float(i["created"]),
                         **({"delivered": float(i["delivered"])} if "delivered" in i else {})}
                        for i in items if isinstance(i, dict) and {"id", "text", "created"} <= i.keys()]
                if good:
                    store[str(aid)] = good

    def save(self) -> None:
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"version": 1, "pending": self.pending, "delivered": self.delivered}, fh,
                          ensure_ascii=False, indent=1)
            os.replace(tmp, self.path)
        except OSError as exc:
            log.error("could not save inbox %s: %s", self.path, exc)

    def unread(self, agent_id: str) -> int:
        return len(self.pending.get(agent_id, ()))

    def add(self, agent_id: str, text: str) -> dict[str, Any] | None:
        """Queues a message; None when the agent's inbox is full."""
        items = self.pending.setdefault(agent_id, [])
        if len(items) >= INBOX_CAP:
            return None
        item = {"id": secrets.token_hex(3), "text": text, "created": time.time()}
        items.append(item)
        self.save()
        return item

    def take(self, agent_id: str) -> list[dict[str, Any]]:
        """Returns and clears the pending messages (they move to the history)."""
        items = self.pending.pop(agent_id, [])
        if items:
            now = time.time()
            hist = self.delivered.setdefault(agent_id, [])
            hist.extend({**i, "delivered": now} for i in items)
            del hist[:-INBOX_HISTORY]
            self.save()
        return items

    def find(self, agent_id: str, message_id: str) -> dict[str, Any] | None:
        for item in [*self.delivered.get(agent_id, ()), *self.pending.get(agent_id, ())]:
            if item["id"] == message_id:
                return item
        return None

    def has_history(self, agent_id: str) -> bool:
        return bool(self.pending.get(agent_id) or self.delivered.get(agent_id))


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

def is_chief_of_staff(agent: "Agent | None", agent_id: str = "") -> bool:
    """True for the single Chief of Staff role (agent_id or role/name match)."""
    if agent is not None:
        if agent.agent_id == COS_AGENT_ID:
            return True
        role = (agent.role or "").casefold()
        name = (agent.name or "").casefold()
        if "chief of staff" in role or name == "chief of staff":
            return True
    aid = (agent_id or (agent.agent_id if agent else "")).casefold()
    return aid == COS_AGENT_ID


def vault_notice_payload(kind: str, title: str, detail: str = "", *, pending: bool = False,
                         meta: dict | None = None) -> dict:
    """Server to client notice event. Names only — never values."""
    return {
        "type": "VAULT_NOTICE",
        "kind": kind,
        "title": title,
        "detail": detail,
        "pending": pending,
        "meta": meta or {},
    }


_VAULT_PROMPT_HOOK = None  # set by Harness

def format_job_system_prompt(job: dict | None, name: str = "", role: str = "", agent_id: str = "") -> str:
    """Turn a member job{} into the Claude --append-system-prompt text."""
    job = job or {}
    title = str(job.get("title") or role or name or "Agent").strip() or "Agent"
    dept = str(job.get("department") or "the office").strip() or "the office"
    purpose = str(job.get("purpose") or "").strip()
    resp = job.get("responsibilities") or []
    tools = job.get("tools") or []
    tools_text = str(job.get("tools_text") or "").strip()
    repos = job.get("repos") or []
    reports = str(job.get("reports_to") or "").strip()
    outputs = str(job.get("outputs_and_cadence") or "").strip()
    rights = str(job.get("decision_rights") or "").strip()
    measures = str(job.get("performance_measures") or "").strip()
    lines = [
        f"You are {title} in the {dept} department of the Agentic Corporation office simulation.",
    ]
    if purpose:
        lines.append(f"Purpose: {purpose}")
    if resp:
        lines.append("Responsibilities: " + "; ".join(str(x) for x in resp))
    if tools_text:
        lines.append(f"Tools / access: {tools_text}")
    elif tools:
        lines.append("Tools: " + ", ".join(str(x) for x in tools))
    if repos:
        lines.append("Repos / areas: " + ", ".join(str(x) for x in repos))
    if reports:
        lines.append(f"Reports to: {reports}")
    if outputs:
        lines.append(f"Outputs and cadence: {outputs}")
    if rights:
        lines.append(f"Decision rights / boundaries: {rights}")
    if measures:
        lines.append(f"Success measures: {measures}")
    lines.append(
        "Reply in character, briefly (2–6 sentences unless asked for more). "
        "No tool-use narration, no markdown fences unless needed for code."
    )
    kb = format_knowledge_system_addon()
    if kb:
        lines.append(kb)
    if _VAULT_PROMPT_HOOK is not None:
        try:
            addon = _VAULT_PROMPT_HOOK(agent_id or name or "")
        except Exception:
            addon = ""
        if addon:
            lines.append(addon)
    return "\n".join(lines)


def knowledge_one_line_summary(text: str, fallback: str = "") -> str:
    """First markdown heading or first non-empty paragraph, single line."""
    lines = (text or "").replace("\r\n", "\n").split("\n")
    heading = ""
    para: list[str] = []
    for raw in lines:
        s = raw.strip()
        if not s:
            if para:
                break
            continue
        if s.startswith("#"):
            heading = s.lstrip("#").strip()
            break
        para.append(s)
    summary = heading or " ".join(para) or fallback
    summary = " ".join(summary.split())
    if len(summary) > 140:
        summary = summary[:137].rstrip() + "..."
    return summary


def regenerate_knowledge_index(knowledge_dir: Path) -> Path:
    """Write knowledge/INDEX.md (filename + one-line summary). Skip INDEX itself."""
    knowledge_dir.mkdir(parents=True, exist_ok=True)
    entries: list[tuple[str, str]] = []
    for path in sorted(knowledge_dir.iterdir(), key=lambda x: x.name.lower()):
        if not path.is_file() or path.suffix.lower() != ".md":
            continue
        if path.name.upper() == "INDEX.MD":
            continue
        try:
            body = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            body = ""
        summary = knowledge_one_line_summary(body, fallback=path.stem.replace("_", " ").replace("-", " "))
        entries.append((path.name, summary))
    lines = [
        "# Shared company knowledge",
        "",
        "Auto-generated index. Agents: use the Read tool on `knowledge/<file>` when a task touches a topic below.",
        "",
    ]
    if not entries:
        lines.append("_No knowledge files yet._")
    else:
        for name, summary in entries:
            lines.append(f"- `{name}` — {summary}")
        lines.append("")
    index_path = knowledge_dir / "INDEX.md"
    index_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return index_path


def format_knowledge_system_addon(knowledge_dir: Path | None = None) -> str:
    """Appended to every agent Claude system prompt: shared knowledge lives in knowledge/."""
    root = knowledge_dir
    if root is None:
        root = Path(__file__).resolve().parent / "knowledge"
    else:
        root = Path(knowledge_dir)
    if not root.is_dir():
        return (
            "Shared company knowledge lives in the knowledge/ folder. "
            "The index is empty right now. When files appear, Read knowledge/<file> for details."
        )
    # Ensure index exists / is fresh enough for listing
    regenerate_knowledge_index(root)
    items: list[str] = []
    for path in sorted(root.iterdir(), key=lambda x: x.name.lower()):
        if not path.is_file() or path.suffix.lower() != ".md":
            continue
        if path.name.upper() == "INDEX.MD":
            continue
        try:
            body = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            body = ""
        summary = knowledge_one_line_summary(body, fallback=path.stem.replace("_", " "))
        items.append(f"- {path.name}: {summary}")
    lines = [
        "Shared company knowledge lives in the knowledge/ folder (see knowledge/INDEX.md).",
        "Below is the index (names and one-line summaries only). "
        "When a task touches a listed topic, use the Read tool on knowledge/<filename> before answering.",
    ]
    if items:
        lines.append("Knowledge index:")
        lines.extend(items)
    else:
        lines.append("Knowledge index: (empty)")
    return "\n".join(lines)


def format_job_plain(job: dict | None, name: str = "", role: str = "") -> str:
    """Human-readable job description for the terminal /jd panel."""
    job = job or {}
    full = str(job.get("full_description") or "").strip()
    if full:
        return full
    title = str(job.get("title") or role or name or "Agent").strip() or "Agent"
    dept = str(job.get("department") or "").strip()
    lines = [f"Job description — {title}"]
    if dept:
        lines.append(f"Department: {dept}")
    purpose = str(job.get("purpose") or "").strip()
    if purpose:
        lines.append(f"Purpose: {purpose}")
    resp = job.get("responsibilities") or []
    if resp:
        lines.append("Responsibilities:")
        for x in resp:
            lines.append(f"  • {x}")
    tools_text = str(job.get("tools_text") or "").strip()
    tools = job.get("tools") or []
    if tools_text:
        lines.append(f"Tools / access: {tools_text}")
    elif tools:
        lines.append("Tools: " + ", ".join(str(x) for x in tools))
    repos = job.get("repos") or []
    if repos:
        lines.append("Repos: " + ", ".join(str(x) for x in repos))
    reports = str(job.get("reports_to") or "").strip()
    if reports:
        lines.append(f"Reports to: {reports}")
    human_owner = str(job.get("human_owner") or "").strip()
    if human_owner:
        lines.append(f"Human owner: {human_owner}")
    outputs = str(job.get("outputs_and_cadence") or "").strip()
    if outputs:
        lines.append(f"Outputs and cadence: {outputs}")
    rights = str(job.get("decision_rights") or "").strip()
    if rights:
        lines.append(f"Decision rights: {rights}")
    caps = str(job.get("capabilities_and_tests") or "").strip()
    if caps:
        lines.append(f"Capabilities / tests: {caps}")
    measures = str(job.get("performance_measures") or "").strip()
    if measures:
        lines.append(f"Success measures: {measures}")
    handoffs = str(job.get("handoffs_and_workflow") or "").strip()
    if handoffs:
        lines.append(f"Handoffs / workflow: {handoffs}")
    if len(lines) == 1:
        lines.append("(no job description yet — edit office.json job{} or roles/catalog.json)")
    return "\n".join(lines)


@dataclass
class Agent:
    """One agent in the office. Mutated only through Hub.emit()."""

    agent_id: str
    name: str
    desk: str
    color: str
    role: str = ""
    room: str = ""
    job: dict = field(default_factory=dict)
    # Where this agent takes breaks / holds meetings (depends on its room).
    break_spots: tuple[str, ...] = SHARED_BREAK_SPOTS
    meeting_target: str = MEETING_TARGET
    group: str = SHARED_GROUP  # agents only meet / play with their own group
    # Small-talk spots (client waypoints <spot>_1.._3, facing each other).
    chat_spots: tuple[str, ...] = SHARED_CHAT_SPOTS
    state: str = "IDLE"
    target: str | None = None
    text: str = ""
    logs: deque[str] = field(default_factory=lambda: deque(maxlen=200))
    lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False)
    queue: asyncio.Queue[str] = field(default_factory=asyncio.Queue, repr=False)
    # Ambient-simulation bookkeeping (simulated seconds, see AmbientDirector).
    activity: str = "desk"  # desk | break | meeting
    activity_until: float = 0.0
    next_event_at: float = 0.0
    thinking_until: float = 0.0
    # Real status reports (MCP): the simulation leaves the agent alone until
    # this time.monotonic() value; live_reports counts them.
    live_until: float = 0.0
    live_reports: int = 0

    def is_live(self) -> bool:
        return time.monotonic() < self.live_until

    def to_json(self, include_logs: bool = True) -> dict[str, Any]:
        data: dict[str, Any] = {
            "agent_id": self.agent_id,
            "name": self.name,
            "role": self.role,
            "room": self.room,
            "desk": self.desk,
            "color": self.color,
            "job": dict(self.job or {}),
            "state": self.state,
            "target": self.target,
            "text": self.text,
            "busy": self.lock.locked(),
            "queued": self.queue.qsize(),
            "live": self.is_live(),
            "unread": 0,  # filled in by Hub.snapshot()
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

    def __init__(self, mode: str, tempo: str = "calm", office: dict[str, Any] | None = None) -> None:
        self.mode = mode
        self.tempo = tempo
        self.connectivity: ConnectivityMonitor | None = None
        self.office = office  # None = legacy fixed office (client uses its built-in layout)
        self.office_path: str | None = None  # where to persist hire/fire (set by Harness)
        self.cmds_path: str | None = None  # agent_cmds.json to extend on hire
        self.agents: dict[str, Agent] = {}
        self.clients: set[ServerConnection] = set()
        self.dispatcher: Callable[[str, str], Awaitable[None]] | None = None
        self.live_hold = 600.0  # seconds a real report keeps the simulation off an agent
        self.inbox = Inbox(None)
        # Decides whether a dashboard prompt goes to the agent's inbox (set by Harness).
        self.inbox_for: Callable[[Agent], bool] = lambda agent: False
        # Called when a real report hands an agent back to the ambient life
        # (action "finish"); set by Harness when a director runs.
        self.on_release: Callable[[Agent], None] | None = None
        # Quiet terminal by default: only chat (user >, …, reply). Verbose shows tools/queue.
        self.verbose_terminal: bool = False
        # Harness hooks so hire/fire can start workers + persist.
        self.on_hired: Callable[[Agent], None] | None = None
        self.on_fired: Callable[[str], None] | None = None
        self.vault: OfficeVault | None = None

    # -- registry ----------------------------------------------------------
    def unregister(self, agent_id: str, *, variant: str = "") -> Agent | None:
        agent = self.agents.pop(agent_id, None)
        if agent is None:
            return None
        payload = {"type": "AGENT_FIRE", "agent_id": agent_id, "name": agent.name,
                   "desk": agent.desk, "room": agent.room}
        if variant:
            payload["variant"] = variant
        self.emit(payload)
        return agent

    def hire(self, agent_id: str, name: str, desk: str, color: str, role: str = "", **extra: Any) -> Agent:
        agent = self.register(agent_id, name, desk, color, role=role, **extra)
        payload = {"type": "AGENT_HIRE", "agent_id": agent_id, "name": agent.name, "role": agent.role,
                   "desk": agent.desk, "room": agent.room, "color": agent.color}
        if agent.job:
            payload["job"] = dict(agent.job)
        self.emit(payload)
        return agent

    def register(self, agent_id: str, name: str, desk: str, color: str, role: str = "", **extra: Any) -> Agent:
        agent = Agent(agent_id=agent_id, name=name, desk=desk, color=color, role=role, **extra)
        self.agents[agent_id] = agent
        return agent

    def layout_message(self) -> dict[str, Any] | None:
        if self.office is None:
            return None
        return {"type": "OFFICE_LAYOUT", "office": self.office, "ts": now_ms()}

    def snapshot(self) -> dict[str, Any]:
        return {
            "type": "SNAPSHOT",
            "server": {"name": "agent_harness", "version": __version__, "mode": self.mode, "tempo": self.tempo,
                       "office": self.office.get("name") if self.office else None,
                       "connectivity": (self.connectivity.payload() if self.connectivity else None)},
            "agents": [{**a.to_json(), "unread": self.inbox.unread(a.agent_id)} for a in self.agents.values()],
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

    def log_line(self, agent_id: str, line: str, stream: str = "stdout", *,
                 important: bool = False) -> None:
        """Office terminal line. Quiet mode drops non-important chatter (tool/queue/ambient)."""
        if self.vault is not None:
            try:
                line = self.vault.scrub(line)
            except Exception:
                pass
        if not important and not self.verbose_terminal:
            log.debug("quiet skip %s: %s", agent_id, strip_ansi(line)[:120])
            return
        self.emit({"type": "LOG_ENTRY", "agent_id": agent_id, "log": line, "stream": stream})

    def collaborate(self, agent_ids: list[str], target: str = MEETING_TARGET, text: str = "") -> None:
        event: dict[str, Any] = {"type": "COLLABORATE", "agents": agent_ids, "target": target}
        if text:
            event["text"] = text
        self.emit(event)
        # Opening turn so the Meeting Room shows a speech bubble.
        if agent_ids:
            opener = text or "Let's sync."
            self.emit({"type": "MEETING_TURN", "agent_id": agent_ids[0], "text": opener, "target": target})

    # -- live status reports (office_mcp.py) ---------------------------------
    def find_agent(self, name: str) -> Agent | None:
        """Matches a bot by display name or agent_id, case-insensitively and
        ignoring extra whitespace / '-' vs '_' in ids."""
        key = " ".join(str(name).split()).casefold()
        if not key:
            return None
        for agent in self.agents.values():
            if key in (agent.name.casefold(), agent.agent_id.casefold()):
                return agent
        slug = re.sub(r"[\s-]+", "_", key)
        for agent in self.agents.values():
            if slug == agent.agent_id or slug == re.sub(r"[\s-]+", "_", agent.name.casefold()):
                return agent
        return None

    def agent_names(self) -> list[str]:
        return [a.name for a in self.agents.values()]

    def apply_report(self, agent: Agent, action: str, detail: str = "") -> None:
        """Turns one real status report into the usual office events."""
        aid = agent.agent_id
        self.touch_live(agent)
        # The ambient director resumes from a clean desk session afterwards.
        agent.thinking_until = 0.0
        if action == "start_task":
            text = detail or "Starting a task"
            self.log_line(aid, f"\x1b[1;36m\u25b6 {text}\x1b[0m")
            self.state(aid, "WORKING", target=agent.desk, text=text)
            agent.activity = "desk"
        elif action == "thinking":
            text = detail or "Thinking..."
            self.log_line(aid, f"\x1b[33m\u2026 {text}\x1b[0m")
            self.state(aid, "THINKING", target=agent.desk, text=text)
            agent.activity = "desk"
        elif action == "run_tool":
            text = detail or "Running a tool"
            self.log_line(aid, f"\x1b[2m$ {text}\x1b[0m")
            self.state(aid, "WORKING", target=agent.desk, text=text)
            agent.activity = "desk"
        elif action == "finish":
            self.log_line(aid, f"\x1b[1;32m\u2714 Done:\x1b[0m {detail}" if detail else "\x1b[1;32m\u2714 Done\x1b[0m")
            spot = random.choice(agent.break_spots)
            self.state(aid, "IDLE", target=spot, text="Done! Coffee time." if "Coffee" in spot else "Done!")
            agent.activity = "break"
            # Finished: the agent goes straight back to the ambient office life.
            agent.live_until = 0.0
            if self.on_release:
                self.on_release(agent)
        elif action == "error":
            text = detail or "Something went wrong"
            self.log_line(aid, f"\x1b[1;31m\u2716 Error:\x1b[0m {text}", stream="stderr")
            self.state(aid, "ERROR", target=agent.desk, text=text)
            agent.activity = "desk"
        else:
            raise ValueError(f"unknown action {action!r}")
        log.info("live report %s %s: %s", aid, action, detail)

    # -- inbox (dashboard -> real bots) ---------------------------------------
    def inbox_event(self, agent_id: str) -> None:
        self.emit({"type": "INBOX", "agent_id": agent_id, "unread": self.inbox.unread(agent_id)})

    def queue_message(self, agent: Agent, prompt: str) -> dict[str, Any] | None:
        text = "\n".join(clean_lines(prompt, MAX_PROMPT))
        item = self.inbox.add(agent.agent_id, text)
        # Inbox / mode chatter stays in the harness log — the terminal only shows chat.
        if item is None:
            log.warning("inbox full (%s unread) for %s: message not queued", INBOX_CAP, agent.name)
            return None
        self.inbox_event(agent.agent_id)
        log.info("inbox %s += #%s (%s)", agent.agent_id, item["id"], clean_line(text, 80))
        if self.mode == "live":
            log.info("live mode: no CLI bound for %s — waiting for check_office_inbox", agent.agent_id)
        return item

    def deliver_messages(self, agent: Agent) -> list[dict[str, Any]]:
        items = self.inbox.take(agent.agent_id)
        if items:
            ids = ", ".join("#" + i["id"] for i in items)
            log.info("delivered to %s (%s)", agent.name, ids)
            self.inbox_event(agent.agent_id)
            self.touch_live(agent, hold=False)
        return items

    def post_reply(self, agent: Agent, reply: str, message_id: str = "", bubble: bool = True) -> None:
        """Prints a bot's reply in its terminal as plain text ("<name>> ...")."""
        lines = clean_lines(reply, MAX_REPLY) or ["(empty reply)"]
        ref = ""
        if message_id:
            item = self.inbox.find(agent.agent_id, message_id)
            if item is not None:
                ref = f" \x1b[2m(re #{message_id}: {clean_line(item['text'], 40)})\x1b[0m"
        prefix = f"\x1b[1;32m{agent.name}>\x1b[0m "
        self.log_line(agent.agent_id, prefix + lines[0] + ref, important=True)
        pad = " " * (len(agent.name) + 2)
        for line in lines[1:]:
            self.log_line(agent.agent_id, pad + line, important=True)
        if bubble:
            self.state(agent.agent_id, agent.state, text=clean_line(" ".join(lines), 60))
        self.touch_live(agent, hold=False)

    def touch_live(self, agent: Agent, hold: bool = True) -> None:
        """Marks the agent as a real bot. Status reports (hold=True) keep the
        simulation off it for live_hold seconds; inbox traffic only extends a
        hold that is already running (a bot reading its messages after
        "finish" keeps its ambient life)."""
        if hold or agent.is_live():
            agent.live_until = time.monotonic() + self.live_hold
        agent.live_reports += 1

    # -- connection handling ----------------------------------------------
    async def handler(self, ws: ServerConnection, *_legacy_path: Any) -> None:
        peer = getattr(ws, "remote_address", None)
        self.clients.add(ws)
        log.info("client connected %s (%d total)", peer, len(self.clients))
        try:
            layout = self.layout_message()
            if layout:  # layout first, so the client can build rooms before spawning agents
                await ws.send(json.dumps(layout, ensure_ascii=False))
            await ws.send(json.dumps(self.snapshot(), ensure_ascii=False))
            if self.connectivity is not None:
                await ws.send(json.dumps(self.connectivity.payload(), ensure_ascii=False))
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
            if self.inbox_for(agent):
                item = self.queue_message(agent, prompt)
                if item is None:
                    await self.reply(ws, {"type": "ERROR", "action": action, "agent_id": agent_id,
                                          "message": f"{agent.name}'s inbox is full ({INBOX_CAP} unread)"})
                else:
                    await self.reply(ws, {"type": "ACK", "action": action, "agent_id": agent_id, "prompt": prompt,
                                          "inbox": True, "message_id": item["id"],
                                          "unread": self.inbox.unread(agent_id), "queued": 0})
                return
            # The ambient director never holds an agent's lock across an await,
            # so the worker picks this up immediately and the director then
            # leaves the agent alone until the run finishes.
            await agent.queue.put(prompt)
            await self.reply(ws, {"type": "ACK", "action": action, "agent_id": agent_id,
                                  "prompt": prompt, "queued": agent.queue.qsize()})
        elif action in ("REQUEST_SNAPSHOT", "GET_REGISTRY"):
            await self.reply(ws, self.snapshot())
        elif action == "REQUEST_LAYOUT":
            await self.reply(ws, self.layout_message() or {"type": "ERROR", "action": action,
                                                           "message": "no office layout (legacy mode)"})
        elif action == "PING":
            await self.reply(ws, {"type": "PONG", "ts": now_ms()})
        elif action in ("CHECK_CONNECTIVITY", "REACTIVATE_CLAUDE"):
            mon = self.connectivity
            if mon is None:
                await self.reply(ws, {"type": "CONNECTIVITY", "harness": True, "claude": "down",
                                      "reason": "connectivity monitor off (mock mode without Claude)",
                                      "mode": self.mode, "ts": now_ms()})
            else:
                payload = await mon.check(force=True)
                await self.reply(ws, payload)
        elif action in ("SET_TERMINAL_VERBOSE", "TOGGLE_TERMINAL_VERBOSE"):
            if action == "TOGGLE_TERMINAL_VERBOSE":
                self.verbose_terminal = not self.verbose_terminal
            else:
                self.verbose_terminal = bool(msg.get("verbose", True))
            log.info("terminal verbose=%s", self.verbose_terminal)
            await self.reply(ws, {"type": "ACK", "action": "SET_TERMINAL_VERBOSE",
                                  "verbose": self.verbose_terminal,
                                  "message": "verbose on" if self.verbose_terminal else "quiet mode (only > … reply)"})
        elif action == "HIRE_AGENT":
            await self._action_hire(ws, msg)
        elif action in ("FIRE_AGENT", "ARCHIVE_AGENT"):
            await self._action_fire(ws, msg)
        elif action == "PREVIEW_HIRE_FIRE":
            await self._action_preview_hire_fire(ws, msg)
        elif action == "ADD_KNOWLEDGE":
            await self._action_add_knowledge(ws, msg)
        elif action == "LIST_KNOWLEDGE":
            await self._action_list_knowledge(ws, msg)
        elif action == "REMOVE_KNOWLEDGE":
            await self._action_remove_knowledge(ws, msg)
        elif action == "SEND_DM":
            await self._action_send_dm(ws, msg)
        elif action == "HUMAN_REPLY":
            await self._action_human_reply(ws, msg)
        elif action == "ASK_HUMAN":
            # Client / test path: surface an ask-human dialog for an agent.
            await self._action_ask_human(ws, msg)
        elif action == "OPEN_HIRING_BOARD":
            # Test hook: ask the Godot client to open the Hiring Board (same as + Add Agent).
            payload = {"type": "OPEN_HIRING_BOARD"}
            self.emit(payload)
            await self.reply(ws, {"type": "ACK", "action": "OPEN_HIRING_BOARD"})
        elif action == "VAULT_LIST":
            await self._action_vault_list(ws, msg)
        elif action == "VAULT_ADD":
            await self._action_vault_add(ws, msg)
        elif action == "VAULT_GRANT":
            await self._action_vault_grant(ws, msg)
        elif action == "VAULT_REVOKE":
            await self._action_vault_revoke(ws, msg)
        elif action == "VAULT_RM":
            await self._action_vault_rm(ws, msg)
        elif action == "VAULT_CONFIRM_RM":
            await self._action_vault_confirm_rm(ws, msg)
        elif action == "VAULT_CANCEL_RM":
            await self._action_vault_cancel_rm(ws, msg)
        elif action == "VAULT_SUBMIT_SECRET":
            await self._action_vault_submit_secret(ws, msg)
        elif action == "VAULT_DISMISS_SECRET":
            await self._action_vault_dismiss_secret(ws, msg)
        elif action == "VAULT_UNLOCK":
            await self._action_vault_unlock(ws, msg)
        elif action == "VAULT_LOCK":
            await self._action_vault_lock(ws, msg)
        elif action == "VAULT_SET_AGENTS":
            await self._action_vault_set_agents(ws, msg)
        else:
            await self.reply(ws, {"type": "ERROR", "message": f"unknown action '{action}'"})



    async def _action_add_knowledge(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        """Copy a dropped .md into knowledge/ and broadcast KNOWLEDGE_ADDED."""
        src = str(msg.get("path", "")).strip()
        if not src:
            await self.reply(ws, {"type": "ERROR", "action": "ADD_KNOWLEDGE", "message": "path required"})
            return
        src_path = Path(src).expanduser()
        if not src_path.is_file():
            await self.reply(ws, {"type": "ERROR", "action": "ADD_KNOWLEDGE", "message": f"not a file: {src}"})
            return
        if src_path.suffix.lower() != ".md":
            await self.reply(ws, {"type": "ERROR", "action": "ADD_KNOWLEDGE", "message": "only .md knowledge files"})
            return
        root = Path(self.office_path).resolve().parent if self.office_path else Path.cwd()
        dest_dir = root / "knowledge"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / src_path.name
        # Avoid clobber: suffix if needed
        if dest.exists():
            stem, suf = dest.stem, dest.suffix
            n = 2
            while True:
                cand = dest_dir / f"{stem}_{n}{suf}"
                if not cand.exists():
                    dest = cand
                    break
                n += 1
        try:
            dest.write_bytes(src_path.read_bytes())
        except OSError as exc:
            await self.reply(ws, {"type": "ERROR", "action": "ADD_KNOWLEDGE", "message": str(exc)})
            return
        title = dest.stem.replace("_", " ").replace("-", " ")
        payload = {
            "type": "KNOWLEDGE_ADDED",
            "path": str(dest),
            "filename": dest.name,
            "title": title,
            "rack": "Server_Rack_1",
        }
        regenerate_knowledge_index(dest_dir)
        self.emit(payload)
        log.info("ADD_KNOWLEDGE %s -> %s", src_path, dest)
        await self.reply(ws, {"type": "ACK", "action": "ADD_KNOWLEDGE", "filename": dest.name, "title": title})

    def _knowledge_dir(self) -> Path:
        root = Path(self.office_path).resolve().parent if self.office_path else Path.cwd()
        return root / "knowledge"

    def _list_knowledge_files(self) -> list[dict[str, Any]]:
        dest_dir = self._knowledge_dir()
        if not dest_dir.is_dir():
            return []
        out: list[dict[str, Any]] = []
        for p in sorted(dest_dir.iterdir(), key=lambda x: x.name.lower()):
            if not p.is_file() or p.suffix.lower() != ".md":
                continue
            if p.name.upper() == "INDEX.MD":
                continue
            try:
                st = p.stat()
            except OSError:
                continue
            content = ""
            try:
                content = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                content = ""
            out.append({
                "name": p.name,
                "filename": p.name,
                "title": p.stem.replace("_", " ").replace("-", " "),
                "summary": knowledge_one_line_summary(content, fallback=p.stem.replace("_", " ").replace("-", " ")),
                "path": str(p),
                "size": int(st.st_size),
                "mtime": float(st.st_mtime),
                "added": float(st.st_mtime),
                "content": content,
            })
        return out

    async def _action_list_knowledge(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        files = self._list_knowledge_files()
        payload = {"type": "KNOWLEDGE_LIST", "files": files, "count": len(files)}
        await self.reply(ws, payload)
        # Also broadcast so any open panel can refresh.
        self.emit(payload)

    async def _action_remove_knowledge(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        raw = str(msg.get("name", msg.get("filename", msg.get("path", "")))).strip()
        if not raw:
            await self.reply(ws, {"type": "ERROR", "action": "REMOVE_KNOWLEDGE", "message": "name required"})
            return
        dest_dir = self._knowledge_dir()
        # Accept basename only; reject path traversal.
        name = Path(raw).name
        target = dest_dir / name
        if not target.is_file() or target.suffix.lower() != ".md":
            # Try stem match / case-insensitive.
            found = None
            if dest_dir.is_dir():
                for p in dest_dir.iterdir():
                    if p.is_file() and p.suffix.lower() == ".md" and (
                        p.name == name or p.stem == Path(name).stem
                        or p.name.lower() == name.lower()
                    ):
                        found = p
                        break
            if found is None:
                await self.reply(ws, {"type": "ERROR", "action": "REMOVE_KNOWLEDGE",
                                     "message": f"not found: {name}"})
                return
            target = found
            name = target.name
        try:
            target.unlink()
        except OSError as exc:
            await self.reply(ws, {"type": "ERROR", "action": "REMOVE_KNOWLEDGE", "message": str(exc)})
            return
        title = Path(name).stem.replace("_", " ").replace("-", " ")
        payload = {
            "type": "KNOWLEDGE_REMOVED",
            "filename": name,
            "name": name,
            "title": title,
            "path": str(target),
            "files": self._list_knowledge_files(),
        }
        regenerate_knowledge_index(dest_dir)
        self.emit(payload)
        log.info("REMOVE_KNOWLEDGE %s", target)
        await self.reply(ws, {"type": "ACK", "action": "REMOVE_KNOWLEDGE",
                              "filename": name, "title": title})

    async def _action_send_dm(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        to_raw = str(msg.get("to", "")).strip()
        text = str(msg.get("text", "")).strip()
        from_who = str(msg.get("from", "paul")).strip() or "paul"
        if not to_raw or not text:
            await self.reply(ws, {"type": "ERROR", "action": "SEND_DM", "message": "to and text required"})
            return
        agent = self.find_agent(to_raw) or self.agents.get(to_raw)
        if agent is None:
            await self.reply(ws, {"type": "ERROR", "action": "SEND_DM", "message": f"unknown agent '{to_raw}'"})
            return
        item = self.queue_message(agent, f"[DM from {from_who}] {text}")
        if item is None:
            await self.reply(ws, {"type": "ERROR", "action": "SEND_DM", "message": "inbox full"})
            return
        self.emit({
            "type": "AGENT_DM",
            "to": agent.agent_id,
            "from": from_who,
            "text": text,
            "message_id": item["id"],
        })
        await self.reply(ws, {"type": "ACK", "action": "SEND_DM", "to": agent.agent_id, "message_id": item["id"]})

    async def _action_human_reply(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        agent_id = str(msg.get("agent_id", ""))
        text = str(msg.get("text", "")).strip()
        request_id = str(msg.get("request_id", ""))
        if agent_id not in self.agents:
            await self.reply(ws, {"type": "ERROR", "action": "HUMAN_REPLY", "message": f"unknown agent '{agent_id}'"})
            return
        if not text:
            await self.reply(ws, {"type": "ERROR", "action": "HUMAN_REPLY", "message": "empty reply"})
            return
        agent = self.agents[agent_id]
        prompt = f"[Human reply{(' #' + request_id) if request_id else ''}] {text}"
        if self.inbox_for(agent):
            item = self.queue_message(agent, prompt)
            if item is None:
                await self.reply(ws, {"type": "ERROR", "action": "HUMAN_REPLY", "message": "inbox full"})
                return
            await self.reply(ws, {"type": "ACK", "action": "HUMAN_REPLY", "agent_id": agent_id,
                                  "message_id": item["id"], "inbox": True})
            return
        await agent.queue.put(prompt)
        await self.reply(ws, {"type": "ACK", "action": "HUMAN_REPLY", "agent_id": agent_id,
                              "queued": agent.queue.qsize()})

    async def _action_ask_human(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        agent_id = str(msg.get("agent_id", ""))
        prompt = str(msg.get("prompt", msg.get("text", ""))).strip()
        if agent_id not in self.agents:
            await self.reply(ws, {"type": "ERROR", "action": "ASK_HUMAN", "message": f"unknown agent '{agent_id}'"})
            return
        agent = self.agents[agent_id]
        request_id = str(msg.get("request_id", "") or f"ask_{int(now_ms())}")
        payload = {
            "type": "ASK_HUMAN",
            "agent_id": agent_id,
            "agent_name": agent.name,
            "prompt": prompt or f"{agent.name} needs a decision from you.",
            "request_id": request_id,
            "choices": msg.get("choices") or [],
        }
        self.emit(payload)
        await self.reply(ws, {"type": "ACK", "action": "ASK_HUMAN", "agent_id": agent_id, "request_id": request_id})



    def _vault_or_error(self) -> OfficeVault | None:
        return self.vault

    def _vault_roster(self) -> list[str]:
        return sorted(self.agents.keys())

    def _vault_meta_payload(self, *, full: bool) -> dict[str, Any]:
        vault = self.vault
        assert vault is not None
        if full and vault.is_unlocked():
            secrets = vault.list_meta()
        else:
            secrets = vault.list_public()
        return {
            "type": "VAULT_META",
            "secrets": secrets,
            "pending": list(vault.pending),
            "locked": not vault.is_unlocked(),
            "unlocked_until": vault.unlocked_until,
            "roster": self._vault_roster(),
            "integrity_ok": vault.verify_integrity(),
            "integrity_detail": vault.integrity_detail,
        }

    async def _vault_require_unlocked(self, ws: ServerConnection, action: str) -> OfficeVault | None:
        vault = self._vault_or_error()
        if vault is None:
            await self.reply(ws, {"type": "ERROR", "action": action, "message": "vault unavailable"})
            return None
        if not vault.is_unlocked():
            await self.reply(ws, {"type": "ERROR", "action": action,
                                  "message": "vault is locked — click the Executive safe to unlock"})
            return None
        vault.touch_unlock()
        return vault

    async def _action_vault_unlock(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = self._vault_or_error()
        if vault is None:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_UNLOCK", "message": "vault unavailable"})
            return
        if vault.is_unlocked():
            vault.touch_unlock()
            self.emit({"type": "VAULT_UNLOCKED", "unlocked_until": vault.unlocked_until,
                       "already": True})
            self.emit(self._vault_meta_payload(full=True))
            await self.reply(ws, {"type": "ACK", "action": "VAULT_UNLOCK", "already": True})
            return
        reason = str(msg.get("reason") or "Unlock the Agentic Corporation office vault")
        try:
            from tools.vault_auth import authenticate as vault_authenticate
        except ImportError:
            # tools/ may not be a package — load by path
            import importlib.util
            spec = importlib.util.spec_from_file_location(
                "vault_auth", Path(__file__).resolve().parent / "tools" / "vault_auth.py")
            if spec is None or spec.loader is None:
                await self.reply(ws, {"type": "ERROR", "action": "VAULT_UNLOCK",
                                      "message": "vault_auth helper missing"})
                return
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            vault_authenticate = mod.authenticate  # type: ignore

        ok, detail = await asyncio.to_thread(vault_authenticate, reason)
        if not ok:
            self.emit(vault_notice_payload(
                "vault_unlock_fail", "Vault unlock failed",
                (detail or "authentication failed")[:160],
            ))
            self.emit({"type": "VAULT_UNLOCK_FAILED", "detail": (detail or "")[:160]})
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_UNLOCK", "message": detail or "denied"})
            return
        until = vault.mark_unlocked()
        self.emit(vault_notice_payload(
            "vault_unlock", "Vault unlocked",
            "session open — re-locks after 2 minutes idle or when closed",
        ))
        self.emit({"type": "VAULT_UNLOCKED", "unlocked_until": until, "already": False})
        self.emit(self._vault_meta_payload(full=True))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_UNLOCK", "unlocked_until": until})

    async def _action_vault_lock(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = self._vault_or_error()
        if vault is None:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_LOCK", "message": "vault unavailable"})
            return
        was = vault.is_unlocked()
        vault.lock()
        if was:
            self.emit(vault_notice_payload("vault_lock", "Vault locked", "session closed"))
        self.emit({"type": "VAULT_LOCKED"})
        self.emit(self._vault_meta_payload(full=False))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_LOCK"})

    async def _action_vault_list(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = self._vault_or_error()
        if vault is None:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_LIST", "message": "vault unavailable"})
            return
        full = vault.is_unlocked()
        if full:
            vault.touch_unlock()
        payload = self._vault_meta_payload(full=full)
        self.emit(payload)
        await self.reply(ws, {"type": "ACK", "action": "VAULT_LIST", "count": len(payload["secrets"]),
                              "pending": len(payload["pending"]), "locked": payload["locked"]})

    async def _action_vault_add(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = await self._vault_require_unlocked(ws, "VAULT_ADD")
        if vault is None:
            return
        name = str(msg.get("name", "")).strip()
        value = str(msg.get("value", ""))
        description = str(msg.get("description", "")).strip()
        agents = msg.get("agents", [])
        try:
            meta = vault.add_secret(name, value, description=description, agents=agents)
        except Exception as exc:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_ADD", "message": str(exc)})
            return
        self.emit(vault_notice_payload(
            "vault_add", f"Vault + {meta['name']}",
            meta.get("description") or "secret stored (value in keychain)",
            meta={"name": meta["name"], "agents": meta.get("agents", [])},
        ))
        self.emit(self._vault_meta_payload(full=True))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_ADD", "name": meta["name"]})

    async def _action_vault_grant(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = await self._vault_require_unlocked(ws, "VAULT_GRANT")
        if vault is None:
            return
        name = str(msg.get("name", "")).strip()
        grantee = str(msg.get("agent_id", msg.get("grantee", ""))).strip()
        try:
            meta = vault.grant(name, grantee)
        except Exception as exc:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_GRANT", "message": str(exc)})
            return
        self.emit(vault_notice_payload(
            "vault_grant", f"Vault grant {name} → {grantee}",
            "access updated (names only)",
            meta={"name": name, "grantee": grantee, "agents": meta.get("agents", []), "by": "human"},
        ))
        self.emit(self._vault_meta_payload(full=True))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_GRANT", "name": name, "grantee": grantee})

    async def _action_vault_revoke(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = await self._vault_require_unlocked(ws, "VAULT_REVOKE")
        if vault is None:
            return
        name = str(msg.get("name", "")).strip()
        grantee = str(msg.get("agent_id", msg.get("grantee", ""))).strip()
        try:
            meta = vault.revoke(name, grantee)
        except Exception as exc:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_REVOKE", "message": str(exc)})
            return
        self.emit(vault_notice_payload(
            "vault_revoke", f"Vault revoke {name} ✕ {grantee}",
            "access updated (names only)",
            meta={"name": name, "grantee": grantee, "agents": meta.get("agents", []), "by": "human"},
        ))
        self.emit(self._vault_meta_payload(full=True))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_REVOKE", "name": name, "grantee": grantee})

    async def _action_vault_set_agents(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = await self._vault_require_unlocked(ws, "VAULT_SET_AGENTS")
        if vault is None:
            return
        name = str(msg.get("name", "")).strip()
        agents = msg.get("agents", [])
        try:
            meta = vault.set_agents(name, agents)
        except Exception as exc:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_SET_AGENTS", "message": str(exc)})
            return
        who = "all" if meta.get("agents") == "all" else ",".join(meta.get("agents") or [])
        self.emit(vault_notice_payload(
            "vault_grant", f"Vault ACL {name}",
            f"agents → {who or '(none)'}",
            meta={"name": name, "agents": meta.get("agents", []), "by": "human"},
        ))
        self.emit(self._vault_meta_payload(full=True))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_SET_AGENTS", "name": name})

    async def _action_vault_rm(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = await self._vault_require_unlocked(ws, "VAULT_RM")
        if vault is None:
            return
        name = str(msg.get("name", "")).strip()
        if not vault.get_meta(name):
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_RM", "message": f"unknown secret '{name}'"})
            return
        request_id = f"vault_rm_{int(now_ms())}_{name}"
        self.emit({
            "type": "VAULT_REMOVE_CONFIRM",
            "name": name,
            "request_id": request_id,
            "prompt": f"Delete vault secret '{name}' from the keychain? This cannot be undone.",
        })
        self.emit(vault_notice_payload(
            "vault_rm_pending", f"Vault remove pending — {name}",
            "waiting for human confirmation",
            pending=True, meta={"name": name, "request_id": request_id},
        ))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_RM", "name": name, "request_id": request_id})

    async def _action_vault_confirm_rm(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = await self._vault_require_unlocked(ws, "VAULT_CONFIRM_RM")
        if vault is None:
            return
        name = str(msg.get("name", "")).strip()
        try:
            vault.remove(name)
        except Exception as exc:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_CONFIRM_RM", "message": str(exc)})
            return
        self.emit(vault_notice_payload(
            "vault_rm", f"Vault − {name}", "removed from keychain + metadata",
            meta={"name": name},
        ))
        self.emit(self._vault_meta_payload(full=True))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_CONFIRM_RM", "name": name})

    async def _action_vault_cancel_rm(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        name = str(msg.get("name", "")).strip()
        self.emit(vault_notice_payload(
            "vault_rm_cancelled", f"Vault remove cancelled — {name}", "",
            meta={"name": name},
        ))
        await self.reply(ws, {"type": "ACK", "action": "VAULT_CANCEL_RM", "name": name})

    async def _action_vault_submit_secret(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        # Submitting a requested secret is itself an unlock-gated human action when session locked:
        # allow without prior unlock so agent requests still work; value never leaves keychain path.
        vault = self._vault_or_error()
        if vault is None:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_SUBMIT_SECRET", "message": "vault unavailable"})
            return
        request_id = str(msg.get("request_id", "")).strip()
        value = str(msg.get("value", ""))
        try:
            result = vault.submit_request(request_id, value)
        except Exception as exc:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_SUBMIT_SECRET", "message": str(exc)})
            return
        req = result["request"]
        meta = result["meta"]
        agent_id = str(req.get("agent_id", ""))
        name = str(meta.get("name", ""))
        self.emit(vault_notice_payload(
            "vault_add", f"Vault + {name}",
            f"granted to {agent_id} (from request)",
            meta={"name": name, "agent_id": agent_id, "request_id": request_id},
        ))
        if agent_id in self.agents:
            self.log_line(
                agent_id,
                f"\x1b[32mvault: ${name} is now available in your environment\x1b[0m",
                important=True,
            )
            agent = self.agents[agent_id]
            if self.inbox_for(agent):
                self.inbox.push(
                    agent_id,
                    f"[vault] Secret '{name}' is available as env var ${name}. Do not print its value.",
                )
        self.emit(self._vault_meta_payload(full=vault.is_unlocked()))
        self.emit({"type": "VAULT_SECRET_RESOLVED", "request_id": request_id, "name": name,
                   "agent_id": agent_id, "status": "granted"})
        await self.reply(ws, {"type": "ACK", "action": "VAULT_SUBMIT_SECRET", "name": name})

    async def _action_vault_dismiss_secret(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        vault = self._vault_or_error()
        if vault is None:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_DISMISS_SECRET", "message": "vault unavailable"})
            return
        request_id = str(msg.get("request_id", "")).strip()
        req = vault.dismiss_request(request_id)
        if not req:
            await self.reply(ws, {"type": "ERROR", "action": "VAULT_DISMISS_SECRET", "message": "unknown request"})
            return
        agent_id = str(req.get("agent_id", ""))
        name = str(req.get("name", ""))
        self.emit(vault_notice_payload(
            "vault_declined", f"Vault request declined — {name}",
            f"agent {agent_id} must not ask again",
            meta={"name": name, "agent_id": agent_id, "request_id": request_id},
        ))
        if agent_id in self.agents:
            self.log_line(
                agent_id,
                f"\x1b[33mvault: request for ${name} was declined — do not ask again\x1b[0m",
                important=True,
            )
        self.emit(self._vault_meta_payload(full=vault.is_unlocked()))
        self.emit({"type": "VAULT_SECRET_RESOLVED", "request_id": request_id, "name": name,
                   "agent_id": agent_id, "status": "declined"})
        await self.reply(ws, {"type": "ACK", "action": "VAULT_DISMISS_SECRET", "name": name})


    def save_office(self) -> None:
        """Write current roster back to office.json (hire/fire persistence)."""
        if not self.office or not self.office_path:
            return
        payload = {
            "name": self.office.get("name", "Agentic Corporation"),
            "_comment": "Roster persisted by agent_harness on hire/archive. desks/colors recomputed on load. job{} is the Claude system prompt source.",
            "rooms": [],
            "shared": {},
            "archived": list(self.office.get("archived") or []),
        }
        for room in self.office.get("rooms", []):
            members = []
            for m in room.get("members", []):
                entry = {
                    "agent_id": m["agent_id"],
                    "name": m.get("name", m["agent_id"]),
                    "role": m.get("role", ""),
                    **({"color": m["color"]} if m.get("color") else {}),
                }
                if m.get("job"):
                    entry["job"] = m["job"]
                members.append(entry)
            payload["rooms"].append({
                "id": room["id"],
                "name": room.get("name", room["id"]),
                "color": room.get("color", "#90a4ae"),
                "theme": room.get("theme", "wood"),
                "desks": max(int(room.get("desks", len(members)) or 0), len(members), 1),
                "members": members,
                **({"isolated": True} if room.get("isolated") else {}),
            })
        shared = self.office.get("shared") or {}
        br = shared.get("break_room") or {}
        mr = shared.get("meeting_room") or {}
        cn = shared.get("canteen") or {}
        rr = shared.get("rec_room") or {}
        sr = shared.get("server_room") or {}
        payload["shared"] = {
            "break_room": {"name": br.get("name", "Break Room")},
            "meeting_room": {"name": mr.get("name", "Meeting Room"), "seats": int(mr.get("seats", 6) or 6)},
            "canteen": {"name": cn.get("name", "Canteen")},
            "rec_room": {"name": rr.get("name", "Rec Room")},
        }
        if sr:
            payload["shared"]["server_room"] = {"name": sr.get("name", "Server Room")}
        try:
            with open(self.office_path, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            log.info("saved office roster -> %s (%d agents)", self.office_path, len(self.agents))
        except OSError as exc:
            log.error("could not save office %s: %s", self.office_path, exc)

    def bind_default_cli(self, agent_id: str, role: str = "") -> None:
        """Ensure a newly hired agent has a Claude binding in agent_cmds.json + live CliRunner."""
        # Live map is owned by Harness via on_hired; here we only persist the file template.
        path = self.cmds_path
        if not path:
            return
        try:
            data = {}
            if os.path.exists(path):
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            if not isinstance(data, dict):
                data = {}
            if agent_id in data:
                return
            # Prefer an explicit job dict from the live agent if present.
            job = {}
            live = self.agents.get(agent_id)
            if live is not None and getattr(live, "job", None):
                job = dict(live.job)
            data[agent_id] = {
                "cmd": "claude -p --output-format text {prompt}",
                "cwd": ".",
                "system": format_job_system_prompt(job, name=agent_id, role=role),
            }
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(data, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            log.info("added CLI binding for %s -> %s", agent_id, path)
        except (OSError, ValueError) as exc:
            log.error("could not update agent cmds %s: %s", path, exc)

    async def _action_hire(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        """Spawn a new agent at a desk (recruiter desk / harness hire). Plays AGENT_HIRE FX."""
        agent_id = str(msg.get("agent_id", "")).strip()
        name = str(msg.get("name", "")).strip() or agent_id.replace("_", " ").title()
        desk = str(msg.get("desk", "")).strip()
        color = str(msg.get("color", "")).strip() or "#5c6bc0"
        role = str(msg.get("role", "")).strip() or "New Hire"
        room = str(msg.get("room", "")).strip()
        job_raw = msg.get("job") if isinstance(msg.get("job"), dict) else {}
        job: dict[str, Any] = dict(job_raw)
        if not job.get("title"):
            job["title"] = role
        if not job.get("department") and room:
            # department filled later from room name when known
            pass
        if not agent_id:
            await self.reply(ws, {"type": "ERROR", "action": "HIRE_AGENT", "message": "agent_id required"})
            return
        if agent_id in self.agents:
            await self.reply(ws, {"type": "ERROR", "action": "HIRE_AGENT",
                                  "message": f"agent '{agent_id}' already exists"})
            return

        # UNIQUE_ROLE_GUARD: reject second hire of catalog roles marked unique
        role_id = str(msg.get("role_id", "") or job.get("role_id", "") or "").strip()
        if role_id or role:
            try:
                cat_path = Path(__file__).resolve().parent / "roles" / "catalog.json"
                if cat_path.exists():
                    cat = json.loads(cat_path.read_text(encoding="utf-8"))
                    roles = cat.get("roles") or []
                    match = None
                    for r in roles:
                        if role_id and r.get("id") == role_id:
                            match = r
                            break
                        if role and (r.get("short_title") == role or r.get("title") == role or r.get("default_name") == role):
                            match = r
                            break
                    if match and match.get("unique"):
                        short = match.get("short_title") or match.get("title") or role
                        aliases = {
                            str(short).strip().lower(),
                            str(match.get("title") or "").strip().lower(),
                            str(match.get("default_name") or "").strip().lower(),
                            str(match.get("short_title") or "").strip().lower(),
                        }
                        aliases.discard("")
                        mid = match.get("id")
                        for a in self.agents.values():
                            ar = str(getattr(a, "role", "") or "").strip().lower()
                            an = str(getattr(a, "name", "") or getattr(a, "display_name", "") or "").strip().lower()
                            aj = getattr(a, "job", None) or {}
                            aj_st = str(aj.get("short_title", "") if isinstance(aj, dict) else "").strip().lower()
                            aj_ti = str(aj.get("title", "") if isinstance(aj, dict) else "").strip().lower()
                            aj_rid = aj.get("role_id") if isinstance(aj, dict) else None
                            if (
                                ar in aliases
                                or an in aliases
                                or aj_st in aliases
                                or aj_ti in aliases
                                or (mid and aj_rid == mid)
                                or (short and short.lower() in ar)
                                or (short and short.lower() in an)
                            ):
                                await self.reply(ws, {
                                    "type": "ERROR",
                                    "action": "HIRE_AGENT",
                                    "message": f"Already hired: {short} (unique role)",
                                    "code": "ALREADY_HIRED",
                                    "role_id": match.get("id"),
                                })
                                return
            except Exception:
                log.exception("unique-role check failed")
        if not desk:
            # Pick a free Desk_* waypoint name from the office layout if possible.
            used = {a.desk for a in self.agents.values()}
            office = self.office or {}
            candidates: list[str] = []
            for r in office.get("rooms", []) or []:
                for m in r.get("members", []) or []:
                    d = str(m.get("desk", "") or f"Desk_{m.get('agent_id', '')}")
                    if d and d not in used:
                        candidates.append(d)
                # Also allow synthetic free desks for the room.
                rid = str(r.get("id", "team"))
                for i in range(1, 9):
                    d = f"Desk_{rid}_free_{i}"
                    if d not in used:
                        candidates.append(d)
            desk = candidates[0] if candidates else f"Desk_{agent_id}"
        if not room:
            room = "special_projects"
            for r in (self.office or {}).get("rooms", []) or []:
                for m in r.get("members", []) or []:
                    if str(m.get("desk", "")) == desk or str(m.get("agent_id", "")) == agent_id:
                        room = str(r.get("id", room))
        # Attach room amenities so ambient life works for the new hire.
        room_meta = next((r for r in (self.office or {}).get("rooms", []) if r.get("id") == room), None)
        extra: dict[str, Any] = {"room": room}
        if room_meta:
            extra["break_spots"] = tuple(room_meta.get("break_spots") or SHARED_BREAK_SPOTS)
            extra["chat_spots"] = tuple(room_meta.get("chat_spots") or SHARED_CHAT_SPOTS)
            extra["meeting_target"] = room_meta.get("meeting_target") or MEETING_TARGET
            extra["group"] = room if room_meta.get("isolated") else SHARED_GROUP
        if room_meta and not job.get("department"):
            job["department"] = str(room_meta.get("name") or room)
        extra["job"] = job
        agent = self.hire(agent_id, name, desk, color, role=role, **extra)
        # Persist into office.json roster.
        if self.office:
            target = room_meta
            if target is None:
                for r in self.office.get("rooms", []):
                    if r.get("id") == room:
                        target = r
                        break
            if target is not None:
                target.setdefault("members", []).append({
                    "agent_id": agent_id, "name": name, "role": role, "color": color, "desk": desk,
                    "job": job,
                })
                target["desks"] = max(int(target.get("desks", 0) or 0), len(target["members"]))
            self.save_office()
        self.bind_default_cli(agent_id, role)
        if self.on_hired:
            try:
                self.on_hired(agent)
            except Exception:
                log.exception("on_hired failed for %s", agent_id)
        log.info("HIRE_AGENT %s (%s) at %s", agent_id, name, desk)
        await self.reply(ws, {"type": "ACK", "action": "HIRE_AGENT", "agent_id": agent_id,
                              "name": name, "desk": desk, "room": room})

    async def _action_fire(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        """Archive / remove an agent. Plays AGENT_FIRE (medics + stretcher) then clears desk."""
        agent_id = str(msg.get("agent_id", "")).strip()
        if not agent_id or agent_id not in self.agents:
            await self.reply(ws, {"type": "ERROR", "action": "FIRE_AGENT",
                                  "message": f"unknown agent '{agent_id}'"})
            return
        # Protect the recruiter itself from accidental archive via preview.
        if agent_id == "dr_eggbot" and not msg.get("force"):
            await self.reply(ws, {"type": "ERROR", "action": "FIRE_AGENT",
                                  "message": "won't archive the recruiter (pass force=true to override)"})
            return
        agent = self.unregister(agent_id)
        if self.office:
            archived_member = None
            for r in self.office.get("rooms", []):
                members = r.get("members") or []
                keep = []
                for m in members:
                    if m.get("agent_id") == agent_id:
                        archived_member = dict(m)
                        archived_member["archived_at"] = now_ms()
                        archived_member["archived_from_room"] = r.get("id")
                    else:
                        keep.append(m)
                r["members"] = keep
            if archived_member is None and agent is not None:
                archived_member = {
                    "agent_id": agent_id,
                    "name": agent.name,
                    "role": agent.role,
                    "color": agent.color,
                    "job": dict(agent.job or {}),
                    "archived_at": now_ms(),
                    "archived_from_room": agent.room,
                }
            if archived_member is not None:
                self.office.setdefault("archived", []).append(archived_member)
            self.save_office()
        if self.on_fired:
            try:
                self.on_fired(agent_id)
            except Exception:
                log.exception("on_fired failed for %s", agent_id)
        log.info("FIRE_AGENT / archive %s", agent_id)
        await self.reply(ws, {"type": "ACK", "action": "FIRE_AGENT", "agent_id": agent_id,
                              "name": agent.name if agent else agent_id})

    async def _action_preview_hire_fire(self, ws: ServerConnection, msg: dict[str, Any]) -> None:
        """Demo the hire and/or fire pageantry without permanently changing the roster.
        which: hire | fire | both (default both).
        Optional variant / alias (ambulance, ufo, …; medics→ambulance) forces the fire FX.
        """
        which = str(msg.get("which", "both")).strip().lower() or "both"
        preview_id = str(msg.get("agent_id", "preview_hire")).strip() or "preview_hire"
        variant = str(msg.get("variant", "") or "").strip().lower()
        log.info("PREVIEW_HIRE_FIRE which=%s id=%s variant=%s", which, preview_id, variant or "-")

        async def _hire_temp() -> None:
            if preview_id in self.agents:
                self.unregister(preview_id)
            desk = str(msg.get("desk", f"Desk_{preview_id}"))
            self.hire(preview_id, "Preview Hire", desk, "#ffd54f",
                      role="Temp", room=str(msg.get("room", "special_projects")))

        async def _fire_temp() -> None:
            if preview_id not in self.agents:
                await _hire_temp()
                await asyncio.sleep(1.8)  # let hire FX play
            self.unregister(preview_id, variant=variant)

        if which in ("hire", "both"):
            await _hire_temp()
            if which == "hire":
                async def _cleanup() -> None:
                    await asyncio.sleep(2.5)
                    if preview_id in self.agents:
                        self.agents.pop(preview_id, None)
                        self.emit(self.snapshot())
                asyncio.create_task(_cleanup())
        if which in ("fire", "both"):
            if which == "both":
                await asyncio.sleep(1.9)
            await _fire_temp()
        await self.reply(ws, {"type": "ACK", "action": "PREVIEW_HIRE_FIRE", "which": which,
                              "agent_id": preview_id, "variant": variant})


# ---------------------------------------------------------------------------
# Runners
# ---------------------------------------------------------------------------
class MockRunner:
    """Scripted, fake agent work for DISPATCH_PROMPT in mock mode."""

    def __init__(self, hub: Hub, speed: float = 1.0) -> None:
        self.hub = hub
        self.speed = max(0.05, speed)

    async def sleep(self, seconds: float) -> None:
        await asyncio.sleep(seconds / self.speed)

    async def run_prompt(self, agent: Agent, prompt: str) -> None:
        hub, aid = self.hub, agent.agent_id
        profile = role_profile(agent)
        short = prompt if len(prompt) <= 40 else prompt[:37] + "..."
        files = re.findall(r"[\w./-]+\.(?:py|ts|js|go|rs|gd|md|json|kt|swift|tf)", prompt)
        task = f"Editing {files[0]}" if files else random.choice(profile.topics)[1]

        hub.log_line(aid, f"\x1b[1;36m> {prompt}\x1b[0m", important=True)
        hub.state(aid, "THINKING", text=f"Reading: {short}")
        await self.sleep(1.5)
        hub.log_line(aid, "\x1b[2mLoading context...\x1b[0m")
        hub.state(aid, "THINKING", text=random.choice(profile.topics)[0])
        await self.sleep(1.5)
        hub.state(aid, "WORKING", target=agent.desk, text=task)
        await self.sleep(2.0)
        for line in random.sample(profile.logs, k=min(3, len(profile.logs))):
            hub.log_line(aid, profile.fill(line))
            await self.sleep(1.2)
        hub.log_line(aid, f"\x1b[1;32m\u2714 Done:\x1b[0m {prompt}", important=True)
        spot = random.choice(agent.break_spots)
        hub.state(aid, "IDLE", target=spot, text="Done! Coffee time." if "Coffee" in spot else "Done!")


# ---------------------------------------------------------------------------
# Ambient simulation
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Tempo:
    """Timing profile for the ambient simulation. All values are simulated
    seconds (divided by --speed for wall-clock time); tuples are (min, max)."""

    work: tuple[float, float]          # length of one focused desk session
    log_every: tuple[float, float]     # gap between trickled log lines while working
    think_chance: float                # chance a log tick becomes a short THINKING pause
    think: tuple[float, float]         # length of a THINKING pause (agent stays seated)
    break_chance: float                # chance a finished session ends in a break-room visit
    break_time: tuple[float, float]    # time spent at the coffee machine / water cooler
    collab_every: tuple[float, float]  # gap between ambient meetings
    collab_time: tuple[float, float]   # meeting length
    chat_every: tuple[float, float]    # gap between meeting / break-room speech bubbles
    walk_slot: float                   # assumed walk time; only one ambient walk starts per slot
    foosball_every: tuple[float, float] = (300, 600)  # gap between foosball games (shared break room)
    foosball_time: tuple[float, float] = (40, 80)     # length of a game
    chat_group_every: tuple[float, float] = (90, 180)  # gap between small-talk groups
    chat_time: tuple[float, float] = (30, 60)         # how long a chat lasts


TEMPOS: dict[str, Tempo] = {
    "calm": Tempo(work=(20, 60), log_every=(5, 12), think_chance=0.15, think=(4, 8), break_chance=0.55,
                  break_time=(15, 30), collab_every=(180, 360), collab_time=(25, 45), chat_every=(7, 12),
                  walk_slot=2.5, foosball_every=(300, 600), foosball_time=(40, 80), chat_group_every=(60, 150),
                  chat_time=(30, 60)),
    "normal": Tempo(work=(12, 30), log_every=(3, 7), think_chance=0.2, think=(3, 6), break_chance=0.4,
                    break_time=(10, 20), collab_every=(60, 120), collab_time=(15, 30), chat_every=(5, 9),
                    walk_slot=4, foosball_every=(120, 240), foosball_time=(25, 45), chat_group_every=(40, 90),
                    chat_time=(20, 40)),
    "busy": Tempo(work=(4, 10), log_every=(1, 3), think_chance=0.25, think=(1.5, 3), break_chance=0.6,
                  break_time=(4, 8), collab_every=(15, 30), collab_time=(8, 15), chat_every=(2, 4),
                  walk_slot=1.5, foosball_every=(30, 60), foosball_time=(10, 20), chat_group_every=(10, 25),
                  chat_time=(10, 20)),
}

@dataclass(frozen=True)
class RoleProfile:
    """Believable (entirely made-up) activity for one kind of agent."""

    topics: list[tuple[str, str]]  # (thinking bubble, working bubble)
    logs: list[str]                # log line templates: {file} {a} {b} {c} {n}

    def fill(self, line: str) -> str:
        return line.format(file=random.choice(["main.py", "auth.py", "utils.py", "api.ts"]),
                           a=random.randint(2, 40), b=random.randint(0, 9), c=random.randint(12, 98),
                           n=random.randint(3, 30))


D, G, Y, B, M, C, R0 = "\x1b[2m", "\x1b[32m", "\x1b[33m", "\x1b[34m", "\x1b[35m", "\x1b[36m", "\x1b[0m"

# Matched against "<agent_id> <role>" in order; first keyword hit wins.
ROLE_PROFILES: list[tuple[tuple[str, ...], RoleProfile]] = [
    (("ios",), RoleProfile(
        [("Checking provisioning...", "xcodebuild archive"), ("SwiftUI layout bug?", "Editing ContentView.swift"),
         ("Reading crash log...", "Running XCTest")],
        [f"{D}$ xcodebuild -scheme App -configuration Release archive{R0}", f"{G}** ARCHIVE SUCCEEDED **{R0}",
         f"{Y}warning:{R0} 'UIScreen.main' is deprecated", f"{D}$ xcodebuild test -destination 'platform=iOS Simulator'{R0}",
         f"{G}Test Suite 'All tests' passed ({{c}} tests){R0}"])),
    (("android",), RoleProfile(
        [("Gradle sync...", "./gradlew assembleRelease"), ("Compose recomposition?", "Editing MainActivity.kt"),
         ("Reading ANR trace...", "Running instrumented tests")],
        [f"{D}$ ./gradlew assembleRelease{R0}", f"{G}BUILD SUCCESSFUL in {{a}}s{R0}",
         f"{Y}w:{R0} Parameter 'savedInstanceState' is never used", f"{D}> Task :app:lintVitalRelease{R0}",
         f"{G}{{c}} tests completed, 0 failed{R0}"])),
    (("devops", "aws"), RoleProfile(
        [("Reviewing IAM policy...", "terraform plan"), ("Why is CI slow?", "Tuning the pipeline"),
         ("Checking alarms...", "Rotating log groups")],
        [f"{D}$ terraform plan -out tfplan{R0}", f"{G}Plan: {{b}} to add, {{b}} to change, 0 to destroy.{R0}",
         f"{C}cdk{R0} diff: no differences", f"{D}$ aws cloudwatch describe-alarms --state-value ALARM{R0}",
         f"{G}All alarms OK{R0}", f"{Y}pipeline{R0} build #{{c}} queued"])),
    (("diagram",), RoleProfile(
        [("Where do the arrows go?", "Rendering diagram.mmd"), ("Simplify this view...", "Updating C4 context")],
        [f"{D}$ mmdc -i system.mmd -o system.svg{R0}", f"{G}Generating single mermaid chart{R0}",
         f"{B}[diagram]{R0} Added {{b}} components, {{a}} edges", f"{D}Exported context.png ({{c}} KB){R0}"])),
    (("architect",), RoleProfile(
        [("Weighing trade-offs...", "Drafting ADR"), ("Mapping dependencies...", "Reviewing module boundaries")],
        [f"{B}[design]{R0} Updated section {{a}} of the ADR", f"{D}Reviewing module boundaries ({{c}} deps){R0}",
         f"{B}[design]{R0} Proposed interface: Provider.verify()"])),
    (("product", "manager"), RoleProfile(
        [("Prioritising backlog...", "Grooming the roadmap"), ("What do users need?", "Writing release notes")],
        [f"{C}[roadmap]{R0} Moved {{b}} items to Next", f"{D}Reviewing {{n}} open tickets{R0}",
         f"{G}Release notes drafted{R0}"])),
    (("finance",), RoleProfile(
        [("Matching transactions...", "Reconciling Betashares..."), ("Checking categories...", "Preparing monthly summary")],
        [f"{D}Reconciling statement lines ({{n}} pending){R0}", f"{G}Matched {{c}} transactions{R0}",
         f"{Y}review:{R0} {{b}} items need a category", f"{D}Building cash-flow summary...{R0}"])),
    (("retirement",), RoleProfile(
        [("Stress-testing assumptions...", "Projecting scenarios"), ("Reviewing drawdown...", "Updating the plan")],
        [f"{D}Running {{c}}0 Monte Carlo paths{R0}", f"{G}Scenario set updated{R0}",
         f"{Y}note:{R0} assumptions due for review"])),
    (("travel",), RoleProfile(
        [("Comparing routes...", "Searching flights"), ("Checking visas...", "Drafting itinerary")],
        [f"{D}Comparing {{n}} fare options{R0}", f"{G}Itinerary draft ready{R0}", f"{Y}heads-up:{R0} tight connection"])),
    (("support",), RoleProfile(
        [("Reading ticket...", "Triaging tickets"), ("Reproducing issue...", "Drafting a reply")],
        [f"{D}Inbox: {{n}} open tickets{R0}", f"{G}Resolved ticket #{{c}}{{a}}{R0}",
         f"{Y}escalate?{R0} needs a human look", f"{D}Updating help-centre article{R0}"])),
    (("odoo",), RoleProfile(
        [("Checking sync...", "Syncing Odoo records"), ("Which module?", "Updating Odoo tasks")],
        [f"{D}odoo: fetched {{n}} tasks{R0}", f"{G}odoo: {{b}} records updated{R0}", f"{D}Running scheduled actions...{R0}"])),
    (("powerbrain",), RoleProfile(
        [("Linking sources...", "Indexing knowledge base"), ("Summarising...", "Answering a question")],
        [f"{D}Indexed {{c}} documents{R0}", f"{G}Embeddings refreshed{R0}", f"{C}[kb]{R0} {{b}} new links"])),
    (("chief", "staff"), RoleProfile(
        [("Who should own this?", "Routing tasks"), ("Reviewing priorities...", "Writing the daily brief")],
        [f"{C}[brief]{R0} {{n}} items for today", f"{D}Delegated {{b}} tasks{R0}", f"{G}Status board updated{R0}"])),
    (("ea",), RoleProfile(
        [("Checking the calendar...", "Scheduling meetings"), ("Drafting...", "Preparing reminders")],
        [f"{D}Calendar: {{b}} conflicts checked{R0}", f"{G}Reminders queued{R0}", f"{D}Inbox triage: {{n}} items{R0}"])),
    (("graphic", "artist"), RoleProfile(
        [("Picking a palette...", "Rendering artwork"), ("Hmm, contrast...", "Exporting assets")],
        [f"{D}Rendering 1024x1024 ...{R0}", f"{G}Exported {{b}} variants{R0}", f"{M}[art]{R0} new colour palette"])),
    (("seo", "aeo"), RoleProfile(
        [("Which queries?", "Crawling sitemap"), ("Answer-engine angle...", "Writing structured data")],
        [f"{D}Crawled {{c}} URLs{R0}", f"{Y}warn:{R0} {{b}} pages missing meta descriptions", f"{G}JSON-LD validated{R0}"])),
    (("outbound", "prospect"), RoleProfile(
        [("Who's a good fit?", "Researching prospects"), ("Tone check...", "Drafting outreach")],
        [f"{D}Shortlisted {{b}} prospects{R0}", f"{G}{{b}} drafts ready for review{R0}", f"{D}Enriching company notes...{R0}"])),
    (("eggbot", "designer"), RoleProfile(
        [("What should this bot do?", "Designing a bot"), ("Testing prompts...", "Writing bot instructions")],
        [f"{M}[bot]{R0} Drafted persona + tools", f"{D}Running {{b}} test conversations{R0}", f"{G}Bot spec ready{R0}"])),
    (("research",), RoleProfile(
        [("Reading papers...", "Running experiments"), ("Is this significant?", "Writing findings")],
        [f"{D}Reading {{b}} papers{R0}", f"{C}[exp]{R0} run {{c}} finished", f"{G}Notes updated{R0}"])),
    (("coder",), RoleProfile(
        [("Analyzing AST...", "Editing main.py"), ("Reading stack trace...", "Patching auth.py"),
         ("Planning refactor...", "Refactoring utils.py")],
        [f"{Y}Edit{R0} {{file}}: +{{a}} -{{b}}", f"{D}$ ruff check .{R0}", f"{G}All checks passed!{R0}",
         f"{C}tool{R0} grep -n \"def login\" -r src/"])),
    (("qa", "test"), RoleProfile(
        [("Reviewing diff...", "Writing test_auth.py"), ("Triaging flaky test...", "Running pytest")],
        [f"{D}$ pytest -q --color=yes{R0}", f"{G}Running tests: {{c}} passed, 0 failed.{R0}",
         f"{Y}flaky?{R0} test_session_timeout took {{a}}.{{b}}s", f"{D}coverage: {{c}}%{R0}"])),
]
DEFAULT_PROFILE = RoleProfile([("Thinking...", "Working")], [f"{D}working...{R0}", f"{G}step done{R0}"])


def role_profile(agent: Agent) -> RoleProfile:
    key = f"{agent.agent_id} {agent.role} {agent.name}".lower()
    words = set(re.split(r"[^a-z0-9]+", key))
    for keywords, profile in ROLE_PROFILES:
        if any((k in words) if len(k) <= 3 else (k in key) for k in keywords):
            return profile
    return DEFAULT_PROFILE


BREAK_CHATTER = ["Anyone seen the CI logs?", "This coffee is compiling...", "Need a refactor break.",
                 "Ship it!", "Who broke main?", "Tabs or spaces?", "Nice weather for a deploy."]
FOOSBALL_CHATTER = ["Goal!", "GOAL!", "Spin it!", "Rematch?", "Nice save!", "Best of five?"]
YOGA_CHATTER = ["Tree pose…", "Breathe in…", "Stretch it out.", "Downward dog.", "Namaste."]
MEDITATE_CHATTER = ["…", "Om.", "Clearing the mind.", "Just breathing.", "Peace."]
MEETING_CHATTER = ["Agreed.", "What about edge cases?", "Let's split the PR.", "I'll write the tests.",
                   "Can we cache that?", "Ship behind a flag?", "Who owns the migration?"]
# Office small talk: (opener, reply) pairs, then a few follow-ups. Kept light,
# varied and work-neutral so it never reads like a status update.
SMALL_TALK: list[tuple[str, str]] = [
    ("Good weekend?", "Too short. Yours?"),
    ("Is the coffee machine behaving?", "Give it a thump first."),
    ("Lunch at the noodle place?", "Only if we beat the queue."),
    ("See the footy last night?", "Don't. Still recovering."),
    ("Who keeps taking my mug?", "Not me. Probably."),
    ("Rain's coming this arvo.", "Brought an umbrella for once."),
    ("Any plans for the weekend?", "Garden, then a long nap."),
    ("These new chairs are comfy.", "Mine squeaks. Want to swap?"),
    ("There's cake in the kitchen!", "Whose birthday is it?"),
    ("Tea or coffee today?", "Coffee. Definitely coffee."),
    ("How's the new place?", "Still living out of boxes."),
    ("Tried the new vending snacks?", "The salt and vinegar ones, yes."),
    ("Trams were packed this morning.", "I walked. Took forever."),
    ("Watching anything good?", "Halfway through a crime series."),
    ("Is it Friday yet?", "Feels like Thursday again."),
    ("Nice jacket!", "Op shop find. Ten bucks."),
    ("Bring your dog in again?", "She'd love that."),
    ("Heading to the gym later?", "That's the plan, anyway."),
]
SMALL_TALK_MORE = ["Ha, fair enough.", "Same here.", "Classic.", "Oh, nice.", "Tell me about it.",
                   "Count me in.", "Good shout.", "No way!", "True, true.", "Right?"]
SOLO_BREAK = ["Ah, that's better.", "Mmm, coffee.", "Just a quick stretch.", "Back in five."]
# Notifications that reach an agent while it is away from its desk; the Godot
# client shows the agent pulling out its phone for each LOG_ENTRY it gets.
AWAY_PINGS = ["background job finished: {w}", "new message about {w}", "reminder: {w}",
              "review requested: {w}", "queue update: {w}"]


class AmbientDirector:
    """Keeps the office alive without constant running around.

    Mock mode: each agent mostly sits at its desk in long, randomised work
    sessions with role-flavoured log lines trickling in and the odd THINKING
    pause (no movement). After a session there is a small chance of a
    break-room visit; every few minutes 2-3 desk-bound agents of the same
    group hold a meeting, two to four play foosball, and small groups stop for
    a chat.

    Idle-only (live mode): no fake work at all. Agents that aren't busy with a
    real report sit at their desk with the screen dark, wander to the coffee
    machine, water cooler, vending machine, sofa or Rec Room (yoga/meditation),
    play foosball, gather in
    pairs or threes for small talk and glance at their phones (AMBIENT events,
    no log lines). A real report always wins: the agent is skipped while the
    report's hold runs, and "finish" hands it straight back (Hub.on_release).

    Ambient walks are rate-limited by a single global "walk slot", so normally
    only one agent starts walking at a time (a meeting, chat or game moves its
    players together). Agents in an isolated room (e.g. the PTC wing) only use
    their own wing's amenities and only meet / chat with each other. Agents
    busy with a user prompt (lock held or prompt queued) are left alone.
    """

    def __init__(self, hub: Hub, tempo: Tempo, speed: float, agent_filter: Callable[[Agent], bool],
                 idle_only: bool = False) -> None:
        self.hub = hub
        self.tempo = tempo
        self.speed = max(0.05, speed)
        self.agent_filter = agent_filter
        self.idle_only = idle_only
        self.t0 = time.monotonic()
        self.walk_free_at = 0.0
        self.next_collab_at = self.rand(tempo.collab_every) * 0.5
        self.next_foosball_at = self.rand(tempo.foosball_every) * (0.15 if idle_only else 0.5)
        self.next_chat_at = self.rand(tempo.chat_group_every) * 0.3
        self.next_canteen_at = self.rand((90, 180))
        self.next_rec_at = 25.0
        # spot name -> {"members": [Agent], "until", "next_at", "turn", "topic"}
        self.chats: dict[str, dict[str, Any]] = {}

    def now(self) -> float:
        """Simulated seconds since start."""
        return (time.monotonic() - self.t0) * self.speed

    @staticmethod
    def rand(span: tuple[float, float]) -> float:
        return random.uniform(*span)

    def can_walk(self) -> bool:
        # Two independent walk slots (A/B) so calm offices with many agents still move.
        now = self.now()
        a = getattr(self, "walk_free_at", 0.0)
        b = getattr(self, "walk_free_at_b", 0.0)
        return now >= a or now >= b

    def reserve_walk(self, factor: float = 1.0) -> None:
        now = self.now()
        slot = self.tempo.walk_slot * factor
        a = getattr(self, "walk_free_at", 0.0)
        b = getattr(self, "walk_free_at_b", 0.0)
        if now >= a:
            self.walk_free_at = now + slot
        else:
            self.walk_free_at_b = now + slot

    def desk_span(self) -> tuple[float, float]:
        """Time at the desk between ambient activities."""
        t = self.tempo.work
        # Idle-only: shorter sits so the office still wanders (walk / canteen / chat).
        # Mock/cli: also shorten vs raw tempo so calm offices are visibly alive.
        if self.idle_only:
            return (t[0] * 0.45, t[1] * 0.7)
        return (t[0] * 0.55, t[1] * 0.75)

    def place_initial(self, agent: Agent) -> None:
        """Agents start seated at their desks (staggered session ends)."""
        agent.state, agent.target, agent.activity = ("IDLE" if self.idle_only else "WORKING"), agent.desk, "desk"
        agent.text = ""
        # Always stagger so the floor does not sit frozen for a full desk_span.
        agent.activity_until = self.rand(self.desk_span()) * random.uniform(0.08, 0.55)
        agent.next_event_at = self.rand(self.tempo.log_every) + random.uniform(0, 6)

    def after_prompt(self, agent: Agent) -> None:
        """A prompt run (or a real "finish") ended at a break spot: linger
        there, then return to the desk."""
        now = self.now()
        agent.activity = "break"
        agent.thinking_until = 0.0
        agent.activity_until = now + self.rand(self.tempo.break_time)
        agent.next_event_at = now + self.rand(self.tempo.chat_every)

    after_finish = after_prompt

    def free(self, agent: Agent) -> bool:
        if agent.live_until:
            if agent.is_live():
                return False  # real status reports own this agent for now
            self.resume(agent)
        return self.agent_filter(agent) and not agent.lock.locked() and agent.queue.empty()

    def resume(self, agent: Agent) -> None:
        """The live hold ran out: pick the simulation back up from where the
        last real report left the agent (a short linger, then the usual cycle)."""
        agent.live_until = 0.0
        now = self.now()
        agent.thinking_until = 0.0
        if agent.activity not in ("desk", "break"):
            agent.activity = "desk"
        span = self.tempo.break_time if agent.activity == "break" else self.desk_span()
        agent.activity_until = now + self.rand(span) * 0.5
        agent.next_event_at = now + self.rand(self.tempo.log_every)
        if self.idle_only:
            # A bot that went quiet without "finish": stop showing it as busy.
            if agent.state != "IDLE":
                self.hub.state(agent.agent_id, "IDLE", target=agent.desk if agent.activity == "desk" else None)
        elif agent.state == "ERROR":
            self.hub.state(agent.agent_id, "WORKING", text="Back to it.")

    async def run(self) -> None:
        while True:
            self.tick()
            await asyncio.sleep(0.5)

    def tick(self) -> None:
        now = self.now()
        agents = [a for a in self.hub.agents.values() if self.free(a)]
        random.shuffle(agents)  # no agent always gets the walk slot first
        for agent in agents:
            if agent.activity == "desk":
                (self._idle_desk if self.idle_only else self._desk)(agent, now)
            elif agent.activity == "break":
                self._away(agent, now, SOLO_BREAK if self.idle_only else BREAK_CHATTER,
                           chat_chance=0.12 if self.idle_only else 0.3, state="IDLE")
            elif agent.activity == "meeting":
                self._away(agent, now, MEETING_CHATTER, chat_chance=0.7, state="COLLAB")
            elif agent.activity == "canteen":
                # Counter -> seat -> desk.
                seat = getattr(agent, "_canteen_seat", None)
                food = getattr(agent, "_canteen_food", "lunch")
                eat_until = getattr(agent, "_canteen_eat_until", agent.activity_until)
                if seat and agent.target == CANTEEN_COUNTER and now >= agent.activity_until:
                    self.hub.state(agent.agent_id, "IDLE", target=seat, text=f"Eating {food}")
                    agent.activity_until = eat_until
                    agent.target = seat
                elif now >= agent.activity_until:
                    agent.activity = "desk"
                    self.hub.state(agent.agent_id, "IDLE", target=agent.desk, text="Back to it.")
                    for attr in ("_canteen_seat", "_canteen_food", "_canteen_eat_until"):
                        if hasattr(agent, attr):
                            delattr(agent, attr)
            elif agent.activity == "foosball":
                self._away(agent, now, FOOSBALL_CHATTER, chat_chance=0.6, state="IDLE")
            elif agent.activity == "yoga":
                self._away(agent, now, YOGA_CHATTER, chat_chance=0.25, state="IDLE")
            elif agent.activity == "meditation":
                self._away(agent, now, MEDITATE_CHATTER, chat_chance=0.18, state="IDLE")
        self._chat_tick(now)
        if not self.idle_only:
            self._maybe_meeting(now, agents)
        self._maybe_foosball(now, agents)
        self._maybe_canteen(now, agents)
        self._maybe_rec(now, agents)
        self._maybe_chat(now, agents)

    # -- per-activity behaviour ----------------------------------------------
    def _back_to_desk(self, agent: Agent, now: float) -> None:
        agent.activity = "desk"
        agent.activity_until = now + self.rand(self.desk_span())
        agent.next_event_at = now + self.rand(self.tempo.log_every)
        if self.idle_only:
            self.hub.state(agent.agent_id, "IDLE", target=agent.desk)
        else:
            self.hub.state(agent.agent_id, "WORKING", target=agent.desk, text=random.choice(role_profile(agent).topics)[1])

    def _phone(self, agent: Agent) -> None:
        """Idle phone glance: a visual cue only (no log line, no state change)."""
        self.hub.emit({"type": "AMBIENT", "agent_id": agent.agent_id, "action": "phone",
                       "seconds": round(random.uniform(3.0, 6.0), 1)})


    def _start_rec_or_break(self, agent: Agent, now: float, spot: str | None = None) -> None:
        """Walk to a break/rec spot. Rec Room spots get yoga/meditation for 20–40s."""
        if spot is None:
            spot = random.choice(agent.break_spots)
        hub, aid = self.hub, agent.agent_id
        if spot.startswith("Yoga_"):
            agent.activity = "yoga"
            agent.activity_until = now + random.uniform(20.0, 40.0)
            agent.next_event_at = now + random.uniform(6.0, 12.0)
            hub.state(aid, "IDLE", target=spot, text="Yoga break.")
            hub.emit({"type": "AMBIENT", "agent_id": aid, "action": "yoga",
                      "seconds": round(agent.activity_until - now, 1)})
            hub.log_line(aid, "\x1b[35m[rec]\x1b[0m Walking to the Rec Room for yoga.")
        elif spot.startswith("Meditation_"):
            agent.activity = "meditation"
            agent.activity_until = now + random.uniform(20.0, 40.0)
            agent.next_event_at = now + random.uniform(8.0, 14.0)
            hub.state(aid, "IDLE", target=spot, text="Meditating.")
            hub.emit({"type": "AMBIENT", "agent_id": aid, "action": "meditate",
                      "seconds": round(agent.activity_until - now, 1)})
            hub.log_line(aid, "\x1b[35m[rec]\x1b[0m Heading to the Rec Room to meditate.")
        else:
            agent.activity = "break"
            agent.activity_until = now + self.rand(self.tempo.break_time) * (1.5 if self.idle_only else 1.0)
            agent.next_event_at = now + self.rand(self.tempo.chat_every)
            text = {"Coffee": "Coffee time.", "Water": "Grabbing some water.", "Sofa": "Quick breather.",
                    "Vending": "Snack run."}
            hub.state(aid, "IDLE", target=spot,
                      text=next((v for k, v in text.items() if k in spot), "Short break."))

    def _idle_desk(self, agent: Agent, now: float) -> None:
        """Idle-only desk time: seated, screen dark, the odd phone glance, then
        maybe a wander to a break spot."""
        t = self.tempo
        if now >= agent.activity_until:
            if random.random() < 0.72 and self.can_walk():
                self.reserve_walk()
                self._start_rec_or_break(agent, now)
                return
            agent.activity_until = now + self.rand(self.desk_span()) * 0.5
        if now >= agent.next_event_at:
            agent.next_event_at = now + self.rand(t.log_every) * 6.0
            if random.random() < 0.35:
                self._phone(agent)

    def _desk(self, agent: Agent, now: float) -> None:
        hub, aid, t = self.hub, agent.agent_id, self.tempo
        profile = role_profile(agent)
        if agent.thinking_until and now >= agent.thinking_until:
            agent.thinking_until = 0.0
            hub.state(aid, "WORKING", text=random.choice(profile.topics)[1])
        if now >= agent.activity_until and not agent.thinking_until:
            if random.random() < t.break_chance and self.can_walk():
                self.reserve_walk()
                self._start_rec_or_break(agent, now)
                return
            # Keep working: start a fresh session in place (no walking).
            agent.activity_until = now + self.rand(t.work)
        if now >= agent.next_event_at and not agent.thinking_until:
            agent.next_event_at = now + self.rand(t.log_every)
            if random.random() < t.think_chance:
                agent.thinking_until = now + self.rand(t.think)
                hub.state(aid, "THINKING", text=random.choice(profile.topics)[0])
            else:
                hub.log_line(aid, profile.fill(random.choice(profile.logs)))
                if agent.state != "WORKING":
                    hub.state(aid, "WORKING")

    def _away(self, agent: Agent, now: float, chatter: list[str], chat_chance: float, state: str) -> None:
        hub, aid, t = self.hub, agent.agent_id, self.tempo
        if now >= agent.activity_until:
            if self.can_walk():
                self.reserve_walk()
                self._back_to_desk(agent, now)
            return
        if now >= agent.next_event_at:
            calm = 2.0 if self.idle_only and agent.activity == "break" else 1.0
            agent.next_event_at = now + self.rand(t.chat_every) * calm
            roll = random.random()
            if roll < chat_chance:
                line = random.choice(chatter)
                hub.state(aid, state, text=line)
                if state == "COLLAB":
                    hub.emit({"type": "MEETING_TURN", "agent_id": aid, "text": line,
                              "target": getattr(agent, "meeting_target", None) or "Meeting_Room"})
            elif roll < chat_chance + (0.2 if self.idle_only else 0.3):
                if self.idle_only:
                    self._phone(agent)
                else:
                    topic = random.choice(role_profile(agent).topics)[1].rstrip(".").lower()
                    hub.log_line(aid, "\x1b[36m[notify]\x1b[0m " + random.choice(AWAY_PINGS).format(w=topic))

    def _desk_bound(self, agents: list[Agent]) -> list[Agent]:
        return [a for a in agents if a.activity == "desk" and not a.thinking_until]

    def _pick_group(self, pool: list[Agent], max_extra: int) -> list[Agent]:
        """An anchor plus 1..max_extra colleagues, preferably from its own room."""
        anchor = random.choice(pool)
        same_room = [a for a in pool if a.room == anchor.room and a is not anchor]
        others = same_room if same_room and random.random() < 0.7 else [a for a in pool if a is not anchor]
        size = min(len(others), 1 if random.random() < 0.6 else max_extra)
        return [anchor, *random.sample(others, size)]

    def _maybe_meeting(self, now: float, free_agents: list[Agent]) -> None:
        if now < self.next_collab_at or not self.can_walk():
            return
        by_group: dict[str, list[Agent]] = {}
        for a in self._desk_bound(free_agents):
            by_group.setdefault(a.group, []).append(a)
        candidates = [g for g in by_group.values() if len(g) >= 2]
        if not candidates:
            return  # try again on a later tick
        group = self._pick_group(random.choice(candidates), 2)
        anchor = group[0]
        self.next_collab_at = now + self.rand(self.tempo.collab_every)
        self.reserve_walk(1.5)
        until = now + self.rand(self.tempo.collab_time)
        for a in group:
            a.activity = "meeting"
            a.activity_until = until + random.uniform(0, 6)  # they drift back one at a time
            a.next_event_at = now + self.rand(self.tempo.chat_every)
        names = " & ".join(a.name for a in group)
        self.hub.collaborate([a.agent_id for a in group], anchor.meeting_target, text=f"Sync: {names}")
        for a in group:
            self.hub.log_line(a.agent_id, f"\x1b[35m[meeting]\x1b[0m Syncing with {names}")


    def _local_lunchtime(self) -> bool:
        """True around local lunch (12:00–14:00)."""
        try:
            hour = time.localtime().tm_hour
        except Exception:
            return False
        return 12 <= hour < 14

    def _maybe_canteen(self, now: float, free_agents: list[Agent]) -> None:
        """Idle agents order at the canteen counter, sit and eat, then return."""
        if now < self.next_canteen_at or not self.can_walk():
            return
        # Prefer lunch hour; otherwise a slower trickle when people have been idle.
        lunch = self._local_lunchtime()
        gap = self.rand((45, 90) if lunch else (180, 420))
        self.next_canteen_at = now + (gap * 0.5 if self.idle_only else gap)
        pool = [a for a in free_agents
                if a.group == SHARED_GROUP and a.activity == "desk"
                and not a.is_live()]
        if not pool:
            return
        n = 1 if not lunch else min(3, len(pool))
        diners = random.sample(pool, min(n, len(pool)))
        seats = [s for s in CANTEEN_SEATS if s]  # client may not have all; harness still emits
        for i, agent in enumerate(diners):
            food = random.choice(CANTEEN_FOOD)
            seat = seats[i % len(seats)]
            eat_for = self.rand((25, 50) if lunch else (18, 35)) * (1.3 if self.idle_only else 1.0)
            agent.activity = "canteen"
            agent.activity_until = now + eat_for + 12.0
            agent.next_event_at = now + 8.0
            # Walk to counter first with an order bubble, then the client/route sits them.
            self.hub.state(agent.agent_id, "IDLE", target=CANTEEN_COUNTER,
                         text=f"I'll have {food}")
            # Follow-up sit is handled when activity timer advances in _tick_break-like path;
            # stash the seat on the agent via text+activity for the next tick.
            agent.text = f"Eating {food}"
            agent.target = seat  # director will re-emit when leaving counter phase
            # Schedule a soft "now eating" by shortening first leg:
            agent.activity_until = now + 8.0  # at counter
            agent._canteen_seat = seat  # type: ignore[attr-defined]
            agent._canteen_food = food  # type: ignore[attr-defined]
            agent._canteen_eat_until = now + 8.0 + eat_for  # type: ignore[attr-defined]


    def _maybe_rec(self, now: float, free_agents: list[Agent]) -> None:
        """Occasionally send an idle agent to the Rec Room for yoga or meditation (20–40s)."""
        if not hasattr(self, "next_rec_at"):
            self.next_rec_at = now + random.uniform(40.0, 90.0)
        if now < self.next_rec_at or not self.can_walk():
            return
        self.next_rec_at = now + self.rand((90, 180) if self.idle_only else (150, 320))
        pool = [a for a in free_agents
                if a.group == SHARED_GROUP and a.activity == "desk" and not a.is_live()]
        if not pool:
            return
        agent = random.choice(pool)
        spots = [s for s in REC_SPOTS if s in agent.break_spots] or list(REC_SPOTS)
        spot = random.choice(spots)
        self.reserve_walk()
        self._start_rec_or_break(agent, now, spot)

    def _maybe_foosball(self, now: float, free_agents: list[Agent]) -> None:
        if now < self.next_foosball_at or not self.can_walk():
            return
        # Only the shared break room has a foosball table (isolated wings don't).
        busy = {a.agent_id for a in self.hub.agents.values() if a.activity == "foosball"}
        if busy:
            return  # one game at a time
        pool = [a for a in self._desk_bound(free_agents) if a.group == SHARED_GROUP]
        if len(pool) < 2:
            return
        gap = self.rand(self.tempo.foosball_every)
        self.next_foosball_at = now + (gap * 0.5 if self.idle_only else gap)
        self.reserve_walk(1.5)
        n = min(len(pool), random.choice((2, 2, 3, 4)))
        players = random.sample(pool, n)
        until = now + self.rand(self.tempo.foosball_time) * (1.5 if self.idle_only else 1.0)
        for i, (spot, a) in enumerate(zip(FOOSBALL_SPOTS, players)):  # 1 and 2 are opposite ends
            a.activity = "foosball"
            a.activity_until = until + random.uniform(0, 5)
            a.next_event_at = now + self.rand(self.tempo.chat_every) + 4.0
            text = f"Foosball, {players[1].name}?" if i == 0 else ("You're on!" if i == 1 else "I'm in!")
            self.hub.state(a.agent_id, "IDLE", target=spot, text=text)

    # -- small talk -------------------------------------------------------------
    def _maybe_chat(self, now: float, free_agents: list[Agent]) -> None:
        if now < self.next_chat_at or not self.can_walk():
            return
        by_group: dict[str, list[Agent]] = {}
        for a in self._desk_bound(free_agents):
            by_group.setdefault(a.group, []).append(a)
        candidates = [g for g in by_group.values() if len(g) >= 2]
        if not candidates:
            return
        group = self._pick_group(random.choice(candidates), 2)
        anchor = group[0]
        spots = [s for s in anchor.chat_spots if s not in self.chats]
        if not spots:
            return
        # Prefer the chat spot in the anchor's own room when there is one.
        own = f"Chat_{anchor.room}"
        spot = own if own in spots and random.random() < 0.5 else random.choice(spots)
        self.next_chat_at = now + self.rand(self.tempo.chat_group_every)
        self.reserve_walk(1.5)
        until = now + self.rand(self.tempo.chat_time)
        for i, a in enumerate(group):
            a.activity = "chat"
            a.activity_until = until
            self.hub.state(a.agent_id, "IDLE", target=f"{spot}_{i + 1}")
        # First line once they've had time to walk over (~8 s of real time).
        self.chats[spot] = {"members": group, "until": until, "next_at": now + 8.0 * self.speed,
                            "turn": 0, "topic": random.choice(SMALL_TALK)}

    def _chat_tick(self, now: float) -> None:
        for spot, chat in list(self.chats.items()):
            # A real report (or a prompt) can pull anyone out at any moment.
            members = [a for a in chat["members"] if a.activity == "chat" and self.free(a)]
            chat["members"] = members
            if now >= chat["until"] or len(members) < 2:
                for a in members:
                    self._back_to_desk(a, now)
                del self.chats[spot]
                continue
            if now >= chat["next_at"]:
                chat["next_at"] = now + self.rand(self.tempo.chat_every)
                turn = chat["turn"]
                speaker = members[turn % len(members)]
                if turn == 0:
                    line = chat["topic"][0]
                elif turn == 1:
                    line = chat["topic"][1]
                elif random.random() < 0.35:
                    chat["topic"] = random.choice(SMALL_TALK)
                    line = chat["topic"][0]
                else:
                    line = random.choice(SMALL_TALK_MORE)
                chat["turn"] = turn + 1
                self.hub.state(speaker.agent_id, "IDLE", text=line)



# ---------------------------------------------------------------------------
# Claude / harness connectivity (banner indicator + CoS awareness)
# ---------------------------------------------------------------------------
CLAUDE_AUTH_MARKERS = (
    "not logged in",
    "please run /login",
    "please run `claude /login`",
    "authentication_error",
    "unauthorized",
    "invalid api key",
    "couldn't authenticate",
    "could not authenticate",
    "login required",
)


def looks_like_claude_auth_failure(text: str) -> bool:
    low = (text or "").casefold()
    return any(m in low for m in CLAUDE_AUTH_MARKERS)


class ConnectivityMonitor:
    """Cached Claude reachability for the HUD indicator and agent system prompts."""

    CACHE_TTL = 45.0
    CHECK_TIMEOUT = 25.0

    def __init__(self, hub: "Hub") -> None:
        self.hub = hub
        self.claude: str = "checking"  # ok | checking | down
        self.reason: str = "Checking Claude…"
        self._last_check: float = 0.0
        self._lock = asyncio.Lock()
        self._prev: str | None = None

    def payload(self) -> dict[str, Any]:
        return {
            "type": "CONNECTIVITY",
            "harness": True,
            "claude": self.claude,
            "reason": self.reason,
            "mode": self.hub.mode,
            "ts": now_ms(),
        }

    def blurb_for_prompt(self) -> str:
        if self.claude == "ok":
            return ("\n\n[Office connectivity] Claude Code is connected. "
                    "You may answer Paul normally.")
        if self.claude == "checking":
            return ("\n\n[Office connectivity] Claude reachability is still being checked. "
                    "If a reply fails, ask Paul to click the banner indicator.")
        return (
            "\n\n[Office connectivity] Claude Code is UNAVAILABLE "
            f"({self.reason}). Tell Paul to click the connectivity indicator in the "
            "top banner (or run `claude /login` in Terminal). Do not pretend tools ran."
        )

    def broadcast(self, *, notice: bool = False) -> None:
        self.hub.emit(self.payload())
        if notice and self.claude in ("ok", "down") and self._prev != self.claude:
            if self.claude == "ok":
                self.hub.emit({
                    "type": "OFFICE_NOTICE",
                    "kind": "claude_ok",
                    "title": "Claude connected",
                    "detail": self.reason or "Claude Code is reachable",
                    "icon": "✔",
                    "color": "#81c784",
                })
            elif self.claude == "down":
                self.hub.emit({
                    "type": "OFFICE_NOTICE",
                    "kind": "claude_down",
                    "title": "Claude disconnected",
                    "detail": self.reason or "Claude Code unreachable",
                    "icon": "⚠",
                    "color": "#e57373",
                })
        self._prev = self.claude

    def note_failure(self, detail: str) -> None:
        detail = clean_line(detail or "Claude call failed", 200)
        if looks_like_claude_auth_failure(detail) or "No such file" in detail or "not found" in detail.casefold():
            self.claude = "down"
            if looks_like_claude_auth_failure(detail):
                self.reason = "Not logged in — click indicator to run claude /login"
            elif "not found" in detail.casefold() or "No such file" in detail:
                self.reason = "claude binary not found on PATH"
            else:
                self.reason = detail
            self._last_check = time.monotonic()
            self.broadcast(notice=True)

    def note_success(self) -> None:
        if self.claude != "ok":
            self.claude = "ok"
            self.reason = "Claude Code reachable"
            self._last_check = time.monotonic()
            self.broadcast(notice=True)

    async def check(self, *, force: bool = False) -> dict[str, Any]:
        async with self._lock:
            now = time.monotonic()
            if not force and self._last_check and (now - self._last_check) < self.CACHE_TTL and self.claude != "checking":
                return self.payload()
            prev = self.claude
            self.claude = "checking"
            self.reason = "Checking Claude…"
            if prev != "checking":
                self.broadcast(notice=False)
            ok, reason = await self._probe()
            self.claude = "ok" if ok else "down"
            self.reason = reason
            self._last_check = time.monotonic()
            self.broadcast(notice=True)
            return self.payload()

    async def _probe(self) -> tuple[bool, str]:
        env = {**os.environ, "FORCE_COLOR": "0", "PYTHONUNBUFFERED": "1"}
        home = env.get("HOME") or os.path.expanduser("~")
        env["HOME"] = home
        try:
            import getpass as _getpass
            user = env.get("USER") or env.get("LOGNAME") or _getpass.getuser()
        except Exception:
            user = env.get("USER") or env.get("LOGNAME") or Path(home).name
        env.setdefault("USER", user)
        env.setdefault("LOGNAME", user)
        parts = [p for p in env.get("PATH", "").split(os.pathsep) if p]
        for extra in (str(Path(home) / ".local" / "bin"), "/opt/homebrew/bin", "/usr/local/bin"):
            if extra not in parts:
                parts.insert(0, extra)
        env["PATH"] = os.pathsep.join(parts)

        # Prefer a cheap auth status if the CLI supports it.
        for argv in (
            ["claude", "auth", "status"],
            ["claude", "-p", "--output-format", "text", "Reply with exactly: PONG"],
        ):
            try:
                proc = await asyncio.create_subprocess_exec(
                    *argv,
                    stdin=asyncio.subprocess.DEVNULL,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    env=env,
                    start_new_session=True,
                )
            except FileNotFoundError:
                return False, "claude binary not found on PATH"
            except OSError as exc:
                return False, f"cannot start claude: {exc}"
            try:
                out_b, err_b = await asyncio.wait_for(proc.communicate(), self.CHECK_TIMEOUT)
            except asyncio.TimeoutError:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
                if argv[1:2] == ["auth"]:
                    continue  # try the ping fallback
                return False, "Claude health check timed out"
            out = (out_b or b"").decode("utf-8", "replace")
            err = (err_b or b"").decode("utf-8", "replace")
            blob = f"{out}\n{err}"
            code = proc.returncode if proc.returncode is not None else -1
            if looks_like_claude_auth_failure(blob):
                return False, "Not logged in — click indicator to run claude /login"
            if argv[1:2] == ["auth"]:
                # Unknown subcommand → fall through to ping.
                if code != 0 and ("unknown" in blob.casefold() or "invalid" in blob.casefold()
                                  or "usage" in blob.casefold()):
                    continue
                if code == 0:
                    return True, "Claude auth ok"
                # Auth status failed for another reason — still try ping once.
                continue
            if code == 0:
                return True, "Claude Code reachable"
            detail = clean_line(err or out or f"exit {code}", 160)
            return False, detail or f"claude exited {code}"
        return False, "Claude health check failed"

class CliRunner:
    """Runs a real CLI (typically `claude -p`) per agent and posts the final
    reply into that agent's terminal. Debug/argv chatter stays in the harness log.
    Claude runs keep a per-agent conversational session via --continue in a
    dedicated .office_claude/<agent_id>/ working dir."""

    def __init__(self, hub: Hub, commands: dict[str, str], prompt_mode: str = "arg",
                 cwd: str | None = None, timeout: float = 0.0,
                 cwds: dict[str, str] | None = None,
                 systems: dict[str, str] | None = None) -> None:
        self.hub = hub
        self.commands = commands
        self.prompt_mode = prompt_mode
        self.cwd = cwd
        self.cwds = dict(cwds or {})
        self.systems = dict(systems or {})
        self.timeout = timeout
        self.procs: set[asyncio.subprocess.Process] = set()
        self.started: set[str] = set()
        self._load_started()

    def _load_started(self) -> None:
        try:
            with open(DEFAULT_CLAUDE_SESSIONS_FILE, encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                self.started = {str(k) for k, v in data.items() if v}
            elif isinstance(data, list):
                self.started = {str(x) for x in data}
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as exc:
            log.warning("could not read %s: %s", DEFAULT_CLAUDE_SESSIONS_FILE, exc)

    def _save_started(self) -> None:
        try:
            with open(DEFAULT_CLAUDE_SESSIONS_FILE, "w", encoding="utf-8") as fh:
                json.dump(sorted(self.started), fh, indent=2)
        except OSError as exc:
            log.warning("could not save %s: %s", DEFAULT_CLAUDE_SESSIONS_FILE, exc)

    def handles(self, agent_id: str) -> bool:
        return agent_id in self.commands

    @staticmethod
    def _is_claude(tokens: list[str]) -> bool:
        if not tokens:
            return False
        base = os.path.basename(tokens[0]).lower()
        return base in ("claude", "claude.exe") or base.startswith("claude")

    def project_cwd(self, agent_id: str) -> str:
        run_cwd = self.cwds.get(agent_id) or self.cwd
        if run_cwd in (None, "", "."):
            run_cwd = os.getcwd()
        return os.path.abspath(run_cwd)

    def session_cwd(self, agent_id: str, project: str) -> str:
        """Per-agent dir so `claude --continue` keeps conversations separate."""
        root = DEFAULT_CLAUDE_SESSIONS_DIR
        if not os.path.isabs(root):
            root = os.path.join(project, root)
        path = os.path.join(root, agent_id)
        os.makedirs(path, exist_ok=True)
        return path

    def build_argv(self, agent_id: str, prompt: str, *, continue_session: bool,
                   project: str) -> list[str]:
        template = self.commands[agent_id]
        tokens = shlex.split(template)
        if "{prompt}" in template:
            tokens = [t.replace("{prompt}", prompt) for t in tokens]
        elif self.prompt_mode == "arg" and prompt:
            tokens = tokens + [prompt]
        if not self._is_claude(tokens):
            return tokens

        # Ensure print mode + plain final text (hooks still run for sprite animation).
        if "-p" not in tokens and "--print" not in tokens:
            tokens.insert(1, "-p")
        if "--output-format" not in tokens:
            # insert before the prompt arg (last) when present
            insert_at = len(tokens) - 1 if prompt and tokens and tokens[-1] == prompt else len(tokens)
            tokens[insert_at:insert_at] = ["--output-format", "text"]

        has_sys = any(t in ("--append-system-prompt", "--system-prompt",
                            "--append-system-prompt-file", "--system-prompt-file") for t in tokens)
        sys_prompt = self.systems.get(agent_id, "").strip()
        mon = getattr(self.hub, "connectivity", None)
        if mon is not None:
            sys_prompt = (sys_prompt + mon.blurb_for_prompt()).strip()
        if sys_prompt and not has_sys:
            insert_at = len(tokens) - 1 if prompt and tokens and tokens[-1] == prompt else len(tokens)
            tokens[insert_at:insert_at] = ["--append-system-prompt", sys_prompt]

        # Conversational continuity per agent (session cwd isolates --continue).
        has_cont = any(t in ("-c", "--continue", "-r", "--resume", "--session-id") for t in tokens)
        if continue_session and not has_cont:
            insert_at = 1
            # after -p if present at index 1
            if len(tokens) > 1 and tokens[1] in ("-p", "--print"):
                insert_at = 2
            tokens[insert_at:insert_at] = ["--continue"]

        # Allow tools to see the real project when we run from a session subdir.
        if project:
            dirs = []
            if "--add-dir" not in tokens:
                dirs.append(project)
            kb = str(Path(project) / "knowledge")
            if Path(kb).is_dir() and kb not in tokens:
                dirs.append(kb)
            if dirs:
                insert_at = len(tokens) - 1 if prompt and tokens and tokens[-1] == prompt else len(tokens)
                for d in dirs:
                    tokens[insert_at:insert_at] = ["--add-dir", d]
                    insert_at += 2

        # Read-only allowlist so status questions (git/gh) don't block on approvals.
        has_allowed = any(t in ("--allowedTools", "--allowed-tools") for t in tokens)
        if not has_allowed:
            insert_at = len(tokens) - 1 if prompt and tokens and tokens[-1] == prompt else len(tokens)
            tokens[insert_at:insert_at] = ["--allowedTools", ",".join(DEFAULT_CLAUDE_ALLOWED_TOOLS)]
        has_perm_prompts = "--permission-prompts" in tokens
        if not has_perm_prompts:
            insert_at = len(tokens) - 1 if prompt and tokens and tokens[-1] == prompt else len(tokens)
            # Anything outside the allowlist is denied automatically (no hang).
            tokens[insert_at:insert_at] = ["--permission-prompts", "none"]
        return tokens

    async def run_prompt(self, agent: Agent, prompt: str) -> None:
        hub, aid = self.hub, agent.agent_id
        project = self.project_cwd(aid)
        continue_session = aid in self.started
        argv = self.build_argv(aid, prompt, continue_session=continue_session, project=project)
        is_claude = self._is_claude(argv)
        run_cwd = self.session_cwd(aid, project) if is_claude else project

        log.info("CLI %s%s cwd=%s: %s", aid, " (continue)" if continue_session else "",
                 run_cwd, " ".join(shlex.quote(a) for a in argv))
        # Terminal: typing indicator only. User message already shown by the drawer.
        hub.log_line(aid, "\x1b[2m…\x1b[0m", important=True)
        hub.state(aid, "THINKING", target=agent.desk, text="…")

        # Inherit full user env so Claude can reach Keychain / ~/.claude.json.
        # A thin harness launch (env -i / .command) often omits USER — without it
        # `claude -p` prints "Not logged in · Please run /login" and exits 1.
        # Never store tokens; only fill HOME/USER/PATH/CLAUDE_CONFIG_DIR.
        env = {**os.environ, "FORCE_COLOR": "0", "PYTHONUNBUFFERED": "1"}
        if getattr(self.hub, "vault", None) is not None:
            try:
                env.update(self.hub.vault.env_for_agent(aid))
            except Exception as exc:
                log.warning("vault env inject failed for %s: %s", aid, exc)
        home = env.get("HOME") or os.path.expanduser("~")
        env["HOME"] = home
        try:
            import getpass as _getpass
            _user = env.get("USER") or env.get("LOGNAME") or _getpass.getuser()
        except Exception:
            _user = env.get("USER") or env.get("LOGNAME") or Path(home).name
        env.setdefault("USER", _user)
        env.setdefault("LOGNAME", _user)
        env.setdefault("SHELL", env.get("SHELL") or "/bin/zsh")
        local_bin = str(Path(home) / ".local" / "bin")
        parts = [p for p in env.get("PATH", "").split(os.pathsep) if p]
        for extra in (local_bin, "/opt/homebrew/bin", "/usr/local/bin"):
            if extra not in parts:
                parts.insert(0, extra)
        env["PATH"] = os.pathsep.join(parts)
        # Do not set CLAUDE_CONFIG_DIR: default auth file is ~/.claude.json under HOME.
        # Setting CLAUDE_CONFIG_DIR=~/.claude looks for ~/.claude/.claude.json and fails.
        env["OFFICE_AGENT"] = agent.name
        env.setdefault("CLAUDE_PROJECT_DIR", project)
        use_stdin = self.prompt_mode == "stdin"
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdin=asyncio.subprocess.PIPE if use_stdin else asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=run_cwd,
                env=env,
                limit=1 << 20,
                start_new_session=True,
            )
        except (OSError, ValueError) as exc:
            log.error("CLI %s failed to start: %s", aid, exc)
            hub.log_line(aid, f"\x1b[31mFailed to start: {exc}\x1b[0m", stream="stderr", important=True)
            if "No such file" in str(exc) or isinstance(exc, FileNotFoundError):
                hub.log_line(aid, "\x1b[31mClaude not connected — click the indicator\x1b[0m",
                             stream="stderr", important=True)
            mon = getattr(hub, "connectivity", None)
            if mon is not None:
                mon.note_failure(str(exc))
            hub.state(aid, "IDLE", target=random.choice(agent.break_spots), text="Failed to start")
            return

        self.procs.add(proc)
        hub.state(aid, "WORKING", target=agent.desk, text="…")
        if use_stdin and proc.stdin:
            proc.stdin.write(prompt.encode() + b"\n")
            await proc.stdin.drain()
            proc.stdin.close()

        stdout_buf: list[str] = []
        stderr_buf: list[str] = []

        async def pump(stream: asyncio.StreamReader | None, bucket: list[str], name: str) -> None:
            if stream is None:
                return
            while True:
                raw = await stream.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                bucket.append(line)
                # Harness log only — never flood the office terminal mid-run.
                safe_line = line
                if getattr(hub, "vault", None) is not None:
                    try:
                        safe_line = hub.vault.scrub(line)
                    except Exception:
                        pass
                (log.debug if name == "stdout" else log.info)("CLI %s %s: %s", aid, name, strip_ansi(safe_line)[:200])

        try:
            pumps = asyncio.gather(pump(proc.stdout, stdout_buf, "stdout"),
                                   pump(proc.stderr, stderr_buf, "stderr"))
            if self.timeout > 0:
                await asyncio.wait_for(pumps, self.timeout)
            else:
                await pumps
            code = await proc.wait()
        except asyncio.TimeoutError:
            log.error("CLI %s timed out after %.0fs", aid, self.timeout)
            await self.terminate(proc)
            code = proc.returncode if proc.returncode is not None else -1
            hub.log_line(aid, f"\x1b[31mTimed out after {self.timeout:.0f}s\x1b[0m", stream="stderr", important=True)
            hub.state(aid, "IDLE", target=random.choice(agent.break_spots), text="Timed out")
            return
        except asyncio.CancelledError:
            await self.terminate(proc)
            raise
        finally:
            self.procs.discard(proc)

        out_text = "\n".join(stdout_buf).strip()
        err_text = "\n".join(stderr_buf).strip()
        if getattr(hub, "vault", None) is not None:
            try:
                out_text = hub.vault.scrub(out_text)
                err_text = hub.vault.scrub(err_text)
            except Exception:
                pass
        ok = code == 0
        log.info("CLI %s exited %s (%d stdout chars, %d stderr chars)",
                 aid, code, len(out_text), len(err_text))
        if ok and out_text:
            self.started.add(aid)
            self._save_started()
            mon = getattr(hub, "connectivity", None)
            if mon is not None:
                mon.note_success()
            hub.post_reply(agent, out_text, bubble=True)
            hub.state(aid, "IDLE", target=agent.desk, text=clean_line(out_text, 60))
        elif ok:
            hub.log_line(aid, "\x1b[33m(empty reply)\x1b[0m", important=True)
            hub.state(aid, "IDLE", target=agent.desk, text="(empty reply)")
        else:
            detail = clean_line(err_text or out_text or f"exit {code}", 200)
            hub.log_line(aid, f"\x1b[31m{detail}\x1b[0m", stream="stderr", important=True)
            mon = getattr(hub, "connectivity", None)
            if mon is not None:
                mon.note_failure(detail)
            if looks_like_claude_auth_failure(detail) or "not found" in detail.casefold():
                hub.log_line(aid, "\x1b[31mClaude not connected — click the indicator\x1b[0m",
                             stream="stderr", important=True)
            hub.state(aid, "IDLE", target=random.choice(agent.break_spots),
                      text=f"Failed (exit {code})")

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
# ---------------------------------------------------------------------------
# Office configuration (office.json)
# ---------------------------------------------------------------------------
def load_office(path: str | None) -> dict[str, Any] | None:
    """Loads and validates office.json. Returns None for the legacy fixed office.

    path None means "office.json next to this script, if it exists"; the
    string "none" forces the legacy office.
    """
    if path is not None and path.lower() == "none":
        return None
    if path is None:
        if not os.path.exists(DEFAULT_OFFICE_FILE):
            log.info("no office.json found: using the legacy 3-agent office")
            return None
        path = DEFAULT_OFFICE_FILE
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"could not read office config {path}: {exc}")
    return normalise_office(raw, source=path)


def normalise_office(raw: Any, source: str = "office.json") -> dict[str, Any]:
    """Validates the config and returns a clean copy (the OFFICE_LAYOUT payload).

    Each room gets derived fields the client and the director both rely on:
    break_spots and meeting_target (shared amenities, or the room's own when
    it is "isolated").
    """
    def bad(msg: str) -> SystemExit:
        return SystemExit(f"{source}: {msg}")

    if not isinstance(raw, dict) or not isinstance(raw.get("rooms"), list) or not raw["rooms"]:
        raise bad("expected an object with a non-empty 'rooms' list")
    seen_rooms: set[str] = set()
    seen_agents: set[str] = set()
    rooms: list[dict[str, Any]] = []
    colour_i = 0
    for r in raw["rooms"]:
        if not isinstance(r, dict):
            raise bad("each room must be an object")
        rid = str(r.get("id", ""))
        if not SLUG_RE.match(rid) or rid in seen_rooms or rid == SHARED_GROUP:
            raise bad(f"room id '{rid}' must be a unique lowercase slug (a-z, 0-9, _)")
        seen_rooms.add(rid)
        members: list[dict[str, str]] = []
        for m in r.get("members", []):
            aid = str(m.get("agent_id", ""))
            if not SLUG_RE.match(aid) or aid in seen_agents:
                raise bad(f"agent_id '{aid}' in room '{rid}' must be a unique lowercase slug")
            seen_agents.add(aid)
            colour = str(m.get("color") or PALETTE[colour_i % len(PALETTE)])
            colour_i += 1
            entry = {"agent_id": aid, "name": str(m.get("name") or aid), "role": str(m.get("role", "")),
                     "color": colour, "desk": f"Desk_{aid}"}
            raw_job = m.get("job") if isinstance(m.get("job"), dict) else None
            if raw_job:
                entry["job"] = dict(raw_job)
                if not entry["role"] and raw_job.get("title"):
                    entry["role"] = str(raw_job["title"])
            else:
                # Minimal stub so every agent has a job shape.
                entry["job"] = {
                    "title": entry["role"] or entry["name"],
                    "department": str(r.get("name") or rid),
                    "purpose": f"Act as {entry['role'] or entry['name']}.",
                    "responsibilities": [],
                    "tools": [],
                    "repos": [],
                    "reports_to": "",
                }
            members.append(entry)
        isolated = bool(r.get("isolated", False))
        desks = max(int(r.get("desks", len(members)) or 0), len(members), 1)
        rooms.append({
            "id": rid,
            "name": str(r.get("name") or rid),
            "color": str(r.get("color", "#90a4ae")),
            "theme": str(r.get("theme", "wood")),
            "isolated": isolated,
            "desks": desks,
            "members": members,
            "break_spots": ([f"{rid}_Coffee", f"{rid}_Water", f"{rid}_Sofa_1", f"{rid}_Sofa_2"] if isolated
                            else list(SHARED_BREAK_SPOTS)),
            "chat_spots": [f"{rid}_Chat"] if isolated else [*SHARED_CHAT_SPOTS, f"Chat_{rid}"],
            "meeting_target": f"{rid}_Meeting_Room" if isolated else MEETING_TARGET,
        })
    shared = raw.get("shared") if isinstance(raw.get("shared"), dict) else {}
    br = shared.get("break_room") if isinstance(shared.get("break_room"), dict) else {}
    mr = shared.get("meeting_room") if isinstance(shared.get("meeting_room"), dict) else {}
    archived_raw = raw.get("archived") if isinstance(raw.get("archived"), list) else []
    archived: list[dict[str, Any]] = []
    for a in archived_raw:
        if isinstance(a, dict) and a.get("agent_id"):
            archived.append(dict(a))
    # UNIQUE_ROLE_DEDUPE at load: at most one live member per catalog unique role.
    # Prefer agent_id "chief_of_staff" when short_title is Chief of Staff.
    try:
        cat_path = Path(__file__).resolve().parent / "roles" / "catalog.json"
        if cat_path.exists():
            cat = json.loads(cat_path.read_text(encoding="utf-8"))
            unique_roles = [r for r in (cat.get("roles") or []) if isinstance(r, dict) and r.get("unique")]
            for ur in unique_roles:
                aliases = {
                    str(ur.get("short_title") or "").strip().lower(),
                    str(ur.get("title") or "").strip().lower(),
                    str(ur.get("default_name") or "").strip().lower(),
                }
                aliases.discard("")
                rid = ur.get("id")
                prefer = "chief_of_staff" if str(ur.get("short_title") or "") == "Chief of Staff" else ""
                hits: list[tuple[dict[str, Any], dict[str, Any]]] = []
                for room in rooms:
                    for m in room.get("members") or []:
                        role_l = str(m.get("role") or "").strip().lower()
                        name_l = str(m.get("name") or "").strip().lower()
                        job = m.get("job") if isinstance(m.get("job"), dict) else {}
                        st_l = str(job.get("short_title") or "").strip().lower()
                        ti_l = str(job.get("title") or "").strip().lower()
                        jrid = job.get("role_id")
                        if (
                            role_l in aliases
                            or name_l in aliases
                            or st_l in aliases
                            or ti_l in aliases
                            or (rid and jrid == rid)
                            or (prefer and m.get("agent_id") == prefer)
                        ):
                            hits.append((room, m))
                if len(hits) <= 1:
                    continue
                keep = None
                if prefer:
                    for room, m in hits:
                        if m.get("agent_id") == prefer:
                            keep = m.get("agent_id")
                            break
                if keep is None:
                    keep = hits[0][1].get("agent_id")
                for room, m in hits:
                    if m.get("agent_id") == keep:
                        continue
                    entry = dict(m)
                    entry["archived_at"] = 0
                    entry["archived_from_room"] = room.get("id")
                    entry["archive_reason"] = "dedupe_unique_role"
                    archived.append(entry)
                    room["members"] = [x for x in room["members"] if x.get("agent_id") != m.get("agent_id")]
                    room["desks"] = max(int(room.get("desks") or 0), len(room["members"]), 1)
    except Exception:
        pass  # never fail office load on catalog issues
    return {
        "name": str(raw.get("name", "Agentic Corporation")),
        "rooms": rooms,
        "archived": archived,
        "shared": {
            "break_room": {"name": str(br.get("name", "Break Room")), "spots": list(SHARED_BREAK_SPOTS),
                           "foosball": list(FOOSBALL_SPOTS)},
            "meeting_room": {"name": str(mr.get("name", "Meeting Room")),
                             "seats": max(2, min(8, int(mr.get("seats", 6)))), "target": MEETING_TARGET},
            "canteen": {"name": str((shared.get("canteen") or {}).get("name", "Canteen") if isinstance(shared.get("canteen"), dict) else "Canteen"),
                        "counter": CANTEEN_COUNTER, "seats": list(CANTEEN_SEATS)},
            "rec_room": {"name": str((shared.get("rec_room") or {}).get("name", "Rec Room") if isinstance(shared.get("rec_room"), dict) else "Rec Room"),
                        "spots": list(REC_SPOTS)},
        },
    }


def register_office(hub: Hub, office: dict[str, Any]) -> None:
    for room in office["rooms"]:
        for m in room["members"]:
            hub.register(m["agent_id"], m["name"], m["desk"], m["color"], role=m["role"], room=room["id"],
                         job=dict(m.get("job") or {}),
                         break_spots=tuple(room["break_spots"]), meeting_target=room["meeting_target"],
                         chat_spots=tuple(room["chat_spots"]),
                         group=room["id"] if room["isolated"] else SHARED_GROUP)


class Harness:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        office = load_office(args.office)
        self.hub = Hub(args.mode, args.tempo, office)
        if office is None:
            for spec in DEFAULT_AGENTS:  # legacy fixed office: coder / qa / architect
                self.hub.register(**spec, room="team", chat_spots=(*SHARED_CHAT_SPOTS, "Chat_team"))
        else:
            register_office(self.hub, office)
        self.mock = MockRunner(self.hub, speed=args.speed)
        commands = dict(args.agent_cmd or [])
        cmd_cwds: dict[str, str] = {}
        cmd_systems: dict[str, str] = {}
        cmds_file = getattr(args, "agent_cmds_file", None)
        if cmds_file:
            file_pairs, file_cwds, file_systems = load_agent_cmds_file(cmds_file)
            for aid, cmd in file_pairs:
                commands.setdefault(aid, cmd)
            cmd_cwds.update(file_cwds)
            cmd_systems.update(file_systems)
        unknown = set(commands) - set(self.hub.agents)
        if unknown:
            raise SystemExit(f"--agent-cmd refers to unknown agents: {', '.join(sorted(unknown))}")
        self.hub.live_hold = max(0.0, float(args.live_hold))
        inbox_path = None if str(args.inbox_file).lower() == "none" else (args.inbox_file or DEFAULT_INBOX_FILE)
        self.hub.inbox = Inbox(inbox_path)
        self.hub.inbox_for = self.inbox_for
        # Prefer job{} on the roster when a cmds entry has no system prompt.
        for aid, agent in self.hub.agents.items():
            if aid not in cmd_systems and getattr(agent, "job", None):
                cmd_systems[aid] = format_job_system_prompt(agent.job, name=agent.name, role=agent.role)
        self.cli = CliRunner(self.hub, commands, args.prompt_mode, args.cwd, args.cmd_timeout,
                             cwds=cmd_cwds, systems=cmd_systems) \
            if args.mode in ("cli", "live") else None
        self.hub.connectivity = ConnectivityMonitor(self.hub)
        # Always track Claude so the banner works even before the first prompt.
        # Persist paths + live hire/fire hooks.
        if office is not None:
            self.hub.office_path = args.office or DEFAULT_OFFICE_FILE
        self.hub.cmds_path = cmds_file
        self.hub.on_hired = self._on_hired
        self.hub.on_fired = self._on_fired
        vault_meta = Path.cwd() / ".office_vault.json"
        office_arg = getattr(args, "office", None)
        if office_arg and str(office_arg).lower() != "none":
            vault_meta = Path(office_arg).expanduser().resolve().parent / ".office_vault.json"
        self.hub.vault = OfficeVault(meta_path=vault_meta)
        if self.hub.vault is not None and not self.hub.vault.verify_integrity():
            log.warning("vault metadata integrity check failed: %s", self.hub.vault.integrity_detail)
            # Notice board is notified on first client connect via SNAPSHOT path; emit now too.
            self.hub.emit(vault_notice_payload(
                "vault_tamper", "Vault metadata integrity warning",
                (self.hub.vault.integrity_detail or "HMAC mismatch")[:160],
                meta={"integrity_ok": False},
            ))
        global _VAULT_PROMPT_HOOK
        def _vault_addon(aid: str) -> str:
            v = self.hub.vault
            if v is None:
                return ""
            agent = self.hub.agents.get(aid)
            return format_vault_system_addon(v, aid, is_cos=is_chief_of_staff(agent, aid))
        _VAULT_PROMPT_HOOK = _vault_addon
        if self.cli is not None:
            for aid, agent in self.hub.agents.items():
                if getattr(agent, "job", None):
                    self.cli.systems[aid] = format_job_system_prompt(
                        agent.job, name=agent.name, role=agent.role, agent_id=aid)
        if self.cli is not None and commands:
            log.info("CLI bindings: %s", ", ".join(sorted(commands)))
        elif self.cli is not None and not commands:
            log.warning("%s mode without any --agent-cmd / agent_cmds.json: "
                        "dashboard prompts go to the MCP inbox and nothing runs them", args.mode)
        self.tasks: list[asyncio.Task[Any]] = []
        self.stop_event: asyncio.Event | None = None
        self.mcp_server: Any = None  # office_mcp.OfficeMCP when enabled
        self.tempo = TEMPOS[args.tempo]
        if args.mode == "live":
            for agent in self.hub.agents.values():  # seated, screens off, until a real report
                agent.state, agent.target, agent.activity = "IDLE", agent.desk, "desk"
        ambient_on = ((args.mode in ("mock", "live") and not args.no_ambient)
                      or (args.mode == "cli" and args.ambient))
        self.director: AmbientDirector | None = None
        if ambient_on:
            # Live/idle-only: include CLI-bound agents so they wander when not
            # on a real report. Mock/cli: keep excluding bound bots from fake work.
            self.director = AmbientDirector(
                self.hub, self.tempo, args.speed,
                agent_filter=(lambda _a: True) if args.mode == "live"
                else (lambda a: not (self.cli and self.cli.handles(a.agent_id))),
                idle_only=args.mode == "live")
            self.hub.on_release = self.director.after_finish
            for agent in self.hub.agents.values():
                if self.director.agent_filter(agent):
                    self.director.place_initial(agent)


    def _on_hired(self, agent: Agent) -> None:
        """Start a worker and bind Claude for a mid-session hire."""
        self.tasks.append(asyncio.create_task(self.worker(agent), name=f"worker-{agent.agent_id}"))
        if self.cli is not None:
            self.cli.commands[agent.agent_id] = "claude -p --output-format text {prompt}"
            self.cli.systems[agent.agent_id] = format_job_system_prompt(
                getattr(agent, "job", None), name=agent.name, role=agent.role,
                agent_id=agent.agent_id)
            log.info("CLI bound for new hire %s", agent.agent_id)
        if self.director and self.director.agent_filter(agent):
            self.director.place_initial(agent)
        # Refresh clients so the new agent appears even before FX finishes.
        self.hub.emit(self.hub.snapshot())

    def _on_fired(self, agent_id: str) -> None:
        if self.cli is not None:
            self.cli.commands.pop(agent_id, None)
            self.cli.systems.pop(agent_id, None)
            self.cli.cwds.pop(agent_id, None)
        path = self.hub.cmds_path
        if path and os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
                if isinstance(data, dict) and agent_id in data:
                    data.pop(agent_id, None)
                    with open(path, "w", encoding="utf-8") as fh:
                        json.dump(data, fh, indent=2, ensure_ascii=False)
                        fh.write("\n")
                    log.info("removed CLI binding for %s from %s", agent_id, path)
            except (OSError, ValueError) as exc:
                log.error("could not update agent cmds on fire %s: %s", path, exc)

    def inbox_for(self, agent: Agent) -> bool:
        """Dashboard prompts go to the inbox for real bots: every agent without a
        bound command in live mode; in mock/cli mode, agents that have reported
        for real (or already have inbox history)."""
        if self.cli and self.cli.handles(agent.agent_id):
            return False
        if self.args.mode == "live":
            return True
        return agent.live_reports > 0 or self.hub.inbox.has_history(agent.agent_id)

    async def worker(self, agent: Agent) -> None:
        """Serially executes prompts queued for one agent."""
        while True:
            prompt = await agent.queue.get()
            async with agent.lock:
                runner = self.cli if (self.cli and self.cli.handles(agent.agent_id)) else self.mock
                if self.args.mode == "live" and runner is self.mock:
                    log.warning("live mode: no command bound to %s; prompt not run: %s",
                                agent.agent_id, clean_line(prompt, 80))
                    agent.queue.task_done()
                    continue
                try:
                    mon = self.hub.connectivity
                    if (runner is self.cli and mon is not None and mon.claude == "down"
                            and looks_like_claude_auth_failure(mon.reason)):
                        self.hub.log_line(agent.agent_id,
                                          "\x1b[31mClaude not connected — click the indicator\x1b[0m",
                                          stream="stderr", important=True)
                        self.hub.state(agent.agent_id, "IDLE",
                                      text="Claude not connected")
                    else:
                        await runner.run_prompt(agent, prompt)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:  # keep the worker alive whatever happens
                    log.exception("runner failed for %s", agent.agent_id)
                    self.hub.log_line(agent.agent_id, f"\x1b[31mRunner error: {exc}\x1b[0m", stream="stderr", important=True)
                    self.hub.state(agent.agent_id, "IDLE", text="Runner error")
                finally:
                    agent.queue.task_done()
                    if self.director and agent.queue.empty() and self.director.agent_filter(agent):
                        self.director.after_prompt(agent)

    async def _connectivity_loop(self) -> None:
        """Periodic cheap Claude health check for the banner indicator."""
        mon = self.hub.connectivity
        if mon is None:
            return
        # First check soon after boot so the banner is not stuck on amber.
        await asyncio.sleep(2.0)
        while True:
            try:
                await mon.check(force=False)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("connectivity check failed")
            await asyncio.sleep(ConnectivityMonitor.CACHE_TTL)

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        self.stop_event = stop = asyncio.Event()

        def request_stop(signame: str) -> None:
            if not stop.is_set():
                log.info("received %s, shutting down...", signame)
                stop.set()

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, request_stop, sig.name)
            except NotImplementedError:  # Windows
                signal.signal(sig, lambda *_: loop.call_soon_threadsafe(request_stop, "signal"))

        for agent in self.hub.agents.values():
            self.tasks.append(asyncio.create_task(self.worker(agent), name=f"worker-{agent.agent_id}"))
        if self.director:
            self.tasks.append(asyncio.create_task(self.director.run(), name="ambient"))
        if self.hub.connectivity is not None:
            self.tasks.append(asyncio.create_task(self._connectivity_loop(), name="connectivity"))

        async with serve(self.hub.handler, self.args.host, self.args.port, max_size=2 ** 22) as server:
            log.info("agent_harness %s (%s mode, %s tempo, websockets %s API) listening on ws://%s:%d",
                     __version__, self.args.mode, self.args.tempo, "legacy" if _WS_LEGACY else "asyncio",
                     self.args.host, self.args.port)
            if self.hub.office:
                log.info("office '%s': %d rooms, %d agents", self.hub.office["name"],
                         len(self.hub.office["rooms"]), len(self.hub.agents))
            else:
                log.info("legacy office, agents: %s", ", ".join(self.hub.agents))
            if self.args.mcp_port:
                await self.start_mcp()
            await stop.wait()
            server.close()
            if self.mcp_server is not None:
                await self.mcp_server.stop()
        # Cleanup
        pending = list(self.tasks)
        for t in pending:
            t.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        if self.cli:
            await self.cli.shutdown()
        log.info("bye")

    async def start_mcp(self) -> None:
        try:
            import office_mcp
        except ImportError as exc:  # the 'mcp' package is missing
            log.warning("MCP connector disabled (%s). Install it with: pip install -r requirements.txt", exc)
            return
        token, source, created = office_mcp.load_token(self.args.mcp_token_file)
        self.mcp_server = office_mcp.OfficeMCP(self.hub, token, rate_per_min=self.args.mcp_rate)
        await self.mcp_server.start(self.args.mcp_host, self.args.mcp_port)
        log.info("MCP connector on http://%s:%d/mcp (tool: report_office_status; bearer token from %s)",
                 self.args.mcp_host, self.mcp_server.port, source)
        if created:
            # Shown once, when the token is first generated.
            print(f"\n  New MCP token saved to {source} (chmod 600):\n\n    {token}\n\n"
                  "  Use it as the connector's header:  Authorization: Bearer <token>\n", flush=True)

    def request_stop(self) -> None:
        """Stops run() (used by tests and embedders)."""
        if self.stop_event is not None:
            self.stop_event.set()



def load_agent_cmds_file(path: str) -> tuple[list[tuple[str, str]], dict[str, str], dict[str, str]]:
    """Load agent_id -> command bindings from a JSON file.

    Accepted shapes:
      {"chief_of_staff": "claude -p {prompt}"}
      {"chief_of_staff": {"cmd": "claude -p {prompt}", "cwd": ".", "system": "You are..."}}
    Keys starting with _ are comments.
    Returns ([(agent_id, cmd), ...], {agent_id: cwd}, {agent_id: system_prompt}).
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise argparse.ArgumentTypeError(f"{path}: expected a JSON object")
    pairs: list[tuple[str, str]] = []
    cwds: dict[str, str] = {}
    systems: dict[str, str] = {}
    for key, val in data.items():
        if str(key).startswith("_"):
            continue
        aid = str(key).strip()
        if not aid:
            continue
        if isinstance(val, str):
            cmd = val.strip()
            cwd = None
            system = None
        elif isinstance(val, dict):
            cmd = str(val.get("cmd") or val.get("command") or "").strip()
            raw_cwd = val.get("cwd")
            cwd = str(raw_cwd).strip() if raw_cwd else None
            raw_sys = val.get("system") or val.get("system_prompt") or val.get("role")
            system = str(raw_sys).strip() if raw_sys else None
        else:
            raise argparse.ArgumentTypeError(f"{path}: {aid}: expected string or object")
        if not cmd:
            raise argparse.ArgumentTypeError(f"{path}: {aid}: missing cmd")
        pairs.append((aid, cmd))
        if cwd:
            cwds[aid] = cwd
        if system:
            systems[aid] = system
    return pairs, cwds, systems


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
    p.add_argument("--mode", choices=("mock", "cli", "live"), default="mock",
                   help="mock: simulated office (real MCP reports override it per agent); cli: real commands; "
                        "live: no fake work, agents work only on real reports / CLI runs and otherwise "
                        "live an idle office life (see --no-ambient)")
    p.add_argument("--agent-cmd", action="append", type=parse_agent_cmd, metavar="AGENT_ID='CMD'",
                   help="bind a shell command to an agent (cli/live mode); repeatable. Use {prompt} as a placeholder")
    p.add_argument("--agent-cmds-file", default=None, metavar="PATH",
                   help="JSON file of agent_id -> cmd (or {cmd, cwd}) bindings; see agent_cmds.example.json")
    p.add_argument("--prompt-mode", choices=("arg", "stdin", "none"), default="arg",
                   help="how the prompt reaches the command when {prompt} is not used (default: arg)")
    p.add_argument("--cwd", default=None, help="working directory for CLI commands")
    p.add_argument("--cmd-timeout", type=float, default=0.0, help="kill CLI runs after N seconds (0 = never)")
    p.add_argument("--office", default=None, metavar="PATH",
                   help="office layout config (default: office.json next to this script if present; "
                        "'none' = legacy 3-agent office)")
    p.add_argument("--tempo", choices=tuple(TEMPOS), default="calm",
                   help="ambient pace: calm (default, long desk sessions, rare breaks/meetings), normal, busy")
    p.add_argument("--speed", type=float, default=1.0, help="time multiplier for ambient tempo and mock prompt runs (2 = twice as fast)")
    p.add_argument("--no-ambient", action="store_true", help="mock / live mode: disable the ambient simulation (live mode: agents then only move on real reports)")
    p.add_argument("--ambient", action="store_true", help="cli mode: simulate agents that have no command")
    p.add_argument("--mcp-port", type=int, default=8766,
                   help="port for the MCP connector at /mcp (default 8766; 0 = off)")
    p.add_argument("--no-mcp", dest="mcp_port", action="store_const", const=0, help="disable the MCP connector")
    p.add_argument("--mcp-host", default="127.0.0.1",
                   help="MCP bind address (default 127.0.0.1; Tailscale Funnel proxies to localhost)")
    p.add_argument("--mcp-token-file", default=None, metavar="PATH",
                   help="where the generated token is kept (default .office_token next to this script); "
                        "env OFFICE_MCP_TOKEN wins if set")
    p.add_argument("--mcp-rate", type=int, default=60,
                   help="max MCP requests per minute per token (default 60, bursts up to 20)")
    p.add_argument("--inbox-file", default=None, metavar="PATH",
                   help="where queued dashboard messages for real bots are kept (default .office_inbox.json next "
                        "to this script; 'none' = memory only)")
    p.add_argument("--live-hold", type=float, default=600.0, metavar="SECONDS",
                   help="after a real status report the simulation leaves that agent alone this long (default 600)")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s", datefmt="%H:%M:%S")
    if not args.verbose:  # the MCP SDK logs every stateless request at INFO
        for name in ("mcp", "uvicorn", "uvicorn.error"):
            logging.getLogger(name).setLevel(logging.WARNING)
    try:
        asyncio.run(Harness(args).run())
    except OSError as exc:
        log.error("could not start server: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
