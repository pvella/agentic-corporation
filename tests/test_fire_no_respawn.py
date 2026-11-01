"""Fired agents must not keep broadcasting state (Godot respawn / unkillable)."""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import agent_harness as h  # noqa: E402


class FireNoRespawnTests(unittest.TestCase):
    def test_emit_drops_updates_for_fired_agent(self) -> None:
        td = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: shutil.rmtree(td, ignore_errors=True))
        src = Path(ROOT) / "office.json"
        if not src.exists():
            self.skipTest("office.json missing")
        office_path = td / "office.json"
        shutil.copy(src, office_path)
        office = h.load_office(str(office_path))
        hub = h.Hub("mock", "normal", office)
        hub.office_path = str(office_path)
        h.register_office(hub, office)
        aid = "portfolio_and_programme_management"
        if aid not in hub.agents:
            aid = next(iter(hub.agents))
        broadcasts: list[str] = []
        with mock.patch.object(h, "broadcast", lambda clients, payload: broadcasts.append(payload)):
            hub.clients = {"dummy"}
            hub.unregister(aid)
            hub.state(aid, "IDLE", text="after-fire")
            hub.log_line(aid, "chatter", important=True)
            hub.emit({"type": "AMBIENT", "agent_id": aid, "action": "phone"})
            other = next(a for a in hub.agents if a != aid)
            hub.emit({"type": "COLLABORATE", "agents": [aid, other], "text": "sync"})
            hub.state(other, "IDLE", text="still-here")
        parsed = [json.loads(p) for p in broadcasts]
        leaked = [
            e for e in parsed
            if e.get("type") in ("STATE_CHANGE", "LOG_ENTRY", "AMBIENT") and e.get("agent_id") == aid
        ]
        self.assertEqual(leaked, [])
        collab = [e for e in parsed if e.get("type") == "COLLABORATE"]
        self.assertEqual(len(collab), 1)
        self.assertEqual(collab[0].get("agents"), [other])
        self.assertTrue(any(e.get("agent_id") == other and e.get("type") == "STATE_CHANGE" for e in parsed))


if __name__ == "__main__":
    unittest.main()
