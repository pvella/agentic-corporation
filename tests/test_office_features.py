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
    main = (ROOT / "Main.gd").read_text(encoding="utf-8")
    assert "_cycle_needs_you" in main
    assert "NEEDS_YOU" in main
    assert "_play_needs_chime" in main
    agent = (ROOT / "Agent.gd").read_text(encoding="utf-8")
    assert "Red desk beacon" in agent


def test_hire_gets_free_desk_in_own_room():
    """New hires get a desk the client draws in their room (Office._free_desk_names),
    not a desk name from another room that the client can't find (→ break spot)."""
    import agent_harness as h

    office = h.load_office(str(ROOT / "tests" / "fixtures" / "office_roster.json"))
    hub = h.Hub("mock", "calm", office)
    h.register_office(hub, office)
    eng = next(r for r in office["rooms"] if r["id"] == "engineering")
    free = max(int(eng.get("desks", 0)), len(eng["members"])) - len(eng["members"])
    picks = []
    for i in range(free):
        d = hub._free_desk("engineering")
        assert d == f"Desk_engineering_free_{i + 1}"
        picks.append(d)
        hub.register(f"hire_{i}", f"Hire {i}", d, "#4fc3f7", role="Dev", room="engineering")
    assert hub._free_desk("engineering") == ""  # room full: caller falls back to Desk_<agent_id>
    assert hub._free_desk("special_projects") == "Desk_special_projects_free_1"


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-q"]))


def test_claude_agents_get_web_tools_and_shared_memory(tmp_path: Path):
    from agent_harness import CliRunner, Hub

    hub = Hub("live")
    runner = CliRunner(hub, {"cos": "claude -p {prompt}"}, systems={"cos": "You are CoS."})
    runner.memory_file = str(tmp_path / "mem" / "owner.md")
    argv = runner.build_argv("cos", "hi", continue_session=False, project=str(tmp_path))
    allowed = argv[argv.index("--allowedTools") + 1].split(",")
    assert "WebSearch" in allowed and "WebFetch" in allowed
    assert f"Edit(/{runner.memory_file})" in allowed
    assert str(tmp_path / "mem") in argv  # --add-dir for the memory folder
    sys_prompt = argv[argv.index("--append-system-prompt") + 1]
    assert "(nothing yet)" in sys_prompt

    Path(runner.memory_file).write_text("# What the office knows about Jane\n\n- Based in Springfield\n")
    argv = runner.build_argv("cos", "hi", continue_session=False, project=str(tmp_path))
    assert "Springfield" in argv[argv.index("--append-system-prompt") + 1]


def test_server_room_panel_reads_and_saves_office_memory(tmp_path: Path):
    import asyncio
    from agent_harness import Hub

    class FakeWS:
        def __init__(self) -> None:
            self.sent: list[dict] = []

        async def send(self, raw: str) -> None:
            self.sent.append(json.loads(raw))

    hub = Hub("mock")
    hub.memory_file = str(tmp_path / "mem" / "owner.md")
    ws = FakeWS()
    asyncio.run(hub.on_message(ws, json.dumps({"action": "LIST_KNOWLEDGE"})))
    listing = [m for m in ws.sent if m.get("type") == "KNOWLEDGE_LIST"][-1]
    assert listing["memory"].startswith("# What the office knows")

    text = "# What the office knows about Jane\n\n- Based in Springfield\n- Prefers short briefs"
    asyncio.run(hub.on_message(ws, json.dumps({"action": "SET_MEMORY", "text": text})))
    assert Path(hub.memory_file).read_text() == text + "\n"
    assert any(m.get("action") == "SET_MEMORY" and m.get("type") == "ACK" for m in ws.sent)


def test_sessions_restart_when_tool_permissions_change(tmp_path: Path, monkeypatch):
    import agent_harness as h

    sessions = tmp_path / "sessions.json"
    monkeypatch.setattr(h, "DEFAULT_CLAUDE_SESSIONS_FILE", str(sessions))
    sessions.write_text(json.dumps(["chief_of_staff"]))  # legacy list, old permissions
    runner = h.CliRunner(h.Hub("live"), {"chief_of_staff": "claude -p {prompt}"})
    assert runner.started == set()
    runner.started.add("chief_of_staff")
    runner._save_started()
    again = h.CliRunner(h.Hub("live"), {"chief_of_staff": "claude -p {prompt}"})
    assert again.started == {"chief_of_staff"}
    sessions.write_text(json.dumps({"chief_of_staff": "old-signature"}))
    assert h.CliRunner(h.Hub("live"), {}).started == set()


def test_colleague_messages_and_calendar_tools(tmp_path: Path, monkeypatch):
    import asyncio
    import agent_harness as h

    monkeypatch.setattr(h, "DEFAULT_CLAUDE_SESSIONS_DIR", str(tmp_path / "sessions"))
    hub = h.Hub("live")
    cos = hub.register("chief_of_staff", "Chief of Staff", "Desk_CoS", "#4fc3f7", role="Chief of Staff")
    ea = hub.register("ea", "EA", "Desk_EA", "#ffb74d", role="Executive Assistant")
    dev = hub.register("developer", "Developer", "Desk_Dev", "#81c784", role="Developer")

    # CLI-bound colleague: the request lands on their run queue, tagged with the sender.
    note = hub.message_colleague(cos, ea, "Check the owner's calendar for 1-7 Nov")
    assert "EA" in note
    queued = ea.queue.get_nowait()
    assert queued.startswith("[Message from Chief of Staff (chief_of_staff)] Check the owner's calendar")
    for _ in range(h.COLLEAGUE_MAX_PER_PAIR - 1):
        hub.message_colleague(ea, cos, "answer")
    try:
        hub.message_colleague(cos, ea, "again")
        raise AssertionError("ping-pong should be capped")
    except ValueError:
        pass

    hub.office_mcp = ("http://127.0.0.1:8766/mcp", "secret-token")
    runner = h.CliRunner(hub, {"ea": "claude -p {prompt}", "developer": "claude -p {prompt}"})
    runner.memory_file = str(tmp_path / "mem" / "owner.md")
    ea_argv = runner.build_argv("ea", "hi", continue_session=False, project=str(tmp_path))
    dev_argv = runner.build_argv("developer", "hi", continue_session=False, project=str(tmp_path))
    ea_allowed = ea_argv[ea_argv.index("--allowedTools") + 1].split(",")
    dev_allowed = dev_argv[dev_argv.index("--allowedTools") + 1].split(",")
    assert "mcp__office__message_colleague" in ea_allowed and "mcp__office__message_colleague" in dev_allowed
    for need in ("mcp__office__check_office_inbox", "mcp__office__list_agents",
                 "mcp__office__report_office_status", "mcp__office__reply_office_message"):
        assert need in ea_allowed and need in dev_allowed
    assert "mcp__office__hire_agent" not in ea_allowed  # not blanket MCP / admin
    assert h.M365 + "outlook_calendar_search" in ea_allowed
    assert not any(t.startswith(h.M365) for t in dev_allowed)
    assert not any("send" in t or "delete" in t for t in ea_allowed)
    cfg = Path(ea_argv[ea_argv.index("--mcp-config") + 1])
    assert json.loads(cfg.read_text())["mcpServers"]["office"]["headers"]["Authorization"] == "Bearer secret-token"
    if os.name != "nt":
        assert oct(cfg.stat().st_mode & 0o777) == "0o600"
    assert "secret-token" not in " ".join(ea_argv)
