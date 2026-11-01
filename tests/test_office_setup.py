"""Per-machine setup: owner name, calendar connector discovery, prompts."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import office_setup  # noqa: E402

M365 = [f"mcp__claude_ai_Microsoft_365__{t}" for t in (
    "outlook_calendar_search", "find_meeting_availability", "outlook_find_available_time",
    "outlook_create_event", "outlook_update_event", "outlook_delete_event", "outlook_respond_to_event",
    "outlook_email_search", "outlook_send_mail", "get_granted_scopes", "sharepoint_search", "search_people")]
GOOGLE = [f"mcp__claude_ai_Google_Calendar__{t}" for t in (
    "list_events", "search_events", "get_event", "list_calendars", "find_free_time",
    "create_event", "update_event", "delete_event", "respond_to_event")]


def test_calendar_tools_are_read_only_calendar_tools():
    assert office_setup.calendar_tools(M365 + ["Read", "WebSearch"]) == sorted(
        f"mcp__claude_ai_Microsoft_365__{t}"
        for t in ("outlook_calendar_search", "find_meeting_availability", "outlook_find_available_time"))
    assert office_setup.calendar_tools(GOOGLE) == sorted(
        f"mcp__claude_ai_Google_Calendar__{t}"
        for t in ("list_events", "search_events", "get_event", "list_calendars", "find_free_time"))
    assert office_setup.calendar_tools(["mcp__claude_ai_Slack__search_messages"]) == []


def test_owner_name_and_prompt():
    assert office_setup.owner_name({"owner": {"name": "Jane"}}) == ("Jane", "office.json")
    assert office_setup.owner_name({"owner": "Jane"}) == ("Jane", "office.json")
    assert "is Jane" in office_setup.owner_prompt("Jane")
    assert office_setup.owner_prompt("") == ""


def test_warnings_for_a_new_user():
    rep = office_setup.SetupReport(owner="", owner_source="not set", claude_found=True,
                                   logged_in=True, auth_method="claude.ai", probed=True,
                                   connectors=[("claude.ai Google Calendar", "needs-auth")], tools=["Read"])
    text = " ".join(rep.warnings())
    assert "No calendar connector" in text and "Google Calendar (needs-auth)" in text
    assert "Owner name not set" in text
    rep2 = office_setup.SetupReport(claude_found=True, logged_in=False)
    assert "not logged in" in rep2.warnings()[0]


def test_agents_use_discovered_calendar_and_owner(tmp_path: Path, monkeypatch):
    import agent_harness as h

    monkeypatch.setattr(h, "DEFAULT_CLAUDE_SESSIONS_DIR", str(tmp_path / "sessions"))
    hub = h.Hub("live")
    hub.owner = "Jane"
    runner = h.CliRunner(hub, {"ea": "claude -p {prompt}"}, systems={"ea": "You are the owner's EA."})
    runner.memory_file = str(tmp_path / "mem" / "owner.md")

    hub.calendar_tools = office_setup.calendar_tools(GOOGLE)
    argv = runner.build_argv("ea", "hi", continue_session=False, project=str(tmp_path))
    allowed = argv[argv.index("--allowedTools") + 1].split(",")
    sys_prompt = argv[argv.index("--append-system-prompt") + 1]
    assert "mcp__claude_ai_Google_Calendar__list_events" in allowed
    assert not any("Microsoft_365" in t or "create_event" in t for t in allowed)
    assert "the owner's EA" in sys_prompt and "\"The owner\" in your instructions is Jane" in sys_prompt
    assert Path(runner.memory_file).read_text().startswith("# What the office knows about Jane")

    hub.calendar_tools = []  # probed: nothing connected
    argv = runner.build_argv("ea", "hi", continue_session=False, project=str(tmp_path))
    assert "No calendar is connected" in argv[argv.index("--append-system-prompt") + 1]
    assert not any(t.startswith("mcp__claude_ai") for t in argv[argv.index("--allowedTools") + 1].split(","))


def test_example_cmds_file_starts_with_default_roster(tmp_path: Path):
    import json

    import agent_harness as h

    office = tmp_path / "office.json"
    office.write_text((ROOT / "office.default.json").read_text())
    cmds = tmp_path / "agent_cmds.json"
    example = json.loads((ROOT / "agent_cmds.example.json").read_text())
    example["retired_bot"] = {"cmd": "claude -p {prompt}"}  # fired agents linger in the file
    cmds.write_text(json.dumps(example))
    args = h.build_parser().parse_args(["--mode", "live", "--office", str(office), "--agent-cmds-file", str(cmds),
                                        "--inbox-file", "none", "--mcp-port", "0"])
    harness = h.Harness(args)
    assert "retired_bot" not in harness.cli.commands
    assert harness.cli.handles("chief_of_staff")


def test_first_run_creates_office_json_from_default(tmp_path: Path, monkeypatch):
    import agent_harness as h

    live, template = tmp_path / "office.json", tmp_path / "office.default.json"
    template.write_text((ROOT / "office.default.json").read_text())
    monkeypatch.setattr(h, "DEFAULT_OFFICE_FILE", str(live))
    monkeypatch.setattr(h, "DEFAULT_OFFICE_TEMPLATE", str(template))
    office = h.load_office(None)
    assert live.read_text() == template.read_text()
    assert {m["agent_id"] for r in office["rooms"] for m in r["members"]} == \
        {"chief_of_staff", "ea", "developer", "finance_bot", "security"}
    live.write_text(live.read_text().replace('"Agentic Corporation HQ"', '"My Office"'))
    assert h.load_office(None)["name"] == "My Office"  # an existing roster is never overwritten
