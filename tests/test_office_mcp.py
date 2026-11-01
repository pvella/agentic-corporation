"""Tests for the MCP live-status connector (office_mcp.py + agent_harness.py).

    python3 -m unittest discover -s tests -p 'test_*.py' -v

Needs the packages in requirements.txt (websockets, mcp). Each test starts a
real harness on free localhost ports and talks to it over HTTP and WebSocket.
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
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


ROSTER_FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "office_roster.json")

def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HarnessCase(unittest.IsolatedAsyncioTestCase):
    extra_args: list[str] = []

    async def asyncSetUp(self) -> None:
        os.environ[office_mcp.TOKEN_ENV] = TOKEN
        self.ws_port, self.mcp_port = free_port(), free_port()
        self.tmp = tempfile.TemporaryDirectory()
        self.inbox_path = os.path.join(self.tmp.name, ".office_inbox.json")
        # A private copy of the frozen test roster: the live office.json changes
        # as agents are hired / fired, and hire/fire tests save back to it.
        self.office_path = os.path.join(self.tmp.name, "office.json")
        shutil.copyfile(ROSTER_FIXTURE, self.office_path)
        args = agent_harness.build_parser().parse_args(
            ["--port", str(self.ws_port), "--mcp-port", str(self.mcp_port), "--inbox-file", self.inbox_path,
             "--office", self.office_path, *self.extra_args])
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
        self.tmp.cleanup()

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
        return await self.tool("report_office_status", args)

    async def tool(self, name: str, args: dict) -> dict:
        status, resp = await self.rpc("tools/call", {"name": name, "arguments": args})
        self.assertEqual(status, 200, resp)
        return resp["result"]

    async def wait_for(self, ws, pred, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            self.assertGreater(left, 0, "event not received")
            ev = json.loads(await asyncio.wait_for(ws.recv(), left))
            if pred(ev):
                return ev


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

    async def test_unknown_agent_lists_valid_names(self) -> None:
        result = await self.call("Nobody Bot", "finish")
        self.assertTrue(result["isError"])
        text = result["content"][0]["text"]
        self.assertIn("Unknown agent 'Nobody Bot'", text)
        self.assertIn("Android Dev", text)
        self.assertIn("Support Desk", text)

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

    async def test_live_mode_has_no_fake_work(self) -> None:
        director = self.harness.director
        self.assertIsNotNone(director)
        self.assertTrue(director.idle_only, "live mode only simulates idle life")
        hub = self.harness.hub
        self.assertTrue(all(a.state == "IDLE" and a.target == a.desk for a in hub.agents.values()))
        await self.call("Support Desk", "finish", "Ticket closed")
        agent = hub.agents["support_desk"]
        self.assertEqual(agent.state, "IDLE")
        # finish releases the agent back to ambient idle life (desk or a break spot)
        self.assertTrue(
            agent.target == agent.desk
            or any(k in agent.target for k in (
                "Coffee", "Water", "Sofa", "Vending", "Chat", "Yoga", "Meditation", "Foosball")),
            agent.target)
        self.assertFalse(agent.is_live(), "finish hands the agent back to the ambient life")
        self.assertEqual(hub.live_hold, 5.0)


class RateLimitTests(HarnessCase):
    extra_args = ["--mcp-rate", "3"]

    async def test_rate_limited(self) -> None:
        codes = [(await self.rpc("tools/list"))[0] for _ in range(6)]
        self.assertEqual(codes[:3], [200, 200, 200])
        self.assertIn(429, codes[3:])


def is_log(agent_id: str, needle: str):
    return lambda e: e["type"] == "LOG_ENTRY" and e["agent_id"] == agent_id and needle in e["log"]


class InboxTests(HarnessCase):
    extra_args = ["--mode", "live"]

    async def open_ws(self):
        ws = await connect(f"ws://127.0.0.1:{self.ws_port}")
        self.assertEqual(json.loads(await ws.recv())["type"], "OFFICE_LAYOUT")
        snap = json.loads(await ws.recv())
        self.assertEqual(snap["type"], "SNAPSHOT")
        return ws, snap

    async def test_queue_deliver_reply_roundtrip(self) -> None:
        ws, snap = await self.open_ws()
        try:
            self.assertTrue(all(a["unread"] == 0 for a in snap["agents"]))
            await ws.send(json.dumps({"action": "DISPATCH_PROMPT", "agent_id": "android_dev",
                                      "prompt": "Can you bump the targetSdk to 35?"}))
            seen: list[dict] = []
            ack = await self.wait_for(ws, lambda e: seen.append(e) or e["type"] == "ACK")
            self.assertTrue(ack["inbox"])
            mid = ack["message_id"]
            self.assertEqual(ack["unread"], 1)
            # Quiet mode: inbox queue chatter stays in the harness log, not LOG_ENTRY.
            inbox_ev = [e for e in seen if e["type"] == "INBOX"]
            self.assertEqual([(e["agent_id"], e["unread"]) for e in inbox_ev], [("android_dev", 1)])

            # Persisted (0600) with id, text and created time.
            with open(self.inbox_path, encoding="utf-8") as fh:
                saved = json.load(fh)
            item = saved["pending"]["android_dev"][0]
            self.assertEqual((item["id"], item["text"]), (mid, "Can you bump the targetSdk to 35?"))
            self.assertAlmostEqual(item["created"], time.time(), delta=10)
            self.assertEqual(stat.S_IMODE(os.stat(self.inbox_path).st_mode), 0o600)

            # A re-snapshot carries the unread count (badge after reconnect).
            await ws.send(json.dumps({"action": "REQUEST_SNAPSHOT"}))
            snap2 = await self.wait_for(ws, lambda e: e["type"] == "SNAPSHOT")
            unread = {a["agent_id"]: a["unread"] for a in snap2["agents"]}
            self.assertEqual(unread["android_dev"], 1)

            # report_office_status nudges the bot.
            res = await self.call("Android Dev", "start_task", "Morning check-in")
            self.assertEqual(res["content"][0]["text"], "ok (1 unread message: call check_office_inbox)")

            res = await self.tool("check_office_inbox", {"agent": "android dev"})
            text = res["content"][0]["text"]
            self.assertIn(f"id {mid}", text)
            self.assertIn("Can you bump the targetSdk to 35?", text)
            self.assertRegex(text, r"\(\d+s ago\)")
            # Quiet mode: delivery is harness-log only; INBOX unread=0 is the signal.
            ev = await self.wait_for(ws, lambda e: e["type"] == "INBOX" and e.get("unread") == 0)
            self.assertEqual(ev["unread"], 0)
            res = await self.tool("check_office_inbox", {"agent": "android_dev"})
            self.assertEqual(res["content"][0]["text"], "no messages")
            self.assertEqual(self.harness.hub.inbox.unread("android_dev"), 0)
            self.assertEqual((await self.call("Android Dev", "thinking"))["content"][0]["text"], "ok")

            res = await self.tool("reply_office_message", {"agent": "Android Dev", "message_id": mid,
                                                           "reply": "Done, PR is up.\nCI is green."})
            self.assertEqual(res["content"][0]["text"], "ok")
            first = await self.wait_for(ws, is_log("android_dev", "Android Dev>"))
            self.assertIn("Done, PR is up.", first["log"])
            self.assertIn(f"re #{mid}", first["log"])
            second = json.loads(await ws.recv())
            self.assertEqual(second["type"], "LOG_ENTRY")
            self.assertEqual(second["log"].strip(), "CI is green.")
            bubble = await self.wait_for(ws, lambda e: e["type"] == "STATE_CHANGE" and e["agent_id"] == "android_dev")
            self.assertEqual(bubble["text"], "Done, PR is up. CI is green.")
            self.assertNotIn("target", bubble)  # a reply never moves the character
        finally:
            await ws.close()

    async def test_reply_without_id_is_a_note_and_is_sanitised(self) -> None:
        ws, _ = await self.open_ws()
        try:
            nasty = "[b]bold[/b] \x1b[31mred\x1b[0m \x1b]8;;http://x\x07link\x1b]8;;\x07\x00\u202e[url=x]y[/url]"
            res = await self.tool("reply_office_message", {"agent": "EA", "reply": nasty, "show_bubble": False})
            self.assertFalse(res.get("isError"), res)
            ev = await self.wait_for(ws, is_log("ea", "EA>"))
            body = ev["log"].split("EA>\x1b[0m ", 1)[1]
            self.assertEqual(body, "[b]bold[/b] red link [url=x]y[/url]")  # Godot escapes '[' when rendering
            self.assertNotIn("\x1b", body)
            # Long replies are capped at 2000 characters.
            await self.tool("reply_office_message", {"agent": "EA", "reply": "z" * 5000, "show_bubble": False})
            ev = await self.wait_for(ws, is_log("ea", "zzz"))
            self.assertLessEqual(len(ev["log"].split("EA>\x1b[0m ", 1)[1]), agent_harness.MAX_REPLY)
        finally:
            await ws.close()

    async def test_reply_errors(self) -> None:
        res = await self.tool("reply_office_message", {"agent": "EA", "reply": "hi", "message_id": "nope42"})
        self.assertTrue(res["isError"])
        self.assertIn("Unknown message_id", res["content"][0]["text"])
        res = await self.tool("reply_office_message", {"agent": "EA", "reply": " \x00 "})
        self.assertTrue(res["isError"])
        res = await self.tool("check_office_inbox", {"agent": "Nobody"})
        self.assertTrue(res["isError"])
        self.assertIn("Valid names", res["content"][0]["text"])

    async def test_inbox_cap(self) -> None:
        hub = self.harness.hub
        agent = hub.agents["support_desk"]
        for i in range(agent_harness.INBOX_CAP):
            self.assertIsNotNone(hub.queue_message(agent, f"msg {i}"))
        self.assertIsNone(hub.queue_message(agent, "one too many"))
        ws, _ = await self.open_ws()
        try:
            await ws.send(json.dumps({"action": "DISPATCH_PROMPT", "agent_id": "support_desk", "prompt": "more"}))
            err = await self.wait_for(ws, lambda e: e["type"] == "ERROR")
            self.assertIn("inbox is full", err["message"])
        finally:
            await ws.close()

    async def test_tools_list_has_all_three(self) -> None:
        status, resp = await self.rpc("tools/list")
        tools = {t["name"]: t for t in resp["result"]["tools"]}
        required = {"report_office_status", "check_office_inbox", "reply_office_message"}
        self.assertTrue(required.issubset(set(tools)), tools)
        self.assertIn("check_office_inbox", tools["report_office_status"]["description"])
        self.assertEqual(tools["check_office_inbox"]["inputSchema"]["required"], ["agent"])
        self.assertEqual(set(tools["reply_office_message"]["inputSchema"]["required"]), {"agent", "reply"})


class MixedInboxTests(HarnessCase):
    async def test_mock_mode_only_queues_for_real_bots(self) -> None:
        hub = self.harness.hub
        self.assertFalse(self.harness.inbox_for(hub.agents["ios_dev"]))  # simulated: mock runner as before
        await self.call("iOS Dev", "start_task", "real work")
        self.assertTrue(self.harness.inbox_for(hub.agents["ios_dev"]))


class InboxPersistenceTests(unittest.TestCase):
    def test_restart_keeps_pending_and_history(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "inbox.json")
            box = agent_harness.Inbox(path)
            a = box.add("ea", "first")
            box.add("ea", "second")
            box.take("ea")
            c = box.add("ea", "third")
            again = agent_harness.Inbox(path)
            self.assertEqual([i["text"] for i in again.pending["ea"]], ["third"])
            self.assertEqual(again.unread("ea"), 1)
            self.assertIsNotNone(again.find("ea", a["id"]))  # delivered ones stay answerable
            self.assertEqual(again.find("ea", c["id"])["text"], "third")
            self.assertFalse(os.path.exists(path + ".tmp"))

    def test_corrupt_file_starts_empty(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "inbox.json")
            with open(path, "w") as fh:
                fh.write("{nope")
            self.assertEqual(agent_harness.Inbox(path).unread("ea"), 0)

    def test_clean_lines(self) -> None:
        self.assertEqual(agent_harness.clean_lines("a\r\n\r\n\r\nb\x07\n\n"), ["a", "", "b"])
        self.assertEqual(len(agent_harness.clean_lines("\n".join("x" * 100))), agent_harness.MAX_REPLY_LINES)


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
