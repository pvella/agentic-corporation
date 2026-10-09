"""Tests for the MCP live-status connector (office_mcp.py + agent_harness.py).

    python3 -m unittest discover -s tests -p 'test_*.py' -v

Needs the packages in requirements.txt (websockets, mcp). Each test starts a
real harness on free localhost ports and talks to it over HTTP and WebSocket.
"""
from __future__ import annotations

import asyncio
import json
import os
import socket
import stat
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import agent_harness  # noqa: E402
import office_mcp  # noqa: E402
from websockets.asyncio.client import connect  # noqa: E402

TOKEN = "test-token-0123456789abcdef"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HarnessCase(unittest.IsolatedAsyncioTestCase):
    extra_args: list[str] = []

    async def asyncSetUp(self) -> None:
        os.environ[office_mcp.TOKEN_ENV] = TOKEN
        self.ws_port, self.mcp_port = free_port(), free_port()
        args = agent_harness.build_parser().parse_args(
            ["--port", str(self.ws_port), "--mcp-port", str(self.mcp_port), *self.extra_args])
        self.harness = agent_harness.Harness(args)
        self.task = asyncio.create_task(self.harness.run())
        for _ in range(200):
            if self.harness.mcp_server is not None and self.harness.mcp_server.port:
                break
            await asyncio.sleep(0.025)
        self.assertIsNotNone(self.harness.mcp_server, "MCP server did not start")
        self.url = f"http://127.0.0.1:{self.mcp_port}/mcp"
        self._id = 0

    async def asyncTearDown(self) -> None:
        self.harness.request_stop()
        await asyncio.wait_for(self.task, 10)
        os.environ.pop(office_mcp.TOKEN_ENV, None)

    # -- HTTP helpers --------------------------------------------------------
    async def http(self, method: str = "POST", body: dict | None = None, token: str | None = TOKEN,
                   path: str = "/mcp") -> tuple[int, dict]:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": "2025-03-26"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"http://127.0.0.1:{self.mcp_port}{path}", data=data, headers=headers,
                                     method=method)

        def go() -> tuple[int, dict]:
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    raw = resp.read()
                    return resp.status, json.loads(raw) if raw else {}
            except urllib.error.HTTPError as exc:
                raw = exc.read()
                return exc.code, json.loads(raw) if raw else {}

        return await asyncio.to_thread(go)

    async def rpc(self, method: str, params: dict | None = None, token: str | None = TOKEN) -> tuple[int, dict]:
        self._id += 1
        body = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            body["params"] = params
        return await self.http("POST", body, token)

    async def initialize(self) -> dict:
        status, resp = await self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                                     "clientInfo": {"name": "unittest", "version": "1"}})
        self.assertEqual(status, 200, resp)
        status, _ = await self.http("POST", {"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual(status, 202)
        return resp["result"]

    async def call(self, agent: str, action: str, detail: str | None = None) -> dict:
        args = {"agent": agent, "action": action}
        if detail is not None:
            args["detail"] = detail
        status, resp = await self.rpc("tools/call", {"name": "report_office_status", "arguments": args})
        self.assertEqual(status, 200, resp)
        return resp["result"]


class AuthTests(HarnessCase):
    async def test_missing_token_is_401(self) -> None:
        status, body = await self.rpc("tools/list", token=None)
        self.assertEqual(status, 401)
        self.assertIn("Bearer", body["error"])

    async def test_bad_token_is_401(self) -> None:
        status, _ = await self.rpc("tools/list", token="wrong-token-wrong-token")
        self.assertEqual(status, 401)

    async def test_get_and_delete_are_405(self) -> None:
        self.assertEqual((await self.http("GET"))[0], 405)
        self.assertEqual((await self.http("DELETE"))[0], 405)

    async def test_other_paths_404(self) -> None:
        self.assertEqual((await self.http("POST", {}, path="/"))[0], 404)


class ToolTests(HarnessCase):
    async def test_initialize_and_tools_list(self) -> None:
        result = await self.initialize()
        self.assertEqual(result["serverInfo"]["name"], "agent-office")
        status, resp = await self.rpc("tools/list")
        self.assertEqual(status, 200)
        tools = {t["name"]: t for t in resp["result"]["tools"]}
        self.assertIn("report_office_status", tools)
        schema = tools["report_office_status"]["inputSchema"]
        self.assertEqual(set(schema["required"]), {"agent", "action"})
        self.assertEqual(schema["properties"]["action"]["enum"],
                         ["start_task", "thinking", "run_tool", "finish", "error"])

    async def test_valid_call_reaches_websocket_client(self) -> None:
        await self.initialize()
        async with connect(f"ws://127.0.0.1:{self.ws_port}") as ws:
            first = json.loads(await ws.recv())
            self.assertEqual(first["type"], "OFFICE_LAYOUT")
            self.assertEqual(json.loads(await ws.recv())["type"], "SNAPSHOT")
            result = await self.call("  android DEV ", "start_task", "Building the release APK")
            self.assertFalse(result.get("isError"), result)
            self.assertEqual(result["content"][0]["text"], "ok")
            seen = await self.wait_for(ws, lambda e: e["type"] == "STATE_CHANGE" and e["agent_id"] == "android_dev")
            self.assertEqual(seen["state"], "WORKING")
            self.assertEqual(seen["target"], "Desk_android_dev")
            self.assertEqual(seen["text"], "Building the release APK")

            for action, state in (("thinking", "THINKING"), ("run_tool", "WORKING"), ("error", "ERROR"),
                                  ("finish", "IDLE")):
                await self.call("android_dev", action, f"step {action}")
                ev = await self.wait_for(ws, lambda e: e["type"] == "STATE_CHANGE" and e["agent_id"] == "android_dev")
                self.assertEqual(ev["state"], state, action)
                if action == "finish":
                    self.assertIn(ev["target"], agent_harness.SHARED_BREAK_SPOTS)
                else:
                    self.assertEqual(ev["target"], "Desk_android_dev")
        agent = self.harness.hub.agents["android_dev"]
        self.assertTrue(any("step run_tool" in line for line in agent.logs))

    async def wait_for(self, ws, pred, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            self.assertGreater(left, 0, "event not received")
            ev = json.loads(await asyncio.wait_for(ws.recv(), left))
            if pred(ev):
                return ev

    async def test_unknown_agent_lists_valid_names(self) -> None:
        result = await self.call("Nobody Bot", "finish")
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("Unknown agent 'Nobody Bot'", text)
        self.assertIn("Android Dev", text)
        self.assertIn("PTC Odoo", text)

    async def test_bad_action_is_rejected(self) -> None:
        result = await self.call("Android Dev", "explode")
        self.assertTrue(result["isError"])

    async def test_detail_is_truncated_and_cleaned(self) -> None:
        nasty = "\x1b[31mred\x1b[0m line\nbreak\x00\u202e" + "x" * 500
        await self.call("iOS Dev", "run_tool", nasty)
        agent = self.harness.hub.agents["ios_dev"]
        self.assertLessEqual(len(agent.text), office_mcp.MAX_DETAIL)
        self.assertTrue(agent.text.startswith("red line break "), agent.text)
        self.assertTrue(agent.text.endswith("\u2026"))
        self.assertFalse(any(ord(c) < 32 or c == "\u202e" for c in agent.text))


class MixedModeTests(HarnessCase):
    async def test_reported_agent_is_left_alone_by_the_simulation(self) -> None:
        director = self.harness.director
        self.assertIsNotNone(director)
        hub = self.harness.hub
        await self.call("Finance Bot", "start_task", "Reconciling the real ledger")
        fin, ea = hub.agents["finance_bot"], hub.agents["ea"]
        self.assertTrue(fin.is_live())
        self.assertFalse(director.free(fin), "simulation must not drive a live agent")
        self.assertTrue(director.free(ea), "other agents keep the mock behaviour")
        for _ in range(20):  # ticks never overwrite the real status
            director.tick()
        self.assertEqual(fin.state, "WORKING")
        self.assertEqual(fin.text, "Reconciling the real ledger")
        fin.live_until = time.monotonic() - 1  # the hold ran out
        self.assertTrue(director.free(fin))
        self.assertEqual(fin.live_until, 0.0)


class LiveModeTests(HarnessCase):
    extra_args = ["--mode", "live", "--live-hold", "5"]

    async def test_live_mode_has_no_simulation(self) -> None:
        self.assertIsNone(self.harness.director)
        hub = self.harness.hub
        self.assertTrue(all(a.state == "IDLE" and a.target == a.desk for a in hub.agents.values()))
        await self.call("PTC Odoo", "finish", "Invoices posted")
        ptc = hub.agents["ptc_odoo"]
        self.assertEqual(ptc.state, "IDLE")
        self.assertIn(ptc.target, ("ptc_Coffee", "ptc_Water"))  # the isolated wing's own kitchenette
        self.assertEqual(hub.live_hold, 5.0)


class RateLimitTests(HarnessCase):
    extra_args = ["--mcp-rate", "3"]

    async def test_rate_limited(self) -> None:
        codes = [(await self.rpc("tools/list"))[0] for _ in range(6)]
        self.assertEqual(codes[:3], [200, 200, 200])
        self.assertIn(429, codes[3:])


class TokenFileTests(unittest.TestCase):
    def test_token_generated_once_with_mode_600(self) -> None:
        saved = os.environ.pop(office_mcp.TOKEN_ENV, None)
        try:
            with tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, ".office_token")
                token, source, created = office_mcp.load_token(path)
                self.assertTrue(created)
                self.assertEqual(source, path)
                self.assertGreaterEqual(len(token), 40)
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
                again, _, created2 = office_mcp.load_token(path)
                self.assertEqual(again, token)
                self.assertFalse(created2)
                os.environ[office_mcp.TOKEN_ENV] = "from-the-environment-123"
                env_token, env_source, _ = office_mcp.load_token(path)
                self.assertEqual(env_token, "from-the-environment-123")
                self.assertEqual(env_source, "$OFFICE_MCP_TOKEN")
        finally:
            os.environ.pop(office_mcp.TOKEN_ENV, None)
            if saved is not None:
                os.environ[office_mcp.TOKEN_ENV] = saved

    def test_clean_text(self) -> None:
        self.assertEqual(office_mcp.clean_text("  a\tb\r\nc  "), "a b c")
        self.assertEqual(len(office_mcp.clean_text("y" * 999)), office_mcp.MAX_DETAIL)


if __name__ == "__main__":
    unittest.main()
