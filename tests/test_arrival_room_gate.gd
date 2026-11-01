## Permanent runtime gate: amenity chatter + seats only when area_kind_at matches.
## Stuck / partial arrivals in a team room must NOT yoga/coffee-chatter or pose.
##   godot --headless --path . --script res://tests/test_arrival_room_gate.gd
extends SceneTree

var main: Node
var failures: PackedStringArray = []


func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	main.server_url = "ws://127.0.0.1:9"
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
	main.set_view_mode(true, false)
	var layout: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://tests/fixtures/office_layout.json"))
	main.handle_message(layout)
	await physics_frame
	await physics_frame

	# Amenity markers must sit inside hub amenity polygons (not team rooms).
	var amenity_expect := {
		"Coffee_Machine": "break", "Water_Cooler": "break", "Vending_Machine": "break",
		"Sofa_1": "break", "Sofa_2": "break",
		"Foosball_1": "break", "Foosball_2": "break",
		"Canteen_Counter": "canteen", "Canteen_Seat_1": "canteen",
		"Yoga_Mat_1": "rec", "Yoga_Mat_2": "rec",
		"Meditation_Cushion_1": "rec", "Meditation_Cushion_2": "rec",
	}
	for wp_name in amenity_expect.keys():
		_check(main.waypoints.has(wp_name), "amenity wp %s exists" % wp_name)
		if not main.waypoints.has(wp_name):
			continue
		var pos: Vector2 = (main.waypoints[wp_name] as Node2D).global_position
		var got: String = main._area_kind_at(pos)
		_check(got == amenity_expect[wp_name],
			"amenity %s at %s has kind=%s (want %s)" % [wp_name, pos, got, amenity_expect[wp_name]])

	# Spawn one agent at their Engineering desk.
	main.handle_message({
		"type": "SNAPSHOT",
		"server": {"mode": "mock", "tempo": "calm"},
		"agents": [{
			"agent_id": "android_dev",
			"name": "Android",
			"desk": "Desk_android_dev",
			"room": "dev_team",
			"color": "#4fc3f7",
			"state": "WORKING",
			"target": "Desk_android_dev",
			"logs": [],
		}],
	})
	await _wait(0.4)
	var agent: Agent = main.agents["android_dev"]
	_check(agent != null and agent.is_seated_at_desk(), "starts seated at own desk")
	var desk_pos: Vector2 = agent.global_position
	var desk_kind: String = main._area_kind_at(desk_pos)
	_check(desk_kind in ["room", "wing", "team"], "desk area_kind is team room (got %s)" % desk_kind)

	# Route toward yoga, then force a stuck settle still at the desk (team room).
	main.handle_message({
		"type": "STATE_CHANGE",
		"agent_id": "android_dev",
		"state": "IDLE",
		"target": "Yoga_Mat_1",
		"text": "Tree pose…",
	})
	await process_frame
	# Keep body in the team room; finish nav path immediately so _arrive runs far from target.
	agent.global_position = desk_pos
	agent.sync_view()
	agent.nav_agent.target_position = desk_pos
	# Wait until settled (nav finished → _arrive).
	for i in 30:
		if agent.is_at_destination():
			break
		await _wait(0.05)
	_check(agent.is_at_destination(), "stuck arrival settled at destination flag")
	_check(main._area_kind_at(agent.global_position) in ["room", "wing", "team"],
		"stuck body still in team room (got %s)" % main._area_kind_at(agent.global_position))
	_check(agent.current_waypoint == "Yoga_Mat_1", "waypoint name still Yoga_Mat_1 after stuck")
	_check(not _is_amenity_seat(agent),
		"no amenity seat pose after stuck in team room (seat=%s)" % _seat_of(agent))
	_check(not agent.bubble.visible,
		"no yoga bubble while stuck in team room (wp trust must not fire)")

	# Mid-chatter with target=None (harness _away): still must not show amenity line.
	main.handle_message({
		"type": "STATE_CHANGE",
		"agent_id": "android_dev",
		"state": "IDLE",
		"text": "Namaste.",
	})
	await process_frame
	_check(not agent.bubble.visible, "targetless amenity chatter suppressed while in team room")

	# Real arrival at the yoga mat: re-route must not early-return (stuck still
	# held the Yoga slot while standing in Engineering). Pose + bubble OK.
	main.handle_message({
		"type": "STATE_CHANGE",
		"agent_id": "android_dev",
		"state": "IDLE",
		"target": "Yoga_Mat_1",
		"text": "Tree pose…",
	})
	await process_frame
	_check(not agent.is_at_destination() or agent.global_position.distance_to(
		(main.waypoints["Yoga_Mat_1"] as Node2D).global_position) > 4.0,
		"re-route after stuck starts nav again (not early-return)")
	var yoga: Vector2 = (main.waypoints["Yoga_Mat_1"] as Node2D).global_position
	agent.global_position = yoga
	agent.sync_view()
	agent.nav_agent.target_position = yoga
	for i in 40:
		if agent.is_at_destination() and _seat_of(agent) == "yoga":
			break
		await _wait(0.05)
	var yoga_kind: String = main._area_kind_at(agent.global_position)
	_check(yoga_kind == "rec", "body in rec after teleport (got %s)" % yoga_kind)
	_check(_seat_of(agent) == "yoga", "yoga seat pose when actually in rec (seat=%s)" % _seat_of(agent))
	# Re-send amenity text once settled in Rec.
	main.handle_message({
		"type": "STATE_CHANGE",
		"agent_id": "android_dev",
		"state": "IDLE",
		"text": "Tree pose…",
	})
	await process_frame
	_check(agent.bubble.visible, "yoga bubble shown when area_kind_at is rec")

	# Desk return: must sit again.
	main.handle_message({
		"type": "STATE_CHANGE",
		"agent_id": "android_dev",
		"state": "WORKING",
		"target": "Desk_android_dev",
		"text": "Back to it.",
	})
	agent.global_position = desk_pos
	agent.sync_view()
	agent.nav_agent.target_position = desk_pos
	for i in 40:
		if agent.is_at_destination():
			break
		await _wait(0.05)
	for i in 20:
		if agent.is_seated_at_desk():
			break
		await _wait(0.05)
	_check(agent.is_seated_at_desk(), "seated at desk after return")

	print("arrival room gate: %s" % ("PASS" if failures.is_empty() else "FAIL (%d)" % failures.size()))
	for f in failures:
		print("  - %s" % f)
	quit(0 if failures.is_empty() else 1)


func _seat_of(agent: Agent) -> String:
	return str(agent._seat)


func _is_amenity_seat(agent: Agent) -> bool:
	return _seat_of(agent) in ["yoga", "meditate", "foosball", "sofa", "chair"]
