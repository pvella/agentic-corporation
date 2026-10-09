## Agent Office main scene.
##
## - Bakes the navigation polygon at runtime from Office.gd's floor/obstacles.
## - Maintains a WebSocketPeer to the Python harness (auto-reconnect with
##   exponential backoff, connection status in the HUD).
## - Spawns Agent nodes from SNAPSHOT messages and routes STATE_CHANGE /
##   LOG_ENTRY / COLLABORATE events to them.
## - Opens the TerminalDrawer when an agent is clicked and forwards
##   DISPATCH_PROMPT commands back to the harness.
##
## Optional user args (after `--` on the command line):
##   --url=ws://host:port          override server_url
##   --screenshot=path.png         save a viewport screenshot (needs a renderer, not --headless)
##   --screenshot-delay=8          seconds to wait before the screenshot (default 6)
##   --quit-after-screenshot       exit after saving
##   --open-drawer=coder_agent     open that agent's terminal once it spawns
##   --dispatch=coder_agent:Fix bug in auth.py   send a prompt once connected
extends Node2D

const Ansi := preload("res://ansi.gd")
const MEETING_TARGET := "Meeting_Room"
const MEETING_SEATS: PackedStringArray = ["Meeting_Table_1", "Meeting_Table_2", "Meeting_Table_3", "Meeting_Table_4"]
const IDLE_SPOTS: PackedStringArray = ["Coffee_Machine", "Water_Cooler"]
## Offsets used when several agents share one waypoint (index = arrival order).
const SPOT_OFFSETS: Array[Vector2] = [Vector2.ZERO, Vector2(-34, 8), Vector2(34, 8), Vector2(0, 36), Vector2(-34, 40), Vector2(34, 40)]
const FALLBACK_COLORS: Array[Color] = [Color("#4fc3f7"), Color("#81c784"), Color("#ffb74d"), Color("#f06292"), Color("#ba68c8"), Color("#4db6ac")]

@export var server_url: String = "ws://127.0.0.1:8765"
@export var agent_scene: PackedScene
@export var reconnect_min: float = 1.0
@export var reconnect_max: float = 15.0
@export var nav_agent_radius: float = 14.0

## agent_id -> Agent
var agents: Dictionary = {}
## marker name -> Marker2D
var waypoints: Dictionary = {}

var _socket: WebSocketPeer = null
var _socket_state: int = -1
var _reconnect_in: float = 0.0
var _backoff: float = 1.0
var _server_info: Dictionary = {}
var _offline_reason: String = ""
var _occupancy: Dictionary = {}  # waypoint name -> Array[String] of agent ids
var _selected: Agent = null
var _roster_buttons: Dictionary = {}  # agent_id -> Button

# user-arg options
var _screenshot_path: String = ""
var _screenshot_delay: float = 6.0
var _quit_after_screenshot: bool = false
var _open_drawer_for: String = ""
var _pending_dispatch: Dictionary = {}

@onready var office: Node2D = $Office
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var waypoints_root: Node2D = $Waypoints
@onready var agents_root: Node2D = $Agents
@onready var drawer: CanvasLayer = $TerminalDrawer
@onready var status_dot: Panel = $HUD/TopBar/Margin/HBox/StatusDot
@onready var status_label: Label = $HUD/TopBar/Margin/HBox/StatusLabel
@onready var roster: HBoxContainer = $HUD/TopBar/Margin/HBox/Roster


func _ready() -> void:
	get_viewport().physics_object_picking = true
	_parse_user_args()
	_bake_navigation()
	for child in waypoints_root.get_children():
		if child is Marker2D:
			waypoints[String(child.name)] = child
	drawer.prompt_submitted.connect(_on_prompt_submitted)
	drawer.closed.connect(_on_drawer_closed)
	_backoff = reconnect_min
	_connect_socket()
	if _screenshot_path != "":
		_take_screenshot()


func _process(delta: float) -> void:
	_poll_socket(delta)


func _exit_tree() -> void:
	if _socket and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "client exiting")
		_socket.poll()


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
## Builds the NavigationPolygon from the office floor minus furniture, so the
## project works without any manual baking in the editor.
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
			var reason := "server unreachable" if code == -1 else "closed (%d)" % code
			_schedule_reconnect(reason)


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
			if drawer.is_open() and drawer.agent.agent_id == str(msg.get("agent_id", "")):
				drawer.append_system("prompt accepted by harness (queue: %d)" % int(msg.get("queued", 0)), "#56b6c2")
		"ERROR":
			push_warning("Harness error: %s" % str(msg.get("message", "")))
			if drawer.is_open():
				drawer.append_system("harness error: %s" % str(msg.get("message", "")), "#e06c75")
		"PONG":
			pass
		var other:
			push_warning("Unknown message type '%s'" % other)


func _apply_snapshot(msg: Dictionary) -> void:
	_server_info = msg.get("server", {})
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
		if target.is_empty() or not (waypoints.has(target) or target == MEETING_TARGET):
			target = _default_target(agent, state)
		agent.set_state(state)
		if fresh or agent.current_waypoint != target:
			_route(agent, target)
	# Drop agents the server no longer knows about.
	for id: String in agents.keys():
		if not seen.has(id):
			_remove_agent(id)
	drawer.refresh()
	var mode := str(_server_info.get("mode", "?"))
	_set_status("Connected to %s  (harness %s, %s mode, %d agents)" % [server_url, _server_info.get("version", "?"), mode, agents.size()], Color("#43a047"))
	# One-shot user-arg actions.
	if _open_drawer_for != "" and agents.has(_open_drawer_for):
		_on_agent_clicked(agents[_open_drawer_for])
		_open_drawer_for = ""
	if not _pending_dispatch.is_empty():
		send_json(_pending_dispatch)
		_pending_dispatch = {}


func _apply_state(agent: Agent, state: String, target: String, text: String) -> void:
	agent.set_state(state)
	if not target.is_empty():
		_route(agent, target)
	if not text.is_empty():
		agent.show_bubble(Ansi.strip(text), state.to_upper() == "THINKING")


func _apply_collaborate(msg: Dictionary) -> void:
	var ids: Array = msg.get("agents", [])
	var target := _str_or_empty(msg.get("target"))
	if target.is_empty():
		target = MEETING_TARGET
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
	var desk := str(data.get("desk", ""))
	if not waypoints.has(desk):
		desk = IDLE_SPOTS[agents.size() % IDLE_SPOTS.size()]
	var agent: Agent = agent_scene.instantiate()
	agent.setup(id, str(data.get("name", id)), colour, desk, waypoints)
	agents_root.add_child(agent)
	var entrance: Marker2D = waypoints.get("Entrance")
	if entrance:
		agent.global_position = entrance.global_position + Vector2(randf_range(-24.0, 24.0), randf_range(-6.0, 0.0))
	agent.clicked.connect(_on_agent_clicked)
	agent.state_changed.connect(func(a: Agent, _s: String) -> void: _update_roster(a))
	agents[id] = agent
	_add_roster_button(agent)
	return agent


func _remove_agent(id: String) -> void:
	var agent: Agent = agents.get(id)
	if agent == null:
		return
	if drawer.agent == agent:
		drawer.close()
	_release(agent)
	agents.erase(id)
	if _roster_buttons.has(id):
		_roster_buttons[id].queue_free()
		_roster_buttons.erase(id)
	agent.queue_free()


func _default_target(agent: Agent, state: String) -> String:
	match state.to_upper():
		"WORKING":
			return agent.desk
		"COLLAB", "COLLABORATE":
			return MEETING_TARGET
		_:
			return IDLE_SPOTS[agents.keys().find(agent.agent_id) % IDLE_SPOTS.size()]


## Sends an agent to a named target, handling Meeting_Room seat allocation and
## spreading agents that share the same waypoint.
func _route(agent: Agent, target: String) -> void:
	_release(agent)
	if target == MEETING_TARGET:
		target = _free_meeting_seat()
	if not waypoints.has(target):
		push_warning("Unknown target '%s' for %s" % [target, agent.agent_id])
		return
	# Take the lowest free slot so agents never stack on the same offset.
	var occupants: Array = _occupancy.get(target, [])
	var index := occupants.find("")
	if index == -1:
		index = occupants.size()
		occupants.append(agent.agent_id)
	else:
		occupants[index] = agent.agent_id
	_occupancy[target] = occupants
	agent.go_to_waypoint(target, SPOT_OFFSETS[index % SPOT_OFFSETS.size()])


func _release(agent: Agent) -> void:
	for key: String in _occupancy.keys():
		var occupants: Array = _occupancy[key]
		var i := occupants.find(agent.agent_id)
		if i != -1:
			occupants[i] = ""  # keep other agents' slot indices stable


func _free_meeting_seat() -> String:
	var best := MEETING_SEATS[0]
	var best_count := 1 << 30
	for seat in MEETING_SEATS:
		var count := 0
		for occupant: String in (_occupancy.get(seat, []) as Array):
			if occupant != "":
				count += 1
		if count < best_count:
			best = seat
			best_count = count
	return best


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
# HUD roster
# ---------------------------------------------------------------------------
func _add_roster_button(agent: Agent) -> void:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(func() -> void: _on_agent_clicked(agent))
	roster.add_child(b)
	_roster_buttons[agent.agent_id] = b
	_update_roster(agent)


func _update_roster(agent: Agent) -> void:
	var b: Button = _roster_buttons.get(agent.agent_id)
	if b == null:
		return
	b.text = "%s  ·  %s" % [agent.display_name, agent.state]
	b.add_theme_color_override("font_color", agent.body_color.lightened(0.3))
	b.add_theme_color_override("font_hover_color", agent.body_color.lightened(0.6))
	b.tooltip_text = "Open %s's terminal" % agent.agent_id


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
			"--open-drawer":
				_open_drawer_for = value
			"--dispatch":
				var parts := value.split(":", true, 1)
				if parts.size() == 2:
					_pending_dispatch = {"action": "DISPATCH_PROMPT", "agent_id": parts[0], "prompt": parts[1]}


func _take_screenshot() -> void:
	await get_tree().create_timer(_screenshot_delay).timeout
	await RenderingServer.frame_post_draw
	var path := _screenshot_path
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	var tex := get_viewport().get_texture()
	var img: Image = tex.get_image() if tex else null
	if img == null or img.is_empty():
		push_warning("Screenshot unavailable (headless/dummy renderer?)")
	else:
		var err := img.save_png(path)
		print("[AgentOffice] screenshot saved to %s (%s)" % [path, error_string(err)])
	if _quit_after_screenshot:
		get_tree().quit()
