## Headless integration test: loads Main.tscn and feeds it harness messages
## directly (no network needed).
##   Part 1: the legacy 3-agent office (no OFFICE_LAYOUT).
##   Part 2: the team-room office from tests/fixtures/office_layout.json
##           (regenerate with: python3 -c "import json,agent_harness as h; ...", see README).
##   godot --headless --path . --script res://tests/smoke_test.gd
extends SceneTree

const Iso := preload("res://Iso.gd")

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
	main.set_view_mode(true, false)  # explicit: don't depend on a saved preference
	_check(Iso.enabled, "isometric view is active")
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
	for i in 20:  # the sit-down animation finishes just after arrival
		if coder.is_seated_at_desk():
			break
		await _wait(0.1)
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
	# Ambient-life spots: chat triples face each other; the wing has its own.
	for wp in ["Vending_Machine", "Chat_Break_1", "Chat_Corridor_3", "Chat_dev_team_2", "ptc_Sofa_1", "ptc_Sofa_2", "ptc_Chat_1", "ptc_Chat_3"]:
		_check(main.waypoints.has(wp), "waypoint %s exists" % wp)
	for spot in ["Chat_Break", "Chat_Corridor", "Chat_dev_team", "ptc_Chat"]:
		var w: Marker2D = main.waypoints[spot + "_1"]
		var e: Marker2D = main.waypoints[spot + "_2"]
		var n: Marker2D = main.waypoints[spot + "_3"]
		var ok := w.global_position.x < e.global_position.x and n.global_position.y < w.global_position.y
		ok = ok and w.get_meta("facing") == "right" and e.get_meta("facing") == "left" and n.get_meta("facing") == "down"
		_check(ok, "%s: the three chat slots face each other" % spot)
		var p1 := NavigationServer2D.map_get_path(map, w.global_position, e.global_position, true)
		_check(p1.size() > 0 and e.global_position.distance_to(p1[p1.size() - 1]) < 4.0, "%s slots are on walkable floor" % spot)
	var wing_rect := Rect2()
	for a: Dictionary in main.office.areas:
		if str(a.get("kind", "")) == "wing":
			wing_rect = a.rect
	for spot in ["ptc_Chat_1", "ptc_Chat_2", "ptc_Chat_3", "ptc_Sofa_1", "ptc_Sofa_2", "ptc_Coffee", "ptc_Water"]:
		var pos: Vector2 = main.waypoints[spot].global_position
		var inside := wing_rect.has_point(pos)
		var p3 := NavigationServer2D.map_get_path(map, from, pos, true)
		# Seats sit just inside the furniture: agents settle the last few px.
		var reach := p3.size() > 0 and pos.distance_to(p3[p3.size() - 1]) < 40.0
		var p4 := NavigationServer2D.map_get_path(map, main.waypoints["Coffee_Machine"].global_position, pos, true)
		var leak := p4.size() > 0 and pos.distance_to(p4[p4.size() - 1]) < 100.0
		_check(inside and reach and not leak, "%s is inside the PTC wing, reachable from its desks only" % spot)

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
	await _views(android)

	# Harness restarted without office.json: back to the legacy layout.
	main.handle_message({"type": "SNAPSHOT", "server": {"mode": "mock", "office": null}, "agents": [
		{"agent_id": "coder_agent", "name": "Coder", "desk": "Desk_Coder", "state": "WORKING", "target": "Desk_Coder", "logs": []}]})
	await process_frame
	_check(main.using_legacy_layout and main.agents.size() == 1, "snapshot without an office falls back to the legacy layout")


## Isometric projection, picking in screen space, and the top-down toggle.
func _views(android: Agent) -> void:
	print("views")
	var worst := 0.0
	for p: Vector2 in [Vector2.ZERO, Vector2(123.5, -40), Vector2(1600, 900), Vector2(-77, 2048)]:
		worst = maxf(worst, Iso.to_world(Iso.to_screen(p)).distance_to(p))
	_check(worst < 0.01, "iso projection round-trips world -> screen -> world (err %.4f)" % worst)
	_check(Iso.to_screen(Vector2(10, 0)).y > 0 and Iso.to_screen(Vector2(10, 0)).x > 0 and Iso.to_screen(Vector2(0, 10)).x < 0, "iso axes: +x down-right, +y down-left")
	await process_frame
	_check(android.view.position.distance_to(Iso.to_screen(android.global_position)) < 1.0, "agent sprite sits at the projected body position")
	_check(not main.bodies_root.visible and android.get_parent() == main.bodies_root and android.view.get_parent() == main.agents_root, "bodies in the hidden world layer, views in the y-sorted layer")
	var walls: int = main.props_root.get_children().filter(func(n: Node) -> bool: return n.kind == "wall").size()
	_check(walls > 50, "iso walls are y-sorted slices (%d)" % walls)
	# Depth: a person south of a desk (sitting at it) is drawn after the desk.
	var desk: Node2D = main._desk_props["android_dev"]
	_check(android.view.position.y > desk.position.y, "seated agent sorts in front of its desk")

	# Click picking in screen space: a click on the drawn person / room sign.
	await physics_frame
	var space: PhysicsDirectSpaceState2D = main.get_world_2d().direct_space_state
	var q := PhysicsPointQueryParameters2D.new()
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = 4
	q.position = android.view.global_position + Vector2(0, -30)
	var hits: Array = space.intersect_point(q, 32).map(func(h: Dictionary) -> Object: return h.collider)
	_check(hits.has(android.click_area), "point query at the drawn person hits its click area")
	q.position = android.global_position + Vector2(0, -30)
	var stale: Array = space.intersect_point(q, 32).map(func(h: Dictionary) -> Object: return h.collider)
	_check(not stale.has(android.click_area), "...and not at the unprojected world position")
	await _click(android.view.global_position + Vector2(0, -30))
	_check(main.drawer.is_open() and main.drawer.agent == android, "mouse click on the iso sprite opens the terminal")
	main.drawer.close()
	await _wait(0.3)
	var tag: Node2D = null
	for t: Node2D in main._sign_tags:
		if t.info.get("room_id", "") == "dev_team":
			tag = t
	_check(tag != null, "iso room sign exists for dev_team")
	if tag:
		q.collision_mask = 8
		q.position = tag.to_global(tag.box.get_center())
		_check(space.intersect_point(q, 8).size() > 0, "point query at the iso room sign hits its area")
		await _click(tag.to_global(tag.box.get_center()))
		_check(main.drawer.is_team_open(), "mouse click on the iso room sign opens the team summary")
		main.drawer.close()
		await _wait(0.3)

	# Toggle to the classic view and back.
	main.set_view_mode(false, false)
	await process_frame
	_check(not Iso.enabled and android.view.position.distance_to(android.global_position * Iso.SCALE) < 1.0, "top-down view: sprite at the (scaled) body position")
	_check(main.props_root.get_child_count() == main.office.props.size(), "top-down view: one prop per piece of furniture, no wall slices")
	_check(main._camera_bounds().size.is_equal_approx(main.office.bounds.size * Iso.SCALE), "top-down view: camera bounds cover the scaled office")
	_check(main._desk_props["android_dev"].owner_agent == android, "desk monitor stays linked across the toggle")
	await physics_frame
	q.collision_mask = 4
	q.position = android.view.to_global(Vector2(0, -30))
	_check(space.intersect_point(q, 32).map(func(h: Dictionary) -> Object: return h.collider).has(android.click_area), "top-down picking at the world position")
	# The V key toggles back (and would save the preference: restore it after).
	var cfg := ConfigFile.new()
	var had_cfg := cfg.load(main.SETTINGS_PATH) == OK
	var key := InputEventKey.new()
	key.keycode = KEY_V
	key.pressed = true
	root.push_input(key)
	await process_frame
	_check(Iso.enabled, "V key switches back to the iso view")
	if had_cfg:
		cfg.save(main.SETTINGS_PATH)
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(main.SETTINGS_PATH))
	main.set_view_mode(true, false)
	await process_frame
	_check(Iso.enabled and android.view.position.distance_to(Iso.to_screen(android.global_position)) < 1.0, "back to iso")


## Simulates a left click at a canvas (world-layer) position.
func _click(canvas_pos: Vector2) -> void:
	var screen := root.get_canvas_transform() * canvas_pos
	for pressed: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = screen
		ev.global_position = screen
		root.push_input(ev, true)  # viewport-local coordinates
		await physics_frame
		await process_frame
