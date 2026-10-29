#!/usr/bin/env python3
"""Claude Code -> Agent Office bridge hook.

Reads one Claude Code hook event as JSON on stdin and posts
report_office_status to the local MCP connector (default
http://127.0.0.1:8766/mcp) so the matching sprite shows live activity.

Designed for project .claude/settings.json. Never touches ~/.claude/settings.json.

Env (optional):
  OFFICE_MCP_URL     default http://127.0.0.1:8766/mcp
  OFFICE_MCP_TOKEN   bearer token (else reads .office_token next to this repo)
  OFFICE_AGENT       office character name (default: Chief of Staff)
  OFFICE_HOOK_LOG    append-only log path (default: .claude/office-hook.log)
  OFFICE_HOOK_QUIET  if 1, skip MCP and only log
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_URL = "http://127.0.0.1:8766/mcp"
DEFAULT_AGENT = "Chief of Staff"
MAX_DETAIL = 200
PROTOCOL = "2025-03-26"


def _env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def _token() -> str:
    tok = _env("OFFICE_MCP_TOKEN")
    if tok:
        return tok
    path = ROOT / ".office_token"
    if path.is_file():
        return path.read_text(encoding="utf-8").strip()
    return ""


def _log(line: str) -> None:
    path = Path(_env("OFFICE_HOOK_LOG", str(ROOT / ".claude" / "office-hook.log")))
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {line}\n")
    except OSError:
        pass


def _clean(text: str, limit: int = MAX_DETAIL) -> str:
    out = " ".join((text or "").replace("\r", " ").replace("\n", " ").split())
    return out[:limit]


def _map_event(payload: dict) -> tuple[str, str] | None:
    """Return (action, detail) or None to skip."""
    event = payload.get("hook_event_name") or payload.get("hookEventName") or ""
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}

    if event in ("SessionStart", "UserPromptSubmit"):
        src = payload.get("source") or payload.get("prompt") or "Claude Code session"
        if isinstance(src, str) and len(src) > 80:
            src = src[:77] + "..."
        return "start_task", _clean(f"Claude Code: {src}" if event == "SessionStart" else f"Prompt: {src}")

    if event == "PreToolUse":
        detail = tool
        if tool == "Bash" and isinstance(tool_input, dict):
            cmd = str(tool_input.get("command") or "")
            if cmd:
                detail = f"Bash: {cmd}"
        elif tool in ("Read", "Edit", "Write", "MultiEdit") and isinstance(tool_input, dict):
            path = tool_input.get("file_path") or tool_input.get("path") or ""
            if path:
                detail = f"{tool}: {path}"
        return "run_tool", _clean(detail or "tool")

    if event == "PostToolUse":
        return "run_tool", _clean(f"done {tool}" if tool else "tool done")

    if event in ("PostToolUseFailure", "StopFailure"):
        err = payload.get("error") or payload.get("message") or tool or "error"
        return "error", _clean(str(err))

    if event == "Notification":
        msg = payload.get("message") or payload.get("notification_type") or "needs attention"
        return "thinking", _clean(str(msg))

    if event == "Stop":
        return "finish", _clean("Claude Code turn finished")

    if event == "SessionEnd":
        return "finish", _clean("Claude Code session ended")

    return None


def _http(url: str, body: dict | None, token: str) -> tuple[int, dict | list | str]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": PROTOCOL,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            raw = resp.read()
            if not raw:
                return resp.status, {}
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw.decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return exc.code, raw.decode("utf-8", "replace") if raw else {}
    except Exception as exc:  # noqa: BLE001 — hook must never fail Claude
        return 0, {"error": str(exc)}


def _report(url: str, token: str, agent: str, action: str, detail: str) -> str:
    # Stateless MCP still expects initialize once per connection-ish; do both.
    _http(
        url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL,
                "capabilities": {},
                "clientInfo": {"name": "claude-office-hook", "version": "0.1"},
            },
        },
        token,
    )
    _http(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, token)
    status, resp = _http(
        url,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "report_office_status",
                "arguments": {"agent": agent, "action": action, "detail": detail},
            },
        },
        token,
    )
    return f"http={status} resp={resp!r}"


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        _log(f"bad-json {raw[:200]!r}")
        return 0

    mapped = _map_event(payload if isinstance(payload, dict) else {})
    if mapped is None:
        _log(f"skip event={payload.get('hook_event_name')!r}")
        return 0

    action, detail = mapped
    agent = _env("OFFICE_AGENT", DEFAULT_AGENT)
    url = _env("OFFICE_MCP_URL", DEFAULT_URL)
    quiet = _env("OFFICE_HOOK_QUIET") == "1"
    token = _token()

    if quiet or not token:
        _log(f"{'quiet' if quiet else 'no-token'} agent={agent!r} action={action} detail={detail!r}")
        return 0

    try:
        result = _report(url, token, agent, action, detail)
        _log(f"ok agent={agent!r} action={action} detail={detail!r} {result}")
    except Exception as exc:  # noqa: BLE001
        _log(f"fail agent={agent!r} action={action} detail={detail!r} err={exc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
