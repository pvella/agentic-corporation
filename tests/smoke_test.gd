## Headless integration test: loads Main.tscn, feeds it harness messages
## directly (no network needed) and checks agents spawn, walk to their desk,
## spread across meeting seats and keep logs.
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


func _run() -> void:
	await process_frame
	await physics_frame
	main.handle_message({"type": "SNAPSHOT", "server": {"version": "test", "mode": "mock"}, "agents": [
		{"agent_id": "coder_agent", "name": "Coder", "desk": "Desk_Coder", "color": "#4fc3f7", "state": "IDLE", "target": null, "logs": ["\u001b[32mhello\u001b[0m"]},
		{"agent_id": "qa_agent", "name": "QA", "desk": "Desk_QA", "color": "#81c784", "state": "IDLE", "target": "Water_Cooler", "logs": []},
		{"agent_id": "architect_agent", "name": "Architect", "desk": "Desk_Architect", "color": "#ffb74d", "state": "IDLE", "target": null, "logs": []},
	]})
	_check(main.agents.size() == 3, "snapshot spawned 3 agents")
	var coder: Agent = main.agents["coder_agent"]
	_check(coder.log_lines.size() == 1, "snapshot restored log history")

	main.handle_message({"type": "STATE_CHANGE", "agent_id": "coder_agent", "state": "THINKING", "text": "Analyzing AST..."})
	_check(coder.state == "THINKING" and coder.bubble.visible, "THINKING sets state and shows a bubble")
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "coder_agent", "state": "WORKING", "target": "Desk_Coder", "text": "Editing main.py"})
	main.handle_message({"type": "LOG_ENTRY", "agent_id": "coder_agent", "log": "Running tests: 12 passed, 0 failed."})
	_check(coder.log_lines.size() == 2, "LOG_ENTRY appended to the agent buffer")
	main.handle_message({"type": "COLLABORATE", "agents": ["qa_agent", "architect_agent"], "target": "Meeting_Room"})
	main.handle_message({"type": "STATE_CHANGE", "agent_id": "new_agent", "state": "IDLE", "target": "Coffee_Machine"})
	_check(main.agents.has("new_agent"), "unknown agent_id spawns on the fly")

	await _wait(12.0)
	var desk: Vector2 = main.waypoints["Desk_Coder"].global_position
	_check(coder.global_position.distance_to(desk) < 20.0, "coder walked to Desk_Coder (dist %.1f)" % coder.global_position.distance_to(desk))
	_check(coder.is_at_destination(), "coder navigation finished")
	var qa: Agent = main.agents["qa_agent"]
	var arch: Agent = main.agents["architect_agent"]
	_check(qa.state == "COLLAB" and arch.state == "COLLAB", "COLLABORATE sets COLLAB state")
	_check(qa.current_waypoint.begins_with("Meeting_Table") and arch.current_waypoint.begins_with("Meeting_Table")
		and qa.current_waypoint != arch.current_waypoint, "collaborators got different meeting seats (%s, %s)" % [qa.current_waypoint, arch.current_waypoint])
	var seat: Vector2 = main.waypoints[qa.current_waypoint].global_position
	_check(qa.global_position.distance_to(seat) < 24.0, "qa reached its seat (dist %.1f)" % qa.global_position.distance_to(seat))

	# Drawer opens for a clicked agent and renders its buffer.
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

	# Snapshot that drops an agent removes it.
	main.handle_message({"type": "SNAPSHOT", "agents": [{"agent_id": "coder_agent", "name": "Coder", "state": "IDLE", "logs": []}]})
	await process_frame
	_check(main.agents.size() == 1, "re-snapshot prunes removed agents")

	print("smoke test: %s" % ("PASS" if failures.is_empty() else "FAIL (%d)" % failures.size()))
	quit(0 if failures.is_empty() else 1)
