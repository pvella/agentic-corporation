## Headless integration test: loads Main.tscn and feeds it harness messages
## directly (no network needed).
##   Part 1: the legacy 3-agent office (no OFFICE_LAYOUT).
##   Part 2: the team-room office from tests/fixtures/office_layout.json
##           (regenerate with: python3 -c "import json,agent_harness as h; ...", see README).
##   godot --headless --path . --script res://tests/smoke_test.gd
extends SceneTree

var main: Node
var failures: PackedStringArray = []


func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	main.server_url = "ws://127.0.0.1:9"  # nothing listening; offline mode is fine
	root.add_child(main)
	_run.call_deferred()


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		failures.append(what)


func _dist(a: Agent, wp: String) -> float:
	return a.global_position.distance_to(main.waypoints[wp].global_position)


func _run() -> void:
	await process_frame
	await physics_frame
	await _legacy()
	await _office()
	print("smoke test: %s" % ("PASS" if failures.is_empty() else "FAIL (%d)" % failures.size()))
	quit(0 if failures.is_empty() else 1)


func _legacy() -> void:
	print("legacy office")
	_check(main.using_legacy_layout and main.waypoints.has("Desk_Coder") and main.waypoints.has("Meeting_Table_4"), "legacy layout built at startup")
	main.handle_message({"type": "SNAPSHOT", "server": {"version": "test", "mode": "mock"}, "agents": [
		{"agent_id": "coder_agent", "name": "Coder", "desk": "Desk_Coder", "color": "#4fc3f7", "state": "IDLE", "target": null, "logs": ["\u001b[32mhello\u001b[0m"]},
		{"agent_id": "qa_agent", "name": "QA", "desk": "Desk_QA", "color": "#81c784", "state": "IDLE", "target": "Water_Cooler", "logs": []},
		{"agent_id": "architect_agent", "name": "Architect", "desk": "Desk_Architect", "color": "#ffb74d", "state": "WORKING", "target": "Desk_Architect", "logs": []},
	]})
	_check(main.agents.size() == 3, "snapshot spawned 3 agents")
	var coder: Agent = main.agents["coder_agent"]
	var qa: Agent = main.agents["qa_agent"]
	var arch: Agent = main.agents["architect_agent"]
	_check(coder.log_lines.size() == 1, "snapshot restored log history")
	_check(_dist(qa, "Water_Cooler") < 2.0, "snapshot places agents straight at their spot (no stampede)")
	_check(coder.move_speed <= 100.0, "relaxed walking speed (%.0f px/s, was 140)" % coder.move_speed)

	main.handle_message({"type": "STATE_CHANGE", "agent_id": "coder_agent", "state": "THINKING", "text": "Analyzing AST..."})
	_check(coder.state == "THINKING" and coder.bubble.visible, "THINKING sets state and shows a bubble")
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "coder_agent", "state": "WORKING", "target": "Desk_Coder", "text": "Editing main.py"})
	main.handle_message({"type": "LOG_ENTRY", "agent_id": "coder_agent", "log": "Running tests: 12 passed, 0 failed."})
	_check(coder.log_lines.size() == 2, "LOG_ENTRY appended to the agent buffer")
	main.handle_message({"type": "COLLABORATE", "agents": ["qa_agent", "architect_agent"], "target": "Meeting_Room"})
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "new_agent", "state": "IDLE", "target": "Coffee_Machine"})
	_check(main.agents.has("new_agent"), "unknown agent_id spawns on the fly")

	await _wait(16.0)
	_check(_dist(coder, "Desk_Coder") < 4.0, "coder walked to Desk_Coder (dist %.1f)" % _dist(coder, "Desk_Coder"))
	_check(coder.is_seated_at_desk(), "coder is seated at the desk facing the monitor")
	_check(qa.state == "COLLAB" and arch.state == "COLLAB", "COLLABORATE sets COLLAB state")
	_check(qa.current_waypoint.begins_with("Meeting_Table") and arch.current_waypoint.begins_with("Meeting_Table")
		and qa.current_waypoint != arch.current_waypoint, "collaborators got different meeting seats (%s, %s)" % [qa.current_waypoint, arch.current_waypoint])
	_check(_dist(qa, qa.current_waypoint) < 4.0, "qa reached its seat (dist %.1f)" % _dist(qa, qa.current_waypoint))

	# Re-sending the spot an agent already holds must not re-path it.
	var before: Vector2 = coder.global_position
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "coder_agent", "state": "WORKING", "target": "Desk_Coder"})
	await _wait(0.5)
	_check(coder.global_position.distance_to(before) < 0.5 and coder.is_seated_at_desk(), "same target again: no re-pathing or jitter")

	main._on_agent_clicked(coder)
	await _wait(0.5)
	var drawer = main.drawer
	_check(drawer.is_open() and drawer.agent == coder, "terminal drawer opened for coder")
	_check(drawer.log_view.get_parsed_text().contains("Running tests: 12 passed"), "drawer shows the log buffer")
	main.handle_message({"type": "LOG_ENTRY", "agent_id": "coder_agent", "log": "\u001b[31mlive line\u001b[0m"})
	_check(drawer.log_view.get_parsed_text().contains("live line"), "drawer updates live")
	drawer.close()
	await _wait(0.5)
	_check(not drawer.panel.visible, "drawer slides closed")

	main.handle_message({"type": "SNAPSHOT", "agents": [{"agent_id": "coder_agent", "name": "Coder", "state": "IDLE", "logs": []}]})
	await process_frame
	_check(main.agents.size() == 1, "re-snapshot prunes removed agents")


func _office() -> void:
	print("team-room office")
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/office_layout.json"))
	main.handle_message(layout)
	await physics_frame
	await physics_frame
	_check(not main.using_legacy_layout and main.agents.is_empty(), "OFFICE_LAYOUT rebuilds the office and clears old agents")
	_check(main.office.rooms.size() == 4, "4 team rooms built")
	for wp in ["Desk_ios_dev", "Desk_ptc_odoo", "Coffee_Machine", "Sofa_2", "Foosball_1", "Foosball_4", "Meeting_Table_6", "ptc_Coffee", "ptc_Meeting_4", "ptc_Entrance", "Entrance"]:
		_check(main.waypoints.has(wp), "waypoint %s exists" % wp)

	var agents: Array = []
	for r: Dictionary in layout.office.rooms:
		for m: Dictionary in r.members:
			var d := m.duplicate()
			d.room = r.id
			d.state = "WORKING"
			d.target = m.desk
			d.logs = []
			agents.append(d)
	for d: Dictionary in agents:
		if d.agent_id == "ios_dev":
			d.state = "IDLE"
			d.target = "Sofa_1"
		elif d.agent_id == "ptc_odoo":
			d.state = "IDLE"
			d.target = "ptc_Coffee"
			d.unread = 3
	main.handle_message({"type": "SNAPSHOT", "server": {"mode": "mock", "tempo": "calm", "office": layout.office.name}, "agents": agents})
	await _wait(1.0)
	_check(main.agents.size() == 23, "23 agents spawned (%d)" % main.agents.size())
	var android: Agent = main.agents["android_dev"]
	var ios: Agent = main.agents["ios_dev"]
	_check(android.is_seated_at_desk() and _dist(android, "Desk_android_dev") < 2.0, "agents start seated at their own desks")
	_check(main._desk_props["android_dev"].owner_agent == android, "desk monitor is linked to its owner")
	_check(ios.is_away_from_desk() and _dist(ios, "Sofa_1") < 2.0, "ios_dev starts on the break-room sofa")
	_check(main.agents["ptc_odoo"].unread == 3, "snapshot restores the unread badge")

	main.handle_message({"type": "LOG_ENTRY", "agent_id": "ios_dev", "log": "[notify] build finished"})
	_check(ios.is_phone_out(), "LOG_ENTRY while away: agent pulls out the phone")
	main.handle_message({"type": "LOG_ENTRY", "agent_id": "android_dev", "log": "gradle assembleRelease"})
	_check(not android.is_phone_out(), "LOG_ENTRY at the desk: no phone")

	# Foosball: two idle agents play, the table animates.
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "finance_bot", "state": "IDLE", "target": "Foosball_1", "text": "Foosball?"})
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "ea", "state": "IDLE", "target": "Foosball_2", "text": "You're on!"})
	# PTC meeting stays inside the wing.
	main.handle_message({"type": "COLLABORATE", "agents": ["ptc_powerbrain", "ptc_chief_of_staff"], "target": "ptc_Meeting_Room"})
	await _wait(18.0)
	var fb: Agent = main.agents["finance_bot"]
	var ea: Agent = main.agents["ea"]
	_check(_dist(fb, "Foosball_1") < 4.0 and _dist(ea, "Foosball_2") < 4.0, "foosball players reached the table (%.1f, %.1f)" % [_dist(fb, "Foosball_1"), _dist(ea, "Foosball_2")])
	_check(main._foosball_props.size() == 1 and main._foosball_props[0].playing, "foosball table animates while two play")
	var pb: Agent = main.agents["ptc_powerbrain"]
	_check(pb.current_waypoint.begins_with("ptc_Meeting_") and _dist(pb, pb.current_waypoint) < 4.0, "PTC meeting uses the wing's own table (%s)" % pb.current_waypoint)

	# Hard wall: no navigation path from the PTC wing into the main building.
	var map: RID = main.nav_region.get_navigation_map()
	var from: Vector2 = main.waypoints["Desk_ptc_odoo"].global_position
	var to: Vector2 = main.waypoints["Coffee_Machine"].global_position
	var path := NavigationServer2D.map_get_path(map, from, to, true)
	var end_gap := to.distance_to(path[path.size() - 1]) if path.size() > 0 else INF
	_check(end_gap > 100.0, "PTC wing has no walkable route to the shared break room (gap %.0f px)" % end_gap)
	var to2: Vector2 = main.waypoints["ptc_Coffee"].global_position
	var path2 := NavigationServer2D.map_get_path(map, from, to2, true)
	_check(path2.size() > 0 and to2.distance_to(path2[path2.size() - 1]) < 4.0, "PTC desks reach the wing's own kitchenette")

	# An update while away and without a target: phone glance.
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "ea", "state": "THINKING", "text": "hmm"})
	_check(ea.is_phone_out(), "THINKING update while away: phone glance")

	# A real bot reports a failure (MCP report -> ERROR at the desk).
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "android_dev", "state": "ERROR", "target": "Desk_android_dev", "text": "Gradle build failed"})
	await _wait(0.3)
	_check(android.state == "ERROR" and android.is_seated_at_desk() and android.bubble.visible, "ERROR state: stays at the desk with a bubble")
	_check(main.counts_label.text.contains("1 error"), "HUD counts the error (%s)" % main.counts_label.text)
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "android_dev", "state": "WORKING", "text": "retrying"})
	_check(android.state == "WORKING", "ERROR clears on the next report")

	# Inbox for real bots: envelope badge, ACK text, delivery, plain-text replies.
	main.handle_message({"type": "INBOX", "agent_id": "ea", "unread": 2})
	_check(ea.unread == 2, "INBOX event sets the envelope badge count")
	main._on_agent_clicked(ea)
	await _wait(0.3)
	main.handle_message({"type": "ACK", "action": "DISPATCH_PROMPT", "agent_id": "ea", "inbox": true, "unread": 2, "queued": 0})
	_check(main.drawer.log_view.get_parsed_text().contains("in EA's inbox (2 unread)"), "inbox ACK shown in the terminal")
	main.handle_message({"type": "LOG_ENTRY", "agent_id": "ea", "log": "\u001b[1;32mEA>\u001b[0m [b]not bold[/b] [url=x]y[/url] [color=red]z"})
	var shown: String = main.drawer.log_view.get_parsed_text()
	_check(shown.contains("EA> [b]not bold[/b] [url=x]y[/url] [color=red]z"), "bot replies render as plain text (no BBCode injection)")
	main.handle_message({"type": "INBOX", "agent_id": "ea", "unread": 0})
	_check(ea.unread == 0, "delivery clears the badge")
	main.drawer.close()
	await _wait(0.3)

	# Team summary from a room sign.
	main.open_team("dev_team")
	await _wait(0.5)
	_check(main.drawer.is_team_open(), "room sign opens the team summary")
	var text: String = main.drawer.log_view.get_parsed_text()
	_check(text.contains("iOS Dev") and text.contains("Product Manager"), "team summary lists members")
	_check(not main.drawer.footer.visible, "team summary hides the prompt box")
	main.drawer.agent_requested.emit("ios_dev")
	await _wait(0.3)
	_check(main.drawer.agent == ios and main.drawer.footer.visible, "clicking a member opens their terminal")
	main.drawer.close()

	# Harness restarted without office.json: back to the legacy layout.
	main.handle_message({"type": "SNAPSHOT", "server": {"mode": "mock", "office": null}, "agents": [
		{"agent_id": "coder_agent", "name": "Coder", "desk": "Desk_Coder", "state": "WORKING", "target": "Desk_Coder", "logs": []}]})
	await process_frame
	_check(main.using_legacy_layout and main.agents.size() == 1, "snapshot without an office falls back to the legacy layout")
