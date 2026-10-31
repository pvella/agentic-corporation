"""Tests for the ambient office life (AmbientDirector), without any sockets.

    python3 -m unittest tests.test_ambient -v

The director runs on a fake clock, so hours of simulated office life take a
fraction of a second.
"""
from __future__ import annotations

import os
import random
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import agent_harness as h  # noqa: E402

AI_SLOP = ("as an ai", "delve", "synergy", "leverage", "tapestry", "🚀")


class AmbientCase(unittest.TestCase):
    idle_only = True

    def setUp(self) -> None:
        random.seed(1234)
        office = h.load_office(None)
        self.assertIsNotNone(office, "office.json is needed for these tests")
        self.hub = h.Hub("live" if self.idle_only else "mock", "calm", office)
        h.register_office(self.hub, office)
        self.events: list[dict] = []
        emit = self.hub.emit

        def record(event: dict) -> None:
            self.events.append(dict(event))
            emit(event)

        self.hub.emit = record  # type: ignore[method-assign]
        self.clock = 0.0
        self.director = h.AmbientDirector(self.hub, h.TEMPOS["calm"], 1.0, lambda a: True, idle_only=self.idle_only)
        self.director.now = lambda: self.clock  # type: ignore[method-assign]
        self.hub.on_release = self.director.after_finish
        for agent in self.hub.agents.values():
            self.director.place_initial(agent)

    def run_for(self, seconds: float, step: float = 0.5) -> None:
        end = self.clock + seconds
        while self.clock < end:
            self.clock += step
            self.director.tick()

    def targets_of(self, agent_id: str) -> set[str]:
        out: set[str] = set()
        for e in self.events:
            if e.get("type") == "STATE_CHANGE" and e["agent_id"] == agent_id and e.get("target"):
                out.add(e["target"])
            elif e.get("type") == "COLLABORATE" and agent_id in e.get("agents", []):
                out.add(e.get("target", ""))
        return out


class IdleOnlyTests(AmbientCase):
    def test_office_comes_alive(self) -> None:
        self.run_for(3600)
        targets = set().union(*(self.targets_of(a) for a in self.hub.agents))
        kinds = {"Coffee": False, "Water": False, "Vending": False, "Sofa": False, "Foosball": False, "Chat": False}
        for t in targets:
            for k in kinds:
                if k in t:
                    kinds[k] = True
        self.assertTrue(all(kinds.values()), f"missing ambient activities: {kinds}")
        self.assertTrue(any(e.get("type") == "AMBIENT" and e.get("action") == "phone" for e in self.events))

    def test_canteen_and_rec_visited_over_idle_cycles(self) -> None:
        """Over N idle cycles, Canteen and Rec Room must each get real visits."""
        self.run_for(7200)  # ~2h simulated
        targets = set().union(*(self.targets_of(a) for a in self.hub.agents))
        canteen = {t for t in targets if t.startswith("Canteen_")}
        rec = {t for t in targets if t.startswith("Yoga_") or t.startswith("Meditation_")}
        self.assertTrue(canteen, f"Canteen never visited over idle cycles; targets={sorted(targets)[:40]}")
        self.assertTrue(rec, f"Rec Room never visited over idle cycles; targets={sorted(targets)[:40]}")
        # Counter→seat phase must complete (not bounce desk after counter-only).
        seats = {t for t in canteen if t.startswith("Canteen_Seat")}
        self.assertTrue(seats, f"Canteen counter visited but nobody sat to eat; canteen={canteen}")

    def test_amenity_chatter_matches_destination_room(self) -> None:
        """Amenity activity text in the same event as a target must match that room."""
        self.run_for(7200)
        bad: list[str] = []
        for e in self.events:
            if e.get("type") != "STATE_CHANGE":
                continue
            text = e.get("text") or ""
            target = e.get("target") or ""
            if not text or not target:
                continue
            if not h.activity_text_matches_target(text, target):
                bad.append(f"{text!r} @ {target}")
        self.assertEqual(bad, [], "activity text outside its room:\n" + "\n".join(bad[:20]))

    def test_activity_text_room_map_covers_scripted_lines(self) -> None:
        """Every scripted amenity one-liner maps to the intended campus room."""
        cases = [
            ("I'll have pizza", "canteen"),
            ("Eating a salad", "canteen"),
            ("Yoga break.", "rec"),
            ("Meditating.", "rec"),
            ("Namaste.", "rec"),
            ("Coffee time.", "break"),
            ("Mmm, coffee.", "break"),
            ("Snack run.", "break"),
            ("Grabbing some water.", "break"),
            ("Foosball, Ada?", "break"),
            ("You're on!", "break"),
            ("Goal!", "break"),
        ]
        for text, expect in cases:
            got = h.required_room_for_activity_text(text)
            self.assertEqual(got, expect, f"{text!r} → {got!r}, want {expect!r}")
        self.assertIsNone(h.required_room_for_activity_text("Anyone seen the CI logs?"))
        self.assertIsNone(h.required_room_for_activity_text("Back to it."))

    def test_idle_never_looks_like_work(self) -> None:
        self.run_for(3600)
        states = {e["state"] for e in self.events if e.get("type") == "STATE_CHANGE"}
        self.assertEqual(states, {"IDLE"}, "no fake WORKING / THINKING / meetings in live mode")
        self.assertFalse([e for e in self.events if e.get("type") in ("LOG_ENTRY", "COLLABORATE")],
                         "no fake log lines or meetings in live mode")

    def test_small_talk_is_plain(self) -> None:
        self.run_for(3600)
        lines = [e.get("text", "") for e in self.events if e.get("type") == "STATE_CHANGE" and e.get("text")]
        self.assertGreater(len(set(lines)), 15, "small talk should vary")
        for line in lines:
            self.assertFalse(any(w in line.lower() for w in AI_SLOP), line)

    def test_chat_groups_use_facing_slots(self) -> None:
        seen = False
        for _ in range(7200):
            self.clock += 0.5
            self.director.tick()
            for spot, chat in self.director.chats.items():
                members = chat["members"]
                self.assertTrue(2 <= len(members) <= 3)
                self.assertEqual(len({m.group for m in members}), 1, "chats stay within a group")
                slots = sorted(m.target for m in members)
                self.assertEqual(slots, [f"{spot}_{i + 1}" for i in range(len(members))])
                seen = True
        self.assertTrue(seen, "no chat group formed")

    def test_foosball_two_to_four_players(self) -> None:
        sizes = set()
        for _ in range(14400):
            self.clock += 0.5
            self.director.tick()
            players = [a for a in self.hub.agents.values() if a.activity == "foosball"]
            if players:
                sizes.add(len(players))
                self.assertTrue(all(a.group == h.SHARED_GROUP for a in players), "isolated wings never play foosball")
        self.assertTrue(sizes and sizes <= {1, 2, 3, 4}, sizes)  # 1 = the last one walking back
        self.assertTrue(sizes & {3, 4}, f"only ever 2 players: {sizes}")

    def test_isolated_wing_stays_put(self) -> None:
        """Isolated rooms (if any) keep their agents in-wing; shared agents stay out."""
        self.run_for(7200)
        isolated = [a for a in self.hub.agents.values() if a.group != h.SHARED_GROUP]
        shared = [a for a in self.hub.agents.values() if a.group == h.SHARED_GROUP]
        if not isolated:
            self.skipTest("no isolated wing in current office seed")
        self.assertTrue(shared)
        for a in isolated:
            targets = self.targets_of(a.agent_id)
            self.assertGreater(len(targets), 1, f"{a.agent_id} never left its desk")
            for t in targets:
                self.assertTrue(t == a.desk or t.startswith(a.group + "_"), f"{a.agent_id} wandered to {t}")
        for a in shared:
            for t in self.targets_of(a.agent_id):
                for iso in {x.group for x in isolated}:
                    self.assertFalse(t.startswith(iso + "_"), f"{a.agent_id} went into {iso} wing ({t})")

    def test_ambient_never_overrides_a_real_report(self) -> None:
        self.run_for(300)
        busy = self.hub.agents["android_dev"]
        self.hub.apply_report(busy, "start_task", "Fixing the login crash")
        mark = len(self.events)
        self.run_for(3600)
        later = [e for e in self.events[mark:]
                 if e.get("agent_id") == busy.agent_id or busy.agent_id in e.get("agents", [])]
        self.assertEqual(later, [], "the ambient life touched an agent with a live report")
        self.assertEqual((busy.state, busy.target, busy.text), ("WORKING", busy.desk, "Fixing the login crash"))
        self.assertFalse(any(busy in c["members"] for c in self.director.chats.values()))

    def test_report_pulls_agent_out_of_a_chat(self) -> None:
        for _ in range(7200):
            self.clock += 0.5
            self.director.tick()
            if self.director.chats:
                break
        spot, chat = next(iter(self.director.chats.items()))
        talker = chat["members"][0]
        self.hub.apply_report(talker, "thinking", "Reading the stack trace")
        mark = len(self.events)
        self.run_for(600)
        self.assertFalse([e for e in self.events[mark:] if e.get("agent_id") == talker.agent_id])
        self.assertEqual(talker.state, "THINKING")

    def test_finish_resumes_ambient_life(self) -> None:
        agent = self.hub.agents["android_dev"]
        self.hub.apply_report(agent, "start_task", "Build")
        self.hub.apply_report(agent, "finish", "Shipped")
        self.assertFalse(agent.is_live())
        self.assertEqual(agent.activity, "break")
        self.assertIn(agent.target, agent.break_spots)
        mark = len(self.events)
        self.run_for(3600)
        self.assertTrue([e for e in self.events[mark:] if e.get("agent_id") == agent.agent_id],
                        "after finish the agent should get ambient life again")

    def test_stale_live_report_hands_back(self) -> None:
        agent = self.hub.agents["android_dev"]
        self.hub.live_hold = 0.0  # the hold has already expired
        self.hub.apply_report(agent, "run_tool", "pytest")
        self.run_for(5)
        self.assertEqual(agent.state, "IDLE", "a bot that went quiet is shown idle again")


class MockModeTests(AmbientCase):
    idle_only = False

    def test_mock_still_works_and_chats(self) -> None:
        self.run_for(3600)
        states = {e["state"] for e in self.events if e.get("type") == "STATE_CHANGE"}
        self.assertTrue({"WORKING", "IDLE"} <= states)
        self.assertTrue(any(e.get("type") == "COLLABORATE" for e in self.events))
        self.assertTrue(any("Chat" in (e.get("target") or "") for e in self.events))


if __name__ == "__main__":
    unittest.main()
