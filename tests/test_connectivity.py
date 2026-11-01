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


def test_steady_connected_produces_zero_notices():
    """Status polls while Claude stays ok must not flood the notice board."""
    hub = ah.Hub("live")
    mon = ah.ConnectivityMonitor(hub)
    hub.connectivity = mon
    notices: list[dict] = []

    def capture(msg):
        if isinstance(msg, dict) and msg.get("type") == "OFFICE_NOTICE":
            notices.append(msg)

    hub.emit = capture  # type: ignore[method-assign]
    # Boot: first stable ok → banner only.
    mon.claude = "ok"
    mon.reason = "Claude Code reachable"
    mon.broadcast(notice=True)
    assert notices == []
    assert mon._prev_stable == "ok"
    # Simulate the old bug path: checking intermediate, then ok again.
    mon.claude = "checking"
    mon.broadcast(notice=False)
    mon.claude = "ok"
    mon.broadcast(notice=True)
    assert notices == [], notices
    # Repeat steady polls.
    for _ in range(5):
        mon.claude = "checking"
        mon.broadcast(notice=False)
        mon.claude = "ok"
        mon.broadcast(notice=True)
    assert notices == []
    # Real disconnect → one notice.
    mon.claude = "down"
    mon.reason = "unreachable"
    mon.broadcast(notice=True)
    assert len(notices) == 1
    assert notices[0]["kind"] == "claude_down"
    assert notices[0]["title"] == "Claude disconnected"
    # Steady down polls → still one.
    for _ in range(3):
        mon.claude = "checking"
        mon.broadcast(notice=False)
        mon.claude = "down"
        mon.broadcast(notice=True)
    assert len(notices) == 1
    # Recover → exactly one reconnect notice (never "Claude connected").
    mon._last_notice_at = 0.0  # bypass debounce for the test
    mon.claude = "ok"
    mon.reason = "Claude Code reachable again"
    mon.broadcast(notice=True)
    assert len(notices) == 2
    assert notices[1]["kind"] == "claude_recovered"
    assert notices[1]["title"] == "Claude reconnected"
    assert all(n["title"] != "Claude connected" for n in notices)


def test_no_claude_connected_notice_title_emitted():
    hub = ah.Hub("live")
    mon = ah.ConnectivityMonitor(hub)
    notices: list[dict] = []
    hub.emit = lambda msg: notices.append(msg) if isinstance(msg, dict) and msg.get("type") == "OFFICE_NOTICE" else None
    mon._prev_stable = "down"
    mon.claude = "ok"
    mon.broadcast(notice=True)
    assert notices and notices[0]["title"] != "Claude connected"
