#!/usr/bin/env python3
"""
Smoke-test client for agent_harness.py.

  python3 tools/test_client.py                 # mock mode checks
  python3 tools/test_client.py --expect-cli    # cli mode checks (ANSI lines + exit code)

Connects, checks the SNAPSHOT, watches ambient events for a few seconds, then
sends DISPATCH_PROMPT to coder_agent and verifies the reaction sequence:
ACK -> THINKING -> WORKING@Desk_Coder -> LOG_ENTRY... -> IDLE.
Exits non-zero on failure.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from typing import Any

from websockets.asyncio.client import connect


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8765")
    ap.add_argument("--ambient-seconds", type=float, default=6.0)
    ap.add_argument("--expect-cli", action="store_true")
    ap.add_argument("--agent", default="coder_agent")
    ap.add_argument("--timeout", type=float, default=40.0)
    ap.add_argument("--expect-layout", choices=("auto", "yes", "no"), default="auto",
                    help="require (yes) or forbid (no) an OFFICE_LAYOUT before the SNAPSHOT")
    ap.add_argument("--min-ambient-events", type=int, default=1,
                    help="fail if fewer ambient events arrive (use 0 for --tempo calm)")
    args = ap.parse_args()

    async with connect(args.url) as ws:
        snap = json.loads(await asyncio.wait_for(ws.recv(), 5))
        layout = None
        if snap.get("type") == "OFFICE_LAYOUT":
            layout = snap["office"]
            snap = json.loads(await asyncio.wait_for(ws.recv(), 5))
        if args.expect_layout == "yes" and layout is None:
            fail("expected OFFICE_LAYOUT before SNAPSHOT")
        if args.expect_layout == "no" and layout is not None:
            fail("did not expect OFFICE_LAYOUT (legacy mode)")
        if snap.get("type") != "SNAPSHOT":
            fail(f"first message was {snap.get('type')}, expected SNAPSHOT")
        ids = [a["agent_id"] for a in snap["agents"]]
        print(f"SNAPSHOT ok: mode={snap['server']['mode']} tempo={snap['server'].get('tempo')} "
              f"{len(ids)} agents: {ids if len(ids) <= 4 else ids[:4] + ['...']}")
        if layout is not None:
            members = [m["agent_id"] for r in layout["rooms"] for m in r["members"]]
            if sorted(members) != sorted(ids):
                fail("OFFICE_LAYOUT members do not match SNAPSHOT agents")
            for r in layout["rooms"]:
                for key in ("id", "name", "color", "desks", "members", "break_spots", "meeting_target", "isolated"):
                    if key not in r:
                        fail(f"room {r.get('id')} missing '{key}'")
            by_id = {a["agent_id"]: a for a in snap["agents"]}
            if any(by_id[m]["desk"] != f"Desk_{m}" for m in members):
                fail("desk waypoints should be named Desk_<agent_id>")
            print(f"OFFICE_LAYOUT ok: {len(layout['rooms'])} rooms "
                  f"({', '.join(r['name'] + (' [isolated]' if r['isolated'] else '') for r in layout['rooms'])})")
        for key in ("agent_id", "name", "desk", "color", "state", "logs"):
            if key not in snap["agents"][0]:
                fail(f"snapshot agent missing '{key}'")

        # 1) ambient / periodic events
        counts: dict[str, int] = {}
        end = time.monotonic() + args.ambient_seconds
        while time.monotonic() < end:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), max(0.05, end - time.monotonic())))
            except asyncio.TimeoutError:
                break
            counts[msg["type"]] = counts.get(msg["type"], 0) + 1
        print(f"ambient events in {args.ambient_seconds:.0f}s: {counts or 'none'}")
        if not args.expect_cli and sum(counts.values()) < args.min_ambient_events:
            fail(f"expected at least {args.min_ambient_events} ambient events, got {counts}")

        # 2) bad input is rejected politely
        await ws.send("not json")
        await ws.send(json.dumps({"action": "DISPATCH_PROMPT", "agent_id": "nobody", "prompt": "x"}))

        # 3) dispatch a prompt and verify the reaction
        prompt = "Fix bug in auth.py"
        await ws.send(json.dumps({"action": "DISPATCH_PROMPT", "agent_id": args.agent, "prompt": prompt}))
        sent_at = time.monotonic()
        first_reaction: float | None = None
        seq: list[str] = []
        logs: list[str] = []
        errors = 0
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            msg: dict[str, Any] = json.loads(await asyncio.wait_for(ws.recv(), args.timeout))
            t = msg.get("type")
            if t == "ERROR":
                errors += 1
                print(f"  ERROR reply (expected for bad input): {msg['message']}")
                continue
            if t == "ACK" and msg.get("agent_id") == args.agent:
                seq.append("ACK")
            if msg.get("agent_id") != args.agent:
                continue
            if t == "STATE_CHANGE" and first_reaction is None and "ACK" in seq:
                first_reaction = time.monotonic() - sent_at
            if t == "STATE_CHANGE":
                tag = msg["state"] + (f"@{msg['target']}" if msg.get("target") else "")
                if not seq or seq[-1] != tag:
                    seq.append(tag)
                print(f"  STATE_CHANGE {tag:28} {msg.get('text', '')!r}")
                # Only count the IDLE that ends *our* run (after we've seen WORKING at the desk).
                if msg["state"] == "IDLE" and any(s.startswith("WORKING@") for s in seq) and logs:
                    break
            elif t == "LOG_ENTRY" and "ACK" in seq:
                logs.append(msg["log"])
                print(f"  LOG_ENTRY [{msg.get('stream', 'stdout')}] {msg['log']!r}")
        else:
            fail(f"timed out; sequence so far {seq}")

        print("sequence:", " -> ".join(seq))
        if first_reaction is not None:
            print(f"prompt reaction latency: {first_reaction * 1000:.0f} ms")
            if first_reaction > 2.0:
                fail("agent took more than 2s to react to the prompt")
        if errors < 2:
            fail("expected 2 ERROR replies for bad input")
        try:
            i_ack = seq.index("ACK")
            i_think = next(i for i, s in enumerate(seq) if s.startswith("THINKING") and i > i_ack)
            i_work = next(i for i, s in enumerate(seq) if s.startswith("WORKING@Desk_") and i > i_think)
            i_idle = next(i for i, s in enumerate(seq) if s.startswith("IDLE") and i > i_work)
        except (ValueError, StopIteration):
            fail(f"unexpected sequence {seq}")
        if not logs:
            fail("no LOG_ENTRY during the run")
        if args.expect_cli:
            ansi = [l for l in logs if "\x1b[32mline" in l]
            if len(ansi) != 3:
                fail(f"expected 3 green ANSI lines from the CLI, got {ansi}")
            if not any("exited with code 0" in l for l in logs):
                fail("missing exit code log")

        await ws.send(json.dumps({"action": "REQUEST_SNAPSHOT"}))
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), 5))
            if msg["type"] == "SNAPSHOT":
                agent = next(a for a in msg["agents"] if a["agent_id"] == args.agent)
                if not any(prompt in l for l in agent["logs"]):
                    fail("snapshot log history missing the dispatched prompt")
                print(f"re-SNAPSHOT ok: {args.agent} has {len(agent['logs'])} log lines, state={agent['state']}")
                break
    print("PASS")


if __name__ == "__main__":
    asyncio.run(main())
