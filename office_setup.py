"""office_setup.py - per-machine setup checks for the Agent Office bridge.

Everything here describes the person running the office on this Mac, so a
fresh clone works for a new user without editing code:

* the owner's name (office.json "owner", else `git config user.name`), told
  to every agent in one prompt line (shipped text only ever says "the owner");
* whether Claude Code is logged in, and how (`claude auth status`);
* which calendar connector is connected in claude.ai, and its read-only tools.

The connector list comes from the `init` event of a `claude -p` stream; the
process is stopped right after that event, before any model call.

Run `python office_setup.py` for a human-readable check.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Any


# A connector counts as a calendar if its server segment matches one of these.
CALENDAR_SERVERS = re.compile(r"calendar|microsoft_365|outlook", re.I)
# On a mixed connector (Microsoft 365), only tools about the calendar qualify.
CALENDAR_WORDS = re.compile(r"calendar|meeting|availab|free_?busy|free_time|event", re.I)
READ_VERBS = re.compile(r"(^|_)(search|list|get|find|check|query|read)(_|$)", re.I)
WRITE_WORDS = re.compile(
    r"create|update|delete|remove|send|respond|reply|move|modify|cancel|trash|forward|set_|"
    r"insert|patch|accept|decline|invite|rsvp|write|draft|copy|rename|upload", re.I)

SETUP_HINT = "connect Microsoft 365 or Google Calendar at claude.ai → Settings → Connectors"


@dataclass
class SetupReport:
    owner: str = ""
    owner_source: str = "not set"
    claude_found: bool = False
    logged_in: bool = False
    auth_method: str = ""
    connectors: list[tuple[str, str]] = field(default_factory=list)  # (name, status)
    tools: list[str] = field(default_factory=list)
    probed: bool = False

    @property
    def calendar_tools(self) -> list[str]:
        return calendar_tools(self.tools)

    @property
    def calendar_connectors(self) -> list[tuple[str, str]]:
        return [(n, s) for n, s in self.connectors if CALENDAR_SERVERS.search(n.replace(" ", "_"))]

    def warnings(self) -> list[str]:
        out: list[str] = []
        if not self.claude_found:
            return ["Claude Code (`claude`) is not on PATH: install it, then run `claude` and /login."]
        if not self.logged_in:
            out.append("Claude Code is not logged in: run `claude`, then /login with your claude.ai account.")
        elif self.auth_method and self.auth_method != "claude.ai":
            out.append(f"Claude Code uses {self.auth_method} auth: claude.ai connectors (calendar) need a "
                       "claude.ai login (`claude` then /login).")
        if self.probed and self.logged_in and not self.calendar_tools:
            pending = [f"{n} ({s})" for n, s in self.calendar_connectors if s != "connected"]
            detail = f" Found but not connected: {', '.join(pending)}." if pending else ""
            out.append(f"No calendar connector: the EA and Chief of Staff can't read your calendar. "
                       f"To fix, {SETUP_HINT}.{detail}")
        if not self.owner:
            out.append("Owner name not set, so agents will call you \"the owner\": add "
                       "\"owner\": {\"name\": \"<you>\"} to office.json, or set git config user.name.")
        return out

    def summary_lines(self) -> list[str]:
        cal = ", ".join(sorted({t.split("__")[1] for t in self.calendar_tools})) or "none"
        lines = [
            f"Owner: {self.owner} (from {self.owner_source})" if self.owner else "Owner: not set",
            f"Claude Code: {'logged in via ' + (self.auth_method or '?') if self.logged_in else 'NOT logged in'}",
            f"Calendar connector: {cal if self.probed else 'not checked'}",
        ]
        return lines + [f"WARNING: {w}" for w in self.warnings()]


def calendar_tools(tools: list[str]) -> list[str]:
    """Read-only calendar tools among a Claude session's tool names."""
    out: list[str] = []
    for name in tools:
        parts = name.split("__")
        if len(parts) < 3 or parts[0] != "mcp":
            continue
        server, tool = parts[1], "__".join(parts[2:])
        if not CALENDAR_SERVERS.search(server) or WRITE_WORDS.search(tool):
            continue
        if not READ_VERBS.search(tool) and "availab" not in tool.lower():
            continue
        calendar_only = re.search(r"calendar", server, re.I) is not None
        if calendar_only or CALENDAR_WORDS.search(tool):
            out.append(name)
    return sorted(out)


def owner_name(office: dict[str, Any] | None = None, cwd: str | None = None) -> tuple[str, str]:
    """(name, source): office.json owner.name, else git user.name's first word."""
    owner = (office or {}).get("owner")
    if isinstance(owner, dict) and str(owner.get("name", "")).strip():
        return str(owner["name"]).strip(), "office.json"
    if isinstance(owner, str) and owner.strip():
        return owner.strip(), "office.json"
    try:
        git = subprocess.run(["git", "config", "user.name"], capture_output=True, text=True,
                             timeout=5, cwd=cwd or os.path.dirname(os.path.abspath(__file__)))
        first = git.stdout.strip().split()
        if first:
            return first[0], "git config user.name"
    except (OSError, subprocess.SubprocessError):
        pass
    return "", "not set"


def owner_prompt(owner: str) -> str:
    """The one place an agent learns the owner's name."""
    if not owner:
        return ""
    return (f"\n\n[Owner] \"The owner\" in your instructions is {owner}, the human who runs this office "
            f"and who you work for; address them as {owner}.")


def auth_status(claude: str = "claude") -> tuple[bool, str]:
    try:
        res = subprocess.run([claude, "auth", "status"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        data = json.loads(res.stdout or "{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return False, ""
    return bool(data.get("loggedIn")), str(data.get("authMethod", ""))


def probe_tools(claude: str = "claude", timeout: float = 45.0) -> tuple[list[tuple[str, str]], list[str]] | None:
    """(connectors, tool names) from a claude -p init event, or None on failure."""
    with tempfile.TemporaryDirectory(prefix="office_probe_") as cwd:
        try:
            proc = subprocess.Popen(
                # Prompt first: --tools is variadic and would swallow a trailing prompt.
                [claude, "-p", "ping", "--output-format", "stream-json", "--verbose", "--max-turns", "1",
                 "--tools", ""],
                cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            return None
        timer = __import__("threading").Timer(timeout, proc.kill)
        timer.start()
        init = None
        try:
            for line in proc.stdout or []:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if ev.get("type") == "system" and ev.get("subtype") == "init":
                    init = ev
                    break
        finally:
            timer.cancel()
            proc.kill()
            proc.wait()
    if init is None:
        return None
    servers = [(str(s.get("name", "")), str(s.get("status", ""))) for s in init.get("mcp_servers") or []]
    return servers, [str(t) for t in init.get("tools") or []]


def check(office: dict[str, Any] | None = None, probe: bool = True) -> SetupReport:
    rep = SetupReport()
    rep.owner, rep.owner_source = owner_name(office)
    claude = shutil.which("claude")
    rep.claude_found = claude is not None
    if not claude:
        return rep
    rep.logged_in, rep.auth_method = auth_status(claude)
    if probe and rep.logged_in:
        found = probe_tools(claude)
        if found is not None:
            rep.connectors, rep.tools = found
            rep.probed = True
    return rep


def main() -> int:
    office = None
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "office.json")
    if not os.path.exists(path):
        path = os.path.join(here, "office.default.json")
    try:
        with open(path, encoding="utf-8") as fh:
            office = json.load(fh)
    except (OSError, ValueError):
        pass
    rep = check(office)
    print("Agent Office setup check")
    for line in rep.summary_lines():
        print("  " + line)
    return 1 if rep.warnings() else 0


if __name__ == "__main__":
    sys.exit(main())
