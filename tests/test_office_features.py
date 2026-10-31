"""Checkpoint tests for NEEDS_YOU / lite / worktrees / Cos MCP (2D office port)."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def test_lite_state_and_needs():
    from agent_harness import Hub
    import office_lite

    hub = Hub("mock")
    hub.register("chief_of_staff", "Chief of Staff", "Desk_CoS", "#4fc3f7", role="Chief of Staff")
    hub.register("android_dev", "Android Dev", "Desk_A", "#ffb74d", role="Android Engineer")
    lite = office_lite.LiteServer(hub)
    lite.mark_needs("android_dev", True)
    st = lite.state()
    assert st["needs_count"] == 1
    assert st["agents"][0]["agent_id"] == "android_dev"  # needs-you first
    assert st["agents"][0]["needs_you"] is True


def test_worktree_cleanup_refuses_dirty(tmp_path: Path):
    import agent_worktrees

    repo = tmp_path / "repo"
    repo.mkdir()
    os.system(f"git -C {repo} init -q && git -C {repo} config user.email t@t && git -C {repo} config user.name t")
    (repo / "a.txt").write_text("x")
    os.system(f"git -C {repo} add a.txt && git -C {repo} commit -qm init")
    mgr = agent_worktrees.WorktreeManager(str(repo))
    path = mgr.ensure("bot1")
    (path / "dirty.txt").write_text("nope")
    note = mgr.safe_cleanup("bot1")
    assert "refused" in note
    assert path.is_dir()


def test_mcp_has_agent_tools():
    import office_mcp
    from agent_harness import Hub

    hub = Hub("mock")
    hub.register("chief_of_staff", "Chief of Staff", "Desk_CoS", "#4fc3f7", role="Chief of Staff")
    office_mcp.build_mcp(hub)
    src = Path(office_mcp.__file__).read_text()
    for name in ("list_agents", "hire_agent", "message_agent", "send_home"):
        assert f'name="{name}"' in src


def test_agent_to_json_needs_you_fields():
    from agent_harness import Hub

    hub = Hub("mock")
    a = hub.register("coder_agent", "Coder", "Desk_Coder", "#4fc3f7", role="Implementation")
    a.awaiting_input = True
    data = a.to_json(include_logs=False)
    assert data["awaiting_input"] is True
    assert data["needs_you"] is True


def test_parser_has_lite_and_worktrees():
    from agent_harness import build_parser

    p = build_parser()
    args = p.parse_args(["--lite-port", "8787", "--worktrees", "--stream-json"])
    assert args.lite_port == 8787
    assert args.worktrees is True
    assert args.stream_json is True


def test_credits_mentions_agentsystemlabs():
    text = (ROOT / "CREDITS.md").read_text()
    assert "AgentSystemLabs" in text
    assert "agent-office" in text


def test_main_gd_has_needs_you_ui():
    main = (ROOT / "Main.gd").read_text()
    assert "_cycle_needs_you" in main
    assert "NEEDS_YOU" in main
    assert "_play_needs_chime" in main
    agent = (ROOT / "Agent.gd").read_text()
    assert "Red desk beacon" in agent


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-q"]))
