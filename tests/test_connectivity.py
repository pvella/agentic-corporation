"""Connectivity monitor helpers."""
from __future__ import annotations

import agent_harness as ah


def test_auth_failure_markers():
    assert ah.looks_like_claude_auth_failure("Error: Not logged in. Please run /login")
    assert ah.looks_like_claude_auth_failure("authentication_error: invalid api key")
    assert not ah.looks_like_claude_auth_failure("PONG")
    assert not ah.looks_like_claude_auth_failure("")


def test_monitor_payload_and_blurb():
    hub = ah.Hub("live")
    mon = ah.ConnectivityMonitor(hub)
    hub.connectivity = mon
    assert mon.payload()["claude"] == "checking"
    mon.claude = "down"
    mon.reason = "Not logged in — click indicator to run claude /login"
    blurb = mon.blurb_for_prompt()
    assert "UNAVAILABLE" in blurb
    assert "click the connectivity indicator" in blurb
    mon.note_success()
    assert mon.claude == "ok"
    assert "connected" in mon.blurb_for_prompt().casefold()


def test_note_failure_detects_missing_binary():
    hub = ah.Hub("live")
    mon = ah.ConnectivityMonitor(hub)
    hub.connectivity = mon
    # suppress broadcast side effects by emptying clients
    mon.note_failure("No such file or directory: 'claude'")
    assert mon.claude == "down"
    assert "not found" in mon.reason.casefold()
