## Agentic Corporation · Agent Office main scene.
##
## - Builds the office from OFFICE_LAYOUT (or the built-in legacy layout when
##   the harness sends none): floor plan, y-sorted furniture props, Marker2D
##   waypoints, clickable room signs, and a runtime-baked navigation polygon.
## - Maintains a WebSocketPeer to agent_harness.py (auto-reconnect with
##   exponential backoff, status in the HUD).
## - Spawns Agent nodes from SNAPSHOT messages (placed straight at their spot)
##   and routes STATE_CHANGE / LOG_ENTRY / COLLABORATE events to them.
## - Opens the TerminalDrawer for a clicked agent, or a team summary for a
##   clicked room sign, and forwards DISPATCH_PROMPT back to the harness.
##
## Optional user args (after `--` on the command line):
##   --url=ws://host:port          override server_url
##   --screenshot=path.png         save a viewport screenshot (needs a renderer, not --headless)
##   --screenshot-delay=8          seconds to wait before the screenshot (default 6)
##   --quit-after-screenshot       exit after saving
##   --screenshot-every=S --screenshot-count=N
##                                 take N shots S seconds apart (path gets _001, _002 ...)
##   --open-drawer=AGENT_ID        open that agent's terminal once it spawns
##   --open-team=ROOM_ID           open a room's team summary once agents spawn
##   --dispatch=AGENT_ID:prompt    send a prompt once connected
##   --zoom=1.5 --focus=x,y        start the camera zoomed in on a world point
##   --focus-agent=AGENT_ID        ...or on an agent (followed until the screenshot)
extends Node2D

const Ansi := preload("res://ansi.gd")
const PropScript := preload("res://Prop.gd")
const Office := preload("res://Office.gd")
## Offsets used when several agents share one standing spot (index = slot).
const SPOT_OFFSETS: Array[Vector2] = [Vector2.ZERO, Vector2(-30, 10), Vector2(30, 10), Vector2(0, 34), Vector2(-32, 42), Vector2(32, 42), Vector2(-56, 24), Vector2(56, 24)]
const FALLBACK_COLORS: Array[Color] = [Color("#4fc3f7"), Color("#81c784"), Color("#ffb74d"), Color("#f06292"), Color("#ba68c8"), Color("#4db6ac")]

@export var server_url: String = "ws://127.0.0.1:8765"
@export var agent_scene: PackedScene
@export var reconnect_min: float = 1.0
@export var reconnect_max: float = 15.0
@export var nav_agent_radius: float = 11.0

## agent_id -> Agent
var agents: Dictionary = {}
## marker name -> Marker2D
var waypoints: Dictionary = {}
## The office config currently built (OFFICE_LAYOUT payload or legacy).
var layout_cfg: Dictionary = {}
var using_legacy_layout := true

var _socket: WebSocketPeer = null
var _socket_state: int = -1
var _reconnect_in: float = 0.0
var _backoff: float = 1.0
var _server_info: Dictionary = {}
var _offline_reason: String = ""
var _occupancy: Dictionary = {}  # waypoint name -> Array[String] (agent ids, "" = free slot)
var _selected: Agent = null
var _desk_props: Dictionary = {}  # agent_id -> Prop
var _foosball_props: Array = []
var _room_buttons: Array[Button] = []
var _spawn_index := 0

# user-arg options
var _screenshot_path: String = ""
var _screenshot_delay: float = 6.0
var _quit_after_screenshot: bool = false
var _screenshot_every: float = 0.0
var _screenshot_count: int = 1
var _open_drawer_for: String = ""
var _open_team_for: String = ""
var _pending_dispatch: Dictionary = {}
var _start_zoom: float = 0.0
var _start_focus := Vector2.INF
var _follow_agent: String = ""

@onready var camera: Camera2D = $Camera2D
@onready var office: Node2D = $Office
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var waypoints_root: Node2D = $Waypoints
@onready var props_root: Node2D = $World/Props
@onready var agents_root: Node2D = $World/Agents
@onready var signs_root: Node2D = $Signs
@onready var drawer: CanvasLayer = $TerminalDrawer
@onready var status_dot: Panel = $HUD/TopBar/Margin/HBox/StatusDot
@onready var status_label: Label = $HUD/TopBar/Margin/HBox/StatusLabel
@onready var roster: HBoxContainer = $HUD/TopBar/Margin/HBox/Roster
@onready var counts_label: Label = $HUD/BottomBar/Counts


func _ready() -> void:
	get_viewport().physics_object_picking = true
	_parse_user_args()
	drawer.prompt_submitted.connect(_on_prompt_submitted)
	drawer.closed.connect(_on_drawer_closed)
	drawer.agent_requested.connect(func(id: String) -> void:
		if agents.has(id):
			_on_agent_clicked(agents[id]))
	camera.zoom_changed.connect(_apply_ui_scale)
	build_layout(Office.LEGACY_LAYOUT, true)
	_backoff = reconnect_min
	_connect_socket()
	if _screenshot_path != "":
		_take_screenshot()


func _process(delta: float) -> void:
	_poll_socket(delta)
	_update_foosball()
	if _follow_agent != "" and agents.has(_follow_agent):
		camera.position = (agents[_follow_agent] as Agent).global_position + Vector2(0, -30)


func _exit_tree() -> void:
	if _socket and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "client exiting")
		_socket.poll()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
## (Re)builds the whole office from a layout config. Existing agents are
## removed; the following SNAPSHOT respawns them.
func build_layout(cfg: Dictionary, legacy: bool = false) -> void:
	for id: String in agents.keys():
		_remove_agent(id)
	_spawn_index = 0
	drawer.close()
	for n in waypoints_root.get_children() + props_root.get_children() + signs_root.get_children():
		n.queue_free()
	waypoints.clear()
	_occupancy.clear()
	_desk_props.clear()
	_foosball_props.clear()

	office.build(cfg)
	layout_cfg = cfg
	using_legacy_layout = legacy
	_bake_navigation()
	for wp: Dictionary in office.waypoints:
		var m := Marker2D.new()
		m.name = str(wp.name).validate_node_name()
		m.position = wp.pos
		m.set_meta("facing", wp.facing)
		m.set_meta("seat", wp.seat)
		waypoints_root.add_child(m)
		waypoints[str(wp.name)] = m
	for d: Dictionary in office.props:
		var p := Node2D.new()
		p.set_script(PropScript)
		props_root.add_child(p)
		p.setup(d)
		if d.kind == "desk" and str(d.get("owner", "")) != "":
			_desk_props[str(d.owner)] = p
		elif d.kind == "foosball":
			_foosball_props.append(p)
	for s: Dictionary in office.signs:
		if not s.clickable:
			continue
		var area := Area2D.new()
		area.input_pickable = true
		area.monitoring = false
		area.collision_layer = 8
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = (s.rect as Rect2).size
		shape.shape = rect_shape
		area.position = (s.rect as Rect2).get_center()
		area.add_child(shape)
		var room_id := str(s.room_id)
		area.input_event.connect(func(_vp: Node, ev: InputEvent, _i: int) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				open_team(room_id)
				get_viewport().set_input_as_handled())
		signs_root.add_child(area)
	_build_room_buttons()
	camera.set_bounds(office.bounds, true)
	if _start_zoom > 0.0:
		camera.focus_on(_start_focus if _start_focus != Vector2.INF else office.bounds.get_center(), _start_zoom)
	_apply_ui_scale(camera.zoom.x)
	print("[AgentOffice] layout '%s': %d rooms, %d waypoints, %d props" % [office.layout_name, office.rooms.size(), waypoints.size(), office.props.size()])


## Builds the NavigationPolygon from the generated floor minus walls and furniture.
func _bake_navigation() -> void:
	var poly := NavigationPolygon.new()
	poly.agent_radius = nav_agent_radius
	var source := NavigationMeshSourceGeometryData2D.new()
	source.add_traversable_outline(office.get_floor_outline())
	for outline: PackedVector2Array in office.get_obstacle_outlines():
		source.add_obstruction_outline(outline)
	NavigationServer2D.bake_from_source_geometry_data(poly, source)
	nav_region.navigation_polygon = poly
	if poly.get_polygon_count() == 0:
		push_error("Navigation bake produced no polygons; agents will not be able to walk.")
	else:
		print("[AgentOffice] navigation baked: %d polygons, %d vertices" % [poly.get_polygon_count(), poly.get_vertices().size()])


func _build_room_buttons() -> void:
	for b in _room_buttons:
		b.queue_free()
	_room_buttons.clear()
	for r: Dictionary in office.rooms:
		var b := Button.new()
		b.text = str(r.name)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", Color.from_string(str(r.get("color", "#ffffff")), Color.WHITE).lightened(0.2))
		b.tooltip_text = "Team summary"
		var rid := str(r.id)
		b.pressed.connect(func() -> void: open_team(rid))
		roster.add_child(b)
		_room_buttons.append(b)


## Opens the team summary for a room in the drawer.
func open_team(room_id: String) -> void:
	for r: Dictionary in office.rooms:
		if str(r.id) == room_id:
			var members: Array = []
			for m: Dictionary in r.get("members", []):
				if agents.has(str(m.agent_id)):
					members.append(agents[str(m.agent_id)])
			if _selected and is_instance_valid(_selected):
				_selected.set_selected(false)
			_selected = null
			drawer.open_team(r, members)
			return


# ---------------------------------------------------------------------------
# WebSocket
# ---------------------------------------------------------------------------
func _connect_socket() -> void:
	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = 1 << 22  # snapshots carry log history
	_socket.outbound_buffer_size = 1 << 16
	_socket.max_queued_packets = 4096
	_socket_state = -1
	var err := _socket.connect_to_url(server_url)
	if err != OK:
		_schedule_reconnect("connect_to_url failed (%s)" % error_string(err))
		return
	_set_status("Connecting to %s ..." % server_url, Color("#fdd835"))


func _schedule_reconnect(reason: String) -> void:
	_socket = null
	_reconnect_in = _backoff
	_backoff = minf(_backoff * 2.0, reconnect_max)
	_offline_reason = reason
	print("[AgentOffice] disconnected: %s; retrying in %.0fs" % [reason, _reconnect_in])
	_set_status("Offline: %s. Retrying in %ds" % [reason, ceili(_reconnect_in)], Color("#e53935"))


func _poll_socket(delta: float) -> void:
	if _socket == null:
		_reconnect_in -= delta
		status_label.text = "Offline: %s. Retrying in %ds" % [_offline_reason, ceili(maxf(_reconnect_in, 0.0))]
		if _reconnect_in <= 0.0:
			_connect_socket()
		return
	_socket.poll()
	var st := _socket.get_ready_state()
	if st != _socket_state:
		_socket_state = st
		if st == WebSocketPeer.STATE_OPEN:
			_backoff = reconnect_min
			_set_status("Connected to %s" % server_url, Color("#43a047"))
			print("[AgentOffice] connected to ", server_url)
	match st:
		WebSocketPeer.STATE_OPEN:
			while _socket.get_available_packet_count() > 0:
				_handle_raw(_socket.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			_schedule_reconnect("server unreachable" if code == -1 else "closed (%d)" % code)


## Sends a JSON command to the harness. Returns false when offline.
func send_json(payload: Dictionary) -> bool:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return _socket.send_text(JSON.stringify(payload)) == OK


func _set_status(text: String, colour: Color) -> void:
	status_label.text = text
	var sb := StyleBoxFlat.new()
	sb.bg_color = colour
	sb.set_corner_radius_all(6)
	status_dot.add_theme_stylebox_override("panel", sb)


# ---------------------------------------------------------------------------
# Message routing
# ---------------------------------------------------------------------------
func _handle_raw(raw: String) -> void:
	var msg: Variant = JSON.parse_string(raw)
	if typeof(msg) != TYPE_DICTIONARY:
		push_warning("Ignoring non-object message: %s" % raw.left(120))
		return
	handle_message(msg)


func handle_message(msg: Dictionary) -> void:
	match String(msg.get("type", "")):
		"OFFICE_LAYOUT":
			var cfg: Dictionary = msg.get("office", {})
			if using_legacy_layout or JSON.stringify(cfg) != JSON.stringify(layout_cfg):
				build_layout(cfg, false)
		"SNAPSHOT", "REGISTRY":
			_apply_snapshot(msg)
		"STATE_CHANGE":
			var agent := _get_or_spawn(str(msg.get("agent_id", "")))
			if agent:
				_apply_state(agent, str(msg.get("state", "IDLE")), _str_or_empty(msg.get("target")), str(msg.get("text", "")))
		"LOG_ENTRY":
			var agent := _get_or_spawn(str(msg.get("agent_id", "")))
			if agent:
				agent.add_log(str(msg.get("log", "")))
		"COLLABORATE":
			_apply_collaborate(msg)
		"ACK":
			if drawer.agent and drawer.agent.agent_id == str(msg.get("agent_id", "")):
				drawer.append_system("prompt accepted by harness (queue: %d)" % int(msg.get("queued", 0)), "#56b6c2")
		"ERROR":
			push_warning("Harness error: %s" % str(msg.get("message", "")))
			if drawer.agent:
				drawer.append_system("harness error: %s" % str(msg.get("message", "")), "#e06c75")
		"PONG":
			pass
		var other:
			push_warning("Unknown message type '%s'" % other)


func _apply_snapshot(msg: Dictionary) -> void:
	_server_info = msg.get("server", {})
	# A harness without an office config means the legacy layout.
	if _server_info.has("office") and _server_info.office == null and not using_legacy_layout:
		build_layout(Office.LEGACY_LAYOUT, true)
	var seen: Dictionary = {}
	for data: Variant in msg.get("agents", []):
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var id := str(data.get("agent_id", ""))
		if id.is_empty():
			continue
		seen[id] = true
		var agent: Agent = agents.get(id)
		var fresh := agent == null
		if fresh:
			agent = _spawn_agent(data)
		agent.set_logs(data.get("logs", []))
		var state := str(data.get("state", "IDLE"))
		var target := _str_or_empty(data.get("target"))
		if target.is_empty() or not (waypoints.has(target) or office.meeting_groups.has(target)):
			target = _default_target(agent, state)
		agent.set_state(state)
		if str(data.get("text", "")) != "":
			agent.last_text = str(data.text)
		# Fresh agents appear right at their spot (no stampede from the door).
		_route(agent, target, fresh)
	for id: String in agents.keys():
		if not seen.has(id):
			_remove_agent(id)
	drawer.refresh()
	_set_status("Connected · %s · %s mode, %s tempo" % [office.layout_name, _server_info.get("mode", "?"), _server_info.get("tempo", "?")], Color("#43a047"))
	_update_counts()
	if _open_drawer_for != "" and agents.has(_open_drawer_for):
		_on_agent_clicked(agents[_open_drawer_for])
		_open_drawer_for = ""
	if _open_team_for != "":
		open_team(_open_team_for)
		_open_team_for = ""
	if not _pending_dispatch.is_empty():
		send_json(_pending_dispatch)
		_pending_dispatch = {}


func _apply_state(agent: Agent, state: String, target: String, text: String) -> void:
	agent.set_state(state)
	if not target.is_empty():
		_route(agent, target)
	elif state.to_upper() in ["THINKING", "WORKING", "ERROR"] and agent.is_away_from_desk():
		agent.glance_phone(4.0)  # an update while away from the desk: check the phone
	if not text.is_empty():
		agent.show_bubble(Ansi.strip(text), state.to_upper() == "THINKING")
	drawer.on_agent_changed(agent)
	_update_counts()


func _apply_collaborate(msg: Dictionary) -> void:
	var ids: Array = msg.get("agents", [])
	var target := _str_or_empty(msg.get("target"))
	if target.is_empty():
		target = "Meeting_Room"
	var names: PackedStringArray = []
	for id: Variant in ids:
		var a := _get_or_spawn(str(id))
		if a:
			names.append(a.display_name)
	var text := str(msg.get("text", ""))
	for i in ids.size():
		var agent: Agent = agents.get(str(ids[i]))
		if agent == null:
			continue
		agent.set_state("COLLAB")
		_route(agent, target)
		if i == 0:
			agent.show_bubble(text if text != "" else "Let's sync: %s" % " & ".join(names), false)
		drawer.on_agent_changed(agent)
	_update_counts()


# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------
func _get_or_spawn(id: String) -> Agent:
	if id.is_empty():
		return null
	if agents.has(id):
		return agents[id]
	# Unknown agent (e.g. harness added one after our snapshot): spawn with defaults.
	return _spawn_agent({"agent_id": id, "name": id.trim_suffix("_agent").capitalize()})


func _spawn_agent(data: Dictionary) -> Agent:
	var id := str(data.get("agent_id"))
	var fallback := FALLBACK_COLORS[agents.size() % FALLBACK_COLORS.size()]
	var colour := Color.from_string(str(data.get("color", "")), fallback)
	var desk := str(data.get("desk", office.desk_of.get(id, "")))
	var agent: Agent = agent_scene.instantiate()
	agent.setup(id, str(data.get("name", id)), colour, desk, waypoints, _spawn_index)
	_spawn_index += 1
	agent.role = str(data.get("role", ""))
	agent.room_id = str(data.get("room", office.agent_room.get(id, "")))
	if not waypoints.has(desk):
		agent.desk = _break_spots_for(agent)[0]
	agents_root.add_child(agent)
	var entrance_name := "%s_Entrance" % agent.room_id if waypoints.has("%s_Entrance" % agent.room_id) else "Entrance"
	var entrance: Marker2D = waypoints.get(entrance_name)
	if entrance:
		agent.global_position = entrance.global_position
	agent.clicked.connect(_on_agent_clicked)
	agent.set_ui_scale(_ui_scale_for(camera.zoom.x))
	agents[id] = agent
	if _desk_props.has(id):
		_desk_props[id].owner_agent = agent
	return agent


func _remove_agent(id: String) -> void:
	var agent: Agent = agents.get(id)
	if agent == null:
		return
	if drawer.agent == agent:
		drawer.close()
	_release(agent)
	agents.erase(id)
	agent.queue_free()


func _is_isolated_room(room_id: String) -> bool:
	for r: Dictionary in office.rooms:
		if str(r.id) == room_id:
			return bool(r.get("isolated", false))
	return false


func _break_spots_for(agent: Agent) -> Array:
	var spots: Array = office.room_break_spots.get(agent.room_id, ["Coffee_Machine", "Water_Cooler"])
	var ok: Array = spots.filter(func(s: Variant) -> bool: return waypoints.has(str(s)))
	return ok if not ok.is_empty() else ["Coffee_Machine"]


func _meeting_target_for(agent: Agent) -> String:
	var t := "%s_Meeting_Room" % agent.room_id
	return t if office.meeting_groups.has(t) else "Meeting_Room"


func _default_target(agent: Agent, state: String) -> String:
	match state.to_upper():
		"WORKING", "THINKING", "ERROR":
			return agent.desk
		"COLLAB", "COLLABORATE":
			return _meeting_target_for(agent)
		_:
			var spots := _break_spots_for(agent)
			return str(spots[absi(agent.agent_id.hash()) % spots.size()])


## Sends an agent to a named target. Virtual meeting targets resolve to a free
## seat; agents sharing a standing spot are spread over fixed slots; re-sending
## the spot an agent already holds is ignored (no re-pathing while standing).
func _route(agent: Agent, target: String, instant: bool = false) -> void:
	if office.meeting_groups.has(target):
		var seats: Array = office.meeting_groups[target]
		if seats.has(agent.current_waypoint) and _holds_slot(agent, agent.current_waypoint):
			return
		target = _free_seat(seats)
	if not waypoints.has(target):
		push_warning("Unknown target '%s' for %s" % [target, agent.agent_id])
		return
	if target == agent.current_waypoint and _holds_slot(agent, target) and not instant:
		return
	_release(agent)
	var occupants: Array = _occupancy.get(target, [])
	var index := occupants.find("")
	if index == -1:
		index = occupants.size()
		occupants.append(agent.agent_id)
	else:
		occupants[index] = agent.agent_id
	_occupancy[target] = occupants
	agent.go_to_waypoint(target, SPOT_OFFSETS[index % SPOT_OFFSETS.size()], instant)


func _holds_slot(agent: Agent, wp: String) -> bool:
	return (_occupancy.get(wp, []) as Array).has(agent.agent_id)


func _release(agent: Agent) -> void:
	for key: String in _occupancy.keys():
		var occupants: Array = _occupancy[key]
		var i := occupants.find(agent.agent_id)
		if i != -1:
			occupants[i] = ""  # keep other agents' slot indices stable


func _free_seat(seats: Array) -> String:
	var best := str(seats[0])
	var best_count := 1 << 30
	for seat: Variant in seats:
		var count := 0
		for occupant: String in (_occupancy.get(str(seat), []) as Array):
			if occupant != "":
				count += 1
		if count < best_count:
			best = str(seat)
			best_count = count
	return best


func _update_foosball() -> void:
	if _foosball_props.is_empty():
		return
	var players := 0
	for a: Agent in agents.values():
		if a.current_waypoint.begins_with("Foosball_") and a.is_at_destination():
			players += 1
	for p in _foosball_props:
		p.playing = players >= 2


func _on_agent_clicked(agent: Agent) -> void:
	if _selected and is_instance_valid(_selected):
		_selected.set_selected(false)
	_selected = agent
	agent.set_selected(true)
	drawer.open_for(agent)


func _on_drawer_closed() -> void:
	if _selected and is_instance_valid(_selected):
		_selected.set_selected(false)
	_selected = null


func _on_prompt_submitted(agent_id: String, prompt: String) -> void:
	var ok := send_json({"action": "DISPATCH_PROMPT", "agent_id": agent_id, "prompt": prompt})
	if not ok:
		drawer.append_system("Not connected to the harness; prompt not sent.", "#e06c75")


# ---------------------------------------------------------------------------
# HUD / UI scale
# ---------------------------------------------------------------------------
func _update_counts() -> void:
	var c := {}
	for a: Agent in agents.values():
		c[a.state] = int(c.get(a.state, 0)) + 1
	counts_label.text = "%d agents · %d working · %d thinking · %d meeting · %d idle" % [
		agents.size(), c.get("WORKING", 0), c.get("THINKING", 0), c.get("COLLAB", 0), c.get("IDLE", 0)]
	if int(c.get("ERROR", 0)) > 0:
		counts_label.text += " · %d error" % int(c.get("ERROR", 0))


## Name pills and bubbles grow a little when zoomed out so they stay legible.
func _ui_scale_for(z: float) -> float:
	return clampf(0.85 / z, 1.0, 1.8)


func _apply_ui_scale(z: float) -> void:
	var s := _ui_scale_for(z)
	for a: Agent in agents.values():
		a.set_ui_scale(s)


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
func _str_or_empty(v: Variant) -> String:
	return "" if v == null else str(v)


func _parse_user_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var key := arg
		var value := ""
		if arg.contains("="):
			key = arg.get_slice("=", 0)
			value = arg.substr(key.length() + 1)
		match key:
			"--url":
				server_url = value
			"--screenshot":
				_screenshot_path = value
			"--screenshot-delay":
				_screenshot_delay = value.to_float()
			"--quit-after-screenshot":
				_quit_after_screenshot = true
			"--screenshot-every":
				_screenshot_every = value.to_float()
			"--screenshot-count":
				_screenshot_count = maxi(1, value.to_int())
			"--open-drawer":
				_open_drawer_for = value
			"--open-team":
				_open_team_for = value
			"--zoom":
				_start_zoom = value.to_float()
			"--focus":
				var xy := value.split(",")
				if xy.size() == 2:
					_start_focus = Vector2(xy[0].to_float(), xy[1].to_float())
			"--focus-agent":
				_follow_agent = value
			"--dispatch":
				var parts := value.split(":", true, 1)
				if parts.size() == 2:
					_pending_dispatch = {"action": "DISPATCH_PROMPT", "agent_id": parts[0], "prompt": parts[1]}


func _take_screenshot() -> void:
	await get_tree().create_timer(_screenshot_delay).timeout
	var path := _screenshot_path
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	for i in _screenshot_count:
		if i > 0:
			await get_tree().create_timer(maxf(_screenshot_every, 0.1)).timeout
		await RenderingServer.frame_post_draw
		var out := path if _screenshot_count == 1 else "%s_%03d.png" % [path.trim_suffix(".png"), i + 1]
		var tex := get_viewport().get_texture()
		var img: Image = tex.get_image() if tex else null
		if img == null or img.is_empty():
			push_warning("Screenshot unavailable (headless/dummy renderer?)")
			break
		var err := img.save_png(out)
		print("[AgentOffice] screenshot saved to %s (%s)" % [out, error_string(err)])
	if _quit_after_screenshot:
		get_tree().quit()
