#!/usr/bin/env python3
"""
Measures how much the agents walk around, to check an ambient tempo.

  python3 agent_harness.py --tempo calm --speed 10 &
  python3 tools/tempo_check.py --seconds 60 --speed 10

A "walk" is any STATE_CHANGE with a new target or a COLLABORATE. Times are
reported in simulated seconds (wall-clock x --speed). It prints walks per
simulated minute, per-agent dwell times between walks, how often ambient walks
started within the walk slot of another one, and the state mix.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from collections import Counter, defaultdict

from websockets.asyncio.client import connect


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8765")
    ap.add_argument("--seconds", type=float, default=60.0, help="wall-clock seconds to observe")
    ap.add_argument("--speed", type=float, default=1.0, help="the harness --speed value")
    ap.add_argument("--walk-seconds", type=float, default=8.0,
                    help="assumed simulated duration of one walk, for the 'walking at once' estimate")
    ap.add_argument("--max-walks-per-min", type=float, default=0.0, help="fail above this rate (0 = report only)")
    args = ap.parse_args()

    walks: list[tuple[float, str, str]] = []
    states: Counter[str] = Counter()
    logs = 0
    async with connect(args.url) as ws:
        snap = json.loads(await ws.recv())
        if snap["type"] == "OFFICE_LAYOUT":
            snap = json.loads(await ws.recv())
        tempo = snap["server"].get("tempo", "?")
        current = {a["agent_id"]: a.get("target") for a in snap["agents"]}
        t0 = time.monotonic()
        end = t0 + args.seconds
        while (left := end - time.monotonic()) > 0:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), left))
            except asyncio.TimeoutError:
                break
            sim = (time.monotonic() - t0) * args.speed
            if msg["type"] == "LOG_ENTRY":
                logs += 1
            elif msg["type"] == "STATE_CHANGE":
                states[msg["state"]] += 1
                tgt = msg.get("target")
                if tgt and tgt != current.get(msg["agent_id"]):
                    current[msg["agent_id"]] = tgt
                    walks.append((sim, msg["agent_id"], tgt))
            elif msg["type"] == "COLLABORATE":
                for aid in msg["agents"]:
                    current[aid] = msg.get("target")
                    walks.append((sim, aid, msg.get("target", "Meeting_Room")))

    sim_minutes = args.seconds * args.speed / 60
    rate = len(walks) / sim_minutes
    print(f"tempo={tempo}: observed {sim_minutes:.1f} simulated minutes")
    print(f"  walks: {len(walks)}  ({rate:.2f} per minute for the whole office)")
    per_agent: dict[str, list[float]] = defaultdict(list)
    for t, aid, _ in walks:
        per_agent[aid].append(t)
    for aid, times in sorted(per_agent.items()):
        gaps = [b - a for a, b in zip(times, times[1:])]
        if gaps:
            print(f"  {aid:16} walks={len(times):3}  dwell between walks: min {min(gaps):5.1f}s  "
                  f"median {statistics.median(gaps):5.1f}s")
        else:
            print(f"  {aid:16} walks={len(times):3}")
    starts = sorted({round(t, 1) for t, _, _ in walks})
    close = sum(1 for a, b in zip(starts, starts[1:]) if b - a < 2.0)
    print(f"  distinct walk start times: {len(starts)}; starts <2s apart (meetings move 2 together): {close}")
    events = sorted([(t, 1) for t, _, _ in walks] + [(t + args.walk_seconds, -1) for t, _, _ in walks])
    cur = peak = 0
    for _, d in events:
        cur += d
        peak = max(peak, cur)
    print(f"  est. agents walking at once (walk = {args.walk_seconds:.0f}s): peak {peak}")
    print(f"  log lines: {logs}; state changes: {dict(states)}")
    print("  destinations:", dict(Counter(tgt for _, _, tgt in walks)))
    if len(per_agent) > 6:
        print("  (per-agent table above lists every agent that walked)")
    if args.max_walks_per_min and rate > args.max_walks_per_min:
        print(f"FAIL: {rate:.2f} walks/min > {args.max_walks_per_min}")
        raise SystemExit(1)
    print("OK")


if __name__ == "__main__":
    asyncio.run(main())
