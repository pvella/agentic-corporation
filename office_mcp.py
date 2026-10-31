"""
office_mcp.py - Remote MCP connector for Agent Office live status.

Started by agent_harness.py (unless --no-mcp). Serves the MCP Streamable HTTP
transport at http://127.0.0.1:8766/mcp using the official `mcp` Python SDK
(MCPServer, stateless, JSON responses), so a cloud-hosted bot (e.g. a Grok Bot
connector) can call office tools including vault helpers:

  report_office_status(agent, action, detail)
      agent   the bot's name as in office.json ("Android Dev"); case-insensitive,
              the agent_id ("android_dev") works too
      action  start_task | thinking | run_tool | finish | error
      detail  one short sentence (control characters stripped, max 200 chars)
      -> "ok", or "ok (N unread messages: call check_office_inbox)"
  check_office_inbox(agent)
      -> the prompts Paul typed into that agent's terminal (id, age, text),
         now marked delivered; or "no messages"
  reply_office_message(agent, reply, message_id="", show_bubble=true)
      prints the reply in the agent's terminal ("<name>> ..."), plain text,
      max 2000 chars / 40 lines; message_id empty = unsolicited note

Security:
  * Every HTTP request needs "Authorization: Bearer <token>" or gets 401.
    The token comes from env OFFICE_MCP_TOKEN, else .office_token next to this
    file (generated on first run with 256 bits of randomness, chmod 600).
  * Token-bucket rate limit per token (default 60/min, bursts of 20) -> 429.
  * Repeated bad tokens from one client are slowed down and then refused (429).
  * Binds to 127.0.0.1 by default; expose it with Tailscale Funnel (see README).
    DNS-rebinding Host checks are off because Funnel forwards the public
    *.ts.net Host header; the bearer token is what guards the endpoint.

If the harness is not running, the bots' calls simply fail; status reports are
not queued. Dashboard messages for the bots are kept in .office_inbox.json.
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

from agent_harness import age_text
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
    "'detail' is one short sentence. Returns \"ok\", plus a note when Paul has left you messages. "
    "After reporting, if there might be messages for you (or the result mentions unread messages), "
    "call check_office_inbox. If the call fails, ignore it and carry on."
)
INBOX_DESCRIPTION = (
    "Fetch messages Paul typed into your terminal in the Agent Office dashboard. Returns each pending "
    "message with its id, text and age, then marks them delivered; returns \"no messages\" if there are none. "
    "Answer with reply_office_message (pass the message_id). 'agent' is your bot name as in the office."
)
REPLY_DESCRIPTION = (
    "Post a reply in your terminal in the Agent Office dashboard (shown as \"<your name>> ...\"), "
    "optionally with a short speech bubble over your character. Pass message_id to answer a message from "
    "check_office_inbox, or leave it empty for an unsolicited note. Plain text, up to 2000 characters."
)
AgentName = Annotated[str, Field(description="Your bot name as in the office, e.g. \"Android Dev\" "
                                             "(case-insensitive; the agent id also works).")]


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
                     "task, make progress, run a tool, finish or fail. When it mentions unread messages (or when "
                     "you check in on a routine), call check_office_inbox and answer with reply_office_message. "
                     "Failures are harmless: carry on.",
    )

    @server.tool(name="report_office_status", title="Report office status", description=TOOL_DESCRIPTION,
                 structured_output=False)
    def report_office_status(
        agent: AgentName,
        action: Annotated[Literal["start_task", "thinking", "run_tool", "finish", "error"],
                          Field(description="start_task, thinking, run_tool, finish or error.")],
        detail: Annotated[str, Field(description="One short sentence about what is happening "
                                                 f"(max {MAX_DETAIL} characters).")] = "",
    ) -> str:
        target = _agent(hub, agent)
        if action not in ACTIONS:  # the schema already enforces this
            raise ToolError(f"Unknown action {action!r}. Use one of: {', '.join(ACTIONS)}")
        hub.apply_report(target, action, clean_text(detail, MAX_DETAIL))
        unread = hub.inbox.unread(target.agent_id)
        if unread:
            return f"ok ({unread} unread message{'s' if unread != 1 else ''}: call check_office_inbox)"
        return "ok"

    @server.tool(name="check_office_inbox", title="Check office inbox", description=INBOX_DESCRIPTION,
                 structured_output=False)
    def check_office_inbox(agent: AgentName) -> str:
        target = _agent(hub, agent)
        items = hub.deliver_messages(target)
        if not items:
            return "no messages"
        now = time.time()
        out = [f"{len(items)} message{'s' if len(items) != 1 else ''} from Paul (now marked delivered; "
               "answer with reply_office_message):"]
        for item in items:
            out.append(f"- id {item['id']} ({age_text(now - item['created'])}): {item['text']}")
        return "\n".join(out)

    @server.tool(name="reply_office_message", title="Reply in the office", description=REPLY_DESCRIPTION,
                 structured_output=False)
    def reply_office_message(
        agent: AgentName,
        reply: Annotated[str, Field(description="Your reply, plain text (max 2000 characters).")],
        message_id: Annotated[str, Field(description="The id from check_office_inbox, or empty for an "
                                                     "unsolicited note.")] = "",
        show_bubble: Annotated[bool, Field(description="Also show the start of the reply as a speech "
                                                       "bubble over your character.")] = True,
    ) -> str:
        target = _agent(hub, agent)
        mid = clean_text(message_id, 32).lstrip("#")
        if mid and hub.inbox.find(target.agent_id, mid) is None:
            raise ToolError(f"Unknown message_id {mid!r} for {target.name}. Use an id from check_office_inbox, "
                            "or leave message_id empty for a note.")
        if not clean_text(reply, 10):
            raise ToolError("reply is empty")
        hub.post_reply(target, reply, mid, bubble=show_bubble)
        return "ok"

    @server.tool(
        name="request_secret",
        title="Request a vault secret",
        description=(
            "Ask the human owner for a new secret. Opens a masked input card in the office. "
            "On approval the value is stored in the OS keychain and granted to you as an env var "
            "with the given NAME. You never see the value. If declined, do not request that name again."
        ),
    )
    def request_secret(
        agent: AgentName,
        name: Annotated[str, Field(description="Env var name, e.g. GITHUB_TOKEN (letters/digits/underscore).")],
        label: Annotated[str, Field(description="Short human-facing title for the secret card.")] = "",
        description: Annotated[str, Field(description="Why you need it / what it is used for.")] = "",
    ) -> str:
        a = _agent(hub, agent)
        vault = getattr(hub, "vault", None)
        if vault is None:
            return "vault unavailable"
        try:
            req = vault.add_request(a.agent_id, name, label=label or name, description=description)
        except PermissionError as exc:
            return str(exc)
        except Exception as exc:
            return f"vault request failed: {exc}"
        hub.emit({
            "type": "VAULT_SECRET_REQUEST",
            "request_id": req["request_id"],
            "agent_id": a.agent_id,
            "agent_name": a.name,
            "name": req["name"],
            "label": req.get("label") or req["name"],
            "description": req.get("description") or "",
            "prompt": (
                f"{a.name} requests secret '{req['name']}'. "
                f"{req.get('description') or 'Enter the value (stored in the keychain, never shown again).'}"
            ),
        })
        hub.emit({
            "type": "VAULT_NOTICE",
            "kind": "vault_request",
            "title": f"Vault request — {req['name']}",
            "detail": f"from {a.name}",
            "pending": True,
            "meta": {"name": req["name"], "agent_id": a.agent_id, "request_id": req["request_id"]},
        })
        return (
            f"Secret request for '{req['name']}' sent to the human owner. "
            f"When granted you will have env var ${req['name']}; never print its value."
        )

    @server.tool(
        name="vault_list",
        title="List vault secrets (metadata)",
        description=(
            "Chief of Staff only. List vault secret names, descriptions and which agents have access. "
            "Never returns values."
        ),
    )
    def vault_list(agent: AgentName) -> str:
        a = _agent(hub, agent)
        from agent_harness import is_chief_of_staff
        if not is_chief_of_staff(a):
            return "only the Chief of Staff may list the vault"
        vault = getattr(hub, "vault", None)
        if vault is None:
            return "vault unavailable"
        lines = ["Vault secrets (names only):"]
        for e in vault.list_meta():
            agents = e.get("agents")
            who = "all" if agents == "all" else (", ".join(agents) if agents else "(none)")
            lines.append(f"- {e['name']}: {e.get('description') or '(no description)'} [agents: {who}]")
        if vault.pending:
            lines.append("Pending requests:")
            for pend in vault.pending:
                lines.append(f"- {pend.get('name')} from {pend.get('agent_id')} ({pend.get('request_id')})")
        if len(lines) == 1:
            lines.append("(empty)")
        hub.emit({"type": "VAULT_NOTICE", "kind": "vault_list", "title": "Vault listed by CoS",
                  "detail": f"{len(vault.list_meta())} secrets", "pending": False,
                  "meta": {"agent_id": a.agent_id}})
        return "\n".join(lines)

    @server.tool(
        name="vault_grant",
        title="Grant vault secret access",
        description="Chief of Staff only. Grant an agent (or 'all') access to a named secret. Metadata only.",
    )
    def vault_grant(
        agent: AgentName,
        name: Annotated[str, Field(description="Secret name.")],
        grantee: Annotated[str, Field(description="agent_id to grant, or 'all'.")],
    ) -> str:
        a = _agent(hub, agent)
        from agent_harness import is_chief_of_staff
        if not is_chief_of_staff(a):
            return "only the Chief of Staff may grant vault access"
        vault = getattr(hub, "vault", None)
        if vault is None:
            return "vault unavailable"
        try:
            meta = vault.grant(name, grantee)
        except Exception as exc:
            return f"grant failed: {exc}"
        hub.emit({
            "type": "VAULT_NOTICE", "kind": "vault_grant",
            "title": f"Vault grant {name} → {grantee}",
            "detail": f"by {a.name}", "pending": False,
            "meta": {"name": name, "grantee": grantee, "agents": meta.get("agents", []), "by": "cos"},
        })
        hub.emit({"type": "VAULT_META", "secrets": vault.list_meta(), "pending": list(vault.pending)})
        return f"granted '{name}' to {grantee}"

    @server.tool(
        name="vault_revoke",
        title="Revoke vault secret access",
        description="Chief of Staff only. Revoke an agent's (or all) access to a named secret.",
    )
    def vault_revoke(
        agent: AgentName,
        name: Annotated[str, Field(description="Secret name.")],
        grantee: Annotated[str, Field(description="agent_id to revoke, or 'all'.")],
    ) -> str:
        a = _agent(hub, agent)
        from agent_harness import is_chief_of_staff
        if not is_chief_of_staff(a):
            return "only the Chief of Staff may revoke vault access"
        vault = getattr(hub, "vault", None)
        if vault is None:
            return "vault unavailable"
        try:
            meta = vault.revoke(name, grantee)
        except Exception as exc:
            return f"revoke failed: {exc}"
        hub.emit({
            "type": "VAULT_NOTICE", "kind": "vault_revoke",
            "title": f"Vault revoke {name} ✕ {grantee}",
            "detail": f"by {a.name}", "pending": False,
            "meta": {"name": name, "grantee": grantee, "agents": meta.get("agents", []), "by": "cos"},
        })
        hub.emit({"type": "VAULT_META", "secrets": vault.list_meta(), "pending": list(vault.pending)})
        return f"revoked '{name}' from {grantee}"

    @server.tool(
        name="vault_request_remove",
        title="Request vault secret removal",
        description=(
            "Chief of Staff only. Ask the human owner to delete a secret. "
            "Does not delete immediately — opens a confirm dialog. CoS never sees values."
        ),
    )
    def vault_request_remove(
        agent: AgentName,
        name: Annotated[str, Field(description="Secret name to remove.")],
    ) -> str:
        a = _agent(hub, agent)
        from agent_harness import is_chief_of_staff
        if not is_chief_of_staff(a):
            return "only the Chief of Staff may request vault removal"
        vault = getattr(hub, "vault", None)
        if vault is None:
            return "vault unavailable"
        if not vault.get_meta(name):
            return f"unknown secret '{name}'"
        request_id = f"vault_rm_{a.agent_id}_{name}"
        hub.emit({
            "type": "VAULT_REMOVE_CONFIRM",
            "name": name,
            "request_id": request_id,
            "prompt": f"Chief of Staff requests deletion of vault secret '{name}'. Confirm?",
        })
        hub.emit({
            "type": "VAULT_NOTICE", "kind": "vault_rm_pending",
            "title": f"Vault remove pending — {name}",
            "detail": f"requested by {a.name}", "pending": True,
            "meta": {"name": name, "request_id": request_id, "agent_id": a.agent_id},
        })
        return f"removal of '{name}' awaits human confirmation"


    return server


def _agent(hub: Any, agent: str) -> Any:
    name = clean_text(agent, MAX_AGENT)
    target = hub.find_agent(name)
    if target is None:
        names = ", ".join(hub.agent_names())
        raise ToolError(f"Unknown agent {name!r}. Use your name exactly as in the office. Valid names: {names}")
    return target


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
