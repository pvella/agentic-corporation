"""
office_mcp.py - Remote MCP connector for Agent Office live status.

Started by agent_harness.py (unless --no-mcp). Serves the MCP Streamable HTTP
transport at http://127.0.0.1:8766/mcp using the official `mcp` Python SDK
(MCPServer, stateless, JSON responses), so a cloud-hosted bot (e.g. a Grok Bot
connector) can call one tool:

  report_office_status(agent, action, detail)
      agent   the bot's name as in office.json ("Android Dev"); case-insensitive,
              the agent_id ("android_dev") works too
      action  start_task | thinking | run_tool | finish | error
      detail  one short sentence (control characters stripped, max 200 chars)

Security:
  * Every HTTP request needs "Authorization: Bearer <token>" or gets 401.
    The token comes from env OFFICE_MCP_TOKEN, else .office_token next to this
    file (generated on first run with 256 bits of randomness, chmod 600).
  * Token-bucket rate limit per token (default 60/min, bursts of 20) -> 429.
  * Repeated bad tokens from one client are slowed down and then refused (429).
  * Binds to 127.0.0.1 by default; expose it with Tailscale Funnel (see README).
    DNS-rebinding Host checks are off because Funnel forwards the public
    *.ts.net Host header; the bearer token is what guards the endpoint.

If the harness is not running, the bots' calls simply fail; the office does
not queue anything.
"""
from __future__ import annotations

import asyncio
import contextlib
import hmac
import json
import logging
import os
import re
import secrets
import socket
import time
import unicodedata
from typing import Annotated, Any, Literal

from pydantic import Field

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings

log = logging.getLogger("office_mcp")

MCP_PATH = "/mcp"
TOKEN_ENV = "OFFICE_MCP_TOKEN"
DEFAULT_TOKEN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".office_token")
MAX_DETAIL = 200
MAX_AGENT = 80
ACTIONS = ("start_task", "thinking", "run_tool", "finish", "error")
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\)|\x1b.")

TOOL_DESCRIPTION = (
    "Report what you are doing so your character in the Agent Office dashboard reacts. "
    "Call it when you start a task (start_task), are working something out (thinking), "
    "run a tool or command (run_tool), finish (finish) or fail (error). "
    "'agent' is your bot name exactly as in the office, e.g. \"Android Dev\". "
    "'detail' is one short sentence. Returns \"ok\". If the call fails, ignore it and carry on."
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def clean_text(value: Any, limit: int = MAX_DETAIL) -> str:
    """Strips ANSI escapes and control/format characters, collapses whitespace,
    and caps the length (an ellipsis marks a cut)."""
    text = _ANSI_RE.sub("", str(value or ""))
    text = "".join(" " if unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp") else ch for ch in text)
    text = " ".join(text.split())
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "\u2026"
    return text


def load_token(path: str | None = None) -> tuple[str, str, bool]:
    """Returns (token, source, created). Env OFFICE_MCP_TOKEN wins; otherwise the
    token file is read, or created with a fresh random token (mode 600)."""
    env = os.environ.get(TOKEN_ENV, "").strip()
    if env:
        if len(env) < 16:
            raise SystemExit(f"{TOKEN_ENV} is too short (use at least 16 characters)")
        return env, f"${TOKEN_ENV}", False
    path = path or DEFAULT_TOKEN_FILE
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            token = fh.read().strip()
        if len(token) >= 16:
            with contextlib.suppress(OSError):
                os.chmod(path, 0o600)
            return token, path, False
    token = secrets.token_urlsafe(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(token + "\n")
    os.chmod(path, 0o600)
    return token, path, True


class TokenBucket:
    def __init__(self, rate_per_min: float, burst: float) -> None:
        self.rate = max(rate_per_min, 1.0) / 60.0
        self.burst = max(burst, 1.0)
        self.tokens = self.burst
        self.at = time.monotonic()

    def take(self) -> float:
        """Takes one token. Returns 0 if allowed, else seconds until the next one."""
        now = time.monotonic()
        self.tokens = min(self.burst, self.tokens + (now - self.at) * self.rate)
        self.at = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return 0.0
        return (1.0 - self.tokens) / self.rate


# ---------------------------------------------------------------------------
# ASGI guard: bearer auth + rate limits in front of the SDK app
# ---------------------------------------------------------------------------
class AuthGuard:
    def __init__(self, app: Any, token: str, rate_per_min: int = 60) -> None:
        self.app = app
        self._token = token.encode()
        self.rate_per_min = rate_per_min
        self._buckets: dict[str, TokenBucket] = {}
        self._failures: dict[str, TokenBucket] = {}

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)  # lifespan
            return
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        client = headers.get("x-forwarded-for", "").split(",")[0].strip() or (scope.get("client") or ("?",))[0]
        auth = headers.get("authorization", "")
        scheme, _, presented = auth.partition(" ")
        ok = scheme.lower() == "bearer" and hmac.compare_digest(presented.strip().encode(), self._token)
        if not ok:
            # Slow down and then refuse repeated bad tokens from one client.
            fail = self._failures.setdefault(client, TokenBucket(10, 10))
            if fail.take() > 0:
                await _plain(send, 429, "too many failed attempts", {"retry-after": "60"})
                return
            log.warning("MCP 401 from %s (%s %s)", client, scope.get("method"), scope.get("path"))
            await asyncio.sleep(0.2)
            await _plain(send, 401, "unauthorized: send 'Authorization: Bearer <token>'",
                         {"www-authenticate": 'Bearer realm="agent-office"'})
            return
        if scope.get("path", "").rstrip("/") != MCP_PATH:
            await _plain(send, 404, f"not found: the MCP endpoint is {MCP_PATH}")
            return
        method = scope.get("method", "")
        if method != "POST":
            # Stateless server: no server-to-client SSE stream (GET) and no
            # sessions to end (DELETE). The spec allows 405 for both.
            await _plain(send, 405, f"{method} not supported here: POST JSON-RPC to {MCP_PATH}",
                         {"allow": "POST"})
            return
        bucket = self._buckets.setdefault("token", TokenBucket(self.rate_per_min, min(20, self.rate_per_min)))
        wait = bucket.take()
        if wait > 0:
            await _plain(send, 429, "rate limited", {"retry-after": str(max(1, round(wait)))})
            return
        # Let the SDK serve "/mcp" itself (no 307 redirect for "/mcp/").
        if scope["path"] != MCP_PATH:
            scope = {**scope, "path": MCP_PATH, "raw_path": MCP_PATH.encode()}
        await self.app(scope, receive, send)


async def _plain(send: Any, status: int, text: str, extra: dict[str, str] | None = None) -> None:
    body = json.dumps({"error": text}).encode()
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
    headers += [(k.encode(), v.encode()) for k, v in (extra or {}).items()]
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


# ---------------------------------------------------------------------------
# The MCP server
# ---------------------------------------------------------------------------
def build_mcp(hub: Any) -> MCPServer:
    """The MCPServer with the report_office_status tool bound to a harness Hub."""
    server = MCPServer(
        name="agent-office",
        title="Agent Office",
        version="0.3.0",
        instructions="Live status for the Agent Office dashboard. Call report_office_status when you start a "
                     "task, make progress, run a tool, finish or fail. Failures are harmless: carry on.",
    )

    @server.tool(name="report_office_status", title="Report office status", description=TOOL_DESCRIPTION,
                 structured_output=False)
    def report_office_status(
        agent: Annotated[str, Field(description="Your bot name as in the office, e.g. \"Android Dev\" "
                                                "(case-insensitive; the agent id also works).")],
        action: Annotated[Literal["start_task", "thinking", "run_tool", "finish", "error"],
                          Field(description="start_task, thinking, run_tool, finish or error.")],
        detail: Annotated[str, Field(description="One short sentence about what is happening "
                                                 f"(max {MAX_DETAIL} characters).")] = "",
    ) -> str:
        name = clean_text(agent, MAX_AGENT)
        target = hub.find_agent(name)
        if target is None:
            names = ", ".join(hub.agent_names())
            raise ToolError(f"Unknown agent {name!r}. Use your name exactly as in the office. Valid names: {names}")
        if action not in ACTIONS:  # the schema already enforces this
            raise ToolError(f"Unknown action {action!r}. Use one of: {', '.join(ACTIONS)}")
        hub.apply_report(target, action, clean_text(detail, MAX_DETAIL))
        return "ok"

    return server


class OfficeMCP:
    """Runs the MCP app with uvicorn inside the harness's event loop."""

    def __init__(self, hub: Any, token: str, rate_per_min: int = 60) -> None:
        self.mcp = build_mcp(hub)
        sdk_app = self.mcp.streamable_http_app(
            streamable_http_path=MCP_PATH,
            stateless_http=True,
            json_response=True,
            max_request_body_size=64 * 1024,
            transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
        )
        self.app = AuthGuard(sdk_app, token, rate_per_min)
        self.server: Any = None
        self.task: asyncio.Task[Any] | None = None
        self.port = 0

    async def start(self, host: str, port: int) -> None:
        import uvicorn

        class _Server(uvicorn.Server):
            @contextlib.contextmanager
            def capture_signals(self):  # the harness owns SIGINT/SIGTERM
                yield

        config = uvicorn.Config(self.app, host=host, port=port, log_level="warning", lifespan="on",
                                access_log=False, server_header=False, timeout_graceful_shutdown=3)
        self.server = _Server(config)
        # Bind here so "port in use" surfaces as a plain OSError.
        sock = socket.create_server((host, port), reuse_port=False)
        sock.setblocking(False)
        self.task = asyncio.create_task(self.server.serve(sockets=[sock]), name="mcp-http")
        for _ in range(200):  # wait until it is listening (or failed)
            if self.server.started or self.task.done():
                break
            await asyncio.sleep(0.025)
        if self.task.done():
            exc = self.task.exception() if not self.task.cancelled() else None
            raise OSError(f"MCP server failed to start on {host}:{port}: {exc}")
        sockets = [s for srv in self.server.servers for s in srv.sockets]
        self.port = sockets[0].getsockname()[1] if sockets else port

    async def stop(self) -> None:
        if self.server is None or self.task is None:
            return
        self.server.should_exit = True
        with contextlib.suppress(asyncio.TimeoutError, asyncio.CancelledError, Exception):
            await asyncio.wait_for(self.task, 5)
