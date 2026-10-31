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
##   --open-team=ROOM_ID           jump to a room and open its team summary once agents spawn
##   --dispatch=AGENT_ID:prompt    send a prompt once connected
##   --preview-hire / --preview-fire / --preview-hire-fire
##                                 demo the hire / fire pageantry once connected
## Keyboard: V toggles iso view; Shift+V toggles quiet/verbose terminal;
##           Shift+H preview hire; Shift+F cycles fire variants; Shift+B both
## HUD: Add Agent / Kill Agent; Terminal: /jd /verbose /msg; knowledge drag-drop
##   --zoom=1.5 --focus=x,y        start the camera zoomed in on a world point
##   --focus-agent=AGENT_ID        ...or on an agent (followed until the screenshot)
##   --view=iso|top                start in the isometric or the classic top-down view
##   --fit                         open with the whole office fitted (default: main building, close up)
##
## Views: the simulation (layout, navigation, agents' bodies and paths) always
## runs in flat top-down "world" coordinates. What you see is a projection of
## it (Iso.gd): the isometric (Habbo-style 2:1) view by default, or the classic
## top-down view (identity projection). V or the header button toggles; the
## choice is saved in user://agent_office.cfg. Agent bodies live in a hidden
## layer; each has an AgentView in the y-sorted World/Agents layer at its
## projected feet that draws it and carries its name pill, bubble and click
## area.
extends Node2D

const Ansi := preload("res://ansi.gd")
const PropScript := preload("res://Prop.gd")
const Office := preload("res://Office.gd")
const Iso := preload("res://Iso.gd")
const HireFireFxScript := preload("res://HireFireFx.gd")
const KnowledgeLibraryScript := preload("res://KnowledgeLibrary.gd")
const NoticesScript := preload("res://Notices.gd")
const NoticeBoardScript := preload("res://NoticeBoard.gd")
const AgentViewScript := preload("res://AgentView.gd")
const SignTagScript := preload("res://SignTag.gd")
const SETTINGS_PATH := "user://agent_office.cfg"
## Iso: long furniture / walls are split into slices this long (world px) so
## each slice sorts correctly against people.
const SLICE_PROP := 60.0
## Camera zoom the office opens at (centred on the main building). With
## Iso.SCALE / PEOPLE_SCALE this makes people about 60 px tall on screen.
const DEFAULT_ZOOM := 0.7
const BASE_SIZE := Vector2i(1280, 800)
const SLICE_WALL := 24.0
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
var _sign_tags: Array[Node2D] = []
var _view_button: Button = null
var _add_agent_button: Button = null
var _kill_agent_button: Button = null
var _kill_mode: bool = false
var _kill_cursor_tex: Texture2D = null
const _KILL_PROTECTED_IDS: Array[String] = ["chief_of_staff"]
var _role_catalog: Array = []
var _role_categories: Array = []
var _fire_preview_variant := ""
var _knowledge_racks: Array = []
var _knowledge_library: Node = null
var _notices_store = null  ## Notices
var _notice_board: Control = null
var _meeting_active: Dictionary = {}  ## target -> {agents: PackedStringArray, text: String}
var _agent_prev_state: Dictionary = {}  ## agent_id -> last notable state
var _server_clickables: Array = []
var _human_queue: Array = []
var _meeting_panel: Control = null
var _human_dialog: Window = null
var _view_arg := ""
var _start_fit := false

# user-arg options
var _screenshot_path: String = ""
var _open_hiring_board_on_start := false
var _open_hiring_sheet_on_start := false
var _debug_activity := false
var _debug_activity_log: Array = []
var _debug_activity_started_ms := 0
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
## Hidden layer holding the agents' physics bodies (world coordinates).
var bodies_root: Node2D


func _ready() -> void:
	# Cap FPS: uncapped GL Compatibility + iso office pegged MBP ~90% CPU
	# and made the window feel dead / unresponsive.
	Engine.max_fps = 30
	# Never show navmesh / agent path debug overlays in the office window.
	NavigationServer2D.set_debug_enabled(false)
	get_viewport().physics_object_picking = true
	_setup_hidpi()
	bodies_root = Node2D.new()
	bodies_root.name = "Bodies"
	bodies_root.visible = false
	add_child(bodies_root)
	move_child(bodies_root, $World.get_index())
	_parse_user_args()
	Iso.enabled = _load_view_setting() if _view_arg == "" else _view_arg != "top"
	_add_view_button()
	_load_role_catalog()
	_add_hr_buttons()
	_setup_files_dropped()
	drawer.prompt_submitted.connect(_on_prompt_submitted)
	drawer.closed.connect(_on_drawer_closed)
	drawer.agent_requested.connect(func(id: String) -> void:
		if agents.has(id):
			_on_agent_clicked(agents[id]))
	if drawer.has_signal("archive_requested"):
		drawer.archive_requested.connect(func(id: String) -> void:
			send_json({"action": "FIRE_AGENT", "agent_id": id})
			drawer.close()
		)
	if drawer.has_signal("hire_requested"):
		drawer.hire_requested.connect(func() -> void:
			_open_hiring_board()
		)
	if drawer.has_signal("fire_preview_requested"):
		drawer.fire_preview_requested.connect(func(variant: String) -> void:
			var v := variant.strip_edges()
			if v == "":
				v = HireFireFxScript.next_preview_variant()
			_fire_preview_variant = v
			send_json({"action": "PREVIEW_HIRE_FIRE", "which": "fire", "variant": v})
			if drawer.has_method("append_system"):
				drawer.append_system("previewing fire · %s" % v)
		)
	if drawer.has_signal("hire_submit"):
		drawer.hire_submit.connect(func(hname: String, hrole: String) -> void:
			var slug := hname.to_lower().replace(" ", "_")
			var cleaned := ""
			for i in slug.length():
				var ch := slug[i]
				if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
					cleaned += ch
			if cleaned.is_empty():
				cleaned = "new_hire_%d" % Time.get_ticks_msec()
			send_json({"action": "HIRE_AGENT", "agent_id": cleaned, "name": hname, "role": hrole,
				"room": "special_projects"})
		)
	if drawer.has_signal("verbose_toggled"):
		drawer.verbose_toggled.connect(func(verbose: bool) -> void:
			send_json({"action": "SET_TERMINAL_VERBOSE", "verbose": verbose})
		)
	if drawer.has_signal("dm_requested"):
		drawer.dm_requested.connect(func(to_who: String, body: String) -> void:
			send_json({"action": "SEND_DM", "to": to_who, "text": body, "from": "paul"})
		)
	if drawer.has_signal("job_description_requested"):
		drawer.job_description_requested.connect(func(_aid: String = "") -> void:
			if drawer.agent:
				_view_job_description_for(drawer.agent)
		)
	if drawer.has_signal("kb_requested"):
		drawer.kb_requested.connect(func(subcmd: String, arg: String) -> void:
			if subcmd == "rm":
				send_json({"action": "REMOVE_KNOWLEDGE", "name": arg})
			else:
				send_json({"action": "LIST_KNOWLEDGE"})
				_open_knowledge_library()
		)
	if _notices_store == null:
		_notices_store = NoticesScript.new()
		_notices_store.load_from_disk()
	if drawer.has_signal("notices_requested"):
		drawer.notices_requested.connect(_on_notices_requested)
	camera.zoom_changed.connect(_apply_ui_scale)
	build_layout(Office.LEGACY_LAYOUT, true)
	_backoff = reconnect_min
	_connect_socket()
	if _open_hiring_board_on_start:
		call_deferred("_open_hiring_board")
	if _debug_activity:
		call_deferred("_start_debug_activity")
	if _screenshot_path != "":
		_take_screenshot()


func _process(delta: float) -> void:
	_poll_socket(delta)
	_update_foosball()
	if _follow_agent != "" and agents.has(_follow_agent):
		camera.position = Iso.to_screen((agents[_follow_agent] as Agent).global_position) + Vector2(0, -30 * Iso.PEOPLE_SCALE)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo:
		if _kill_mode and k.keycode == KEY_ESCAPE:
			_exit_kill_mode()
			get_viewport().set_input_as_handled()
			return
		if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:
			return
		if k.keycode == KEY_V and k.shift_pressed:
			send_json({"action": "TOGGLE_TERMINAL_VERBOSE"})
			get_viewport().set_input_as_handled()
			return
		if k.keycode == KEY_V:
			set_view_mode(not Iso.enabled)
			get_viewport().set_input_as_handled()
			return
		# Preview hire / fire pageantry (Shift+H / Shift+F), or both (Shift+B).
		if k.shift_pressed and k.keycode == KEY_H:
			send_json({"action": "PREVIEW_HIRE_FIRE", "which": "hire"})
			get_viewport().set_input_as_handled()
		elif k.shift_pressed and k.keycode == KEY_F:
			_fire_preview_variant = HireFireFxScript.next_preview_variant()
			print("[AgentOffice] preview fire variant: ", _fire_preview_variant)
			send_json({"action": "PREVIEW_HIRE_FIRE", "which": "fire", "variant": _fire_preview_variant})
			get_viewport().set_input_as_handled()
		elif k.shift_pressed and k.keycode == KEY_B:
			send_json({"action": "PREVIEW_HIRE_FIRE", "which": "both"})
			get_viewport().set_input_as_handled()



func _unhandled_input(event: InputEvent) -> void:
	if not _kill_mode:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_exit_kill_mode()
		get_viewport().set_input_as_handled()


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
	for n in waypoints_root.get_children():
		n.queue_free()
	waypoints.clear()
	_occupancy.clear()

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
	_build_visuals()
	_build_room_buttons()
	camera.set_bounds(_camera_bounds(), false)
	if _start_zoom > 0.0:
		camera.focus_on(Iso.to_screen(_start_focus) if _start_focus != Vector2.INF else _camera_bounds().get_center(), _start_zoom)
	elif _start_fit:
		camera.fit_all()
	else:
		default_view()
	_apply_ui_scale(camera.zoom.x)
	print("[AgentOffice] layout '%s': %d rooms, %d waypoints, %d props (%s view)" % [office.layout_name, office.rooms.size(), waypoints.size(), office.props.size(), "iso" if Iso.enabled else "top-down"])


## Camera limits in screen (projected) space.
func _camera_bounds() -> Rect2:
	if not Iso.enabled:
		return Rect2(office.bounds.position * Iso.SCALE, office.bounds.size * Iso.SCALE)
	return Iso.screen_aabb(office.bounds.grow(-12), Office.WALL_H_BACK + 40.0)


## (Re)creates everything drawn for the current view mode: furniture props
## (sliced in iso), iso walls, room signs and their click areas.
func _build_visuals() -> void:
	for n in props_root.get_children() + signs_root.get_children():
		n.get_parent().remove_child(n)
		n.queue_free()
	_desk_props.clear()
	_foosball_props.clear()
	_sign_tags.clear()
	for d: Dictionary in office.props:
		if not Iso.enabled:
			var p := _add_prop(d)
			_link_prop(d, p)
			continue
		match str(d.kind):
			"table", "counter", "reception", "bench":
				for sl in _slices(d.rect, SLICE_PROP):
					_add_prop(d, sl)
			"sofa":
				var r: Rect2 = d.rect
				var back := d.duplicate()
				back.kind = "sofaback"
				for sl in _slices(Rect2(r.position, Vector2(r.size.x, 12)), 54.0):
					_add_prop(back, sl)
				_add_prop(d)
				var arm := d.duplicate()
				arm.kind = "sofaarm"
				arm.rect = Rect2(r.end.x - 14, r.position.y, 14, r.size.y)
				_add_prop(arm)
			_:
				_link_prop(d, _add_prop(d))
	if Iso.enabled:
		for a: Dictionary in office.areas:
			if a.kind == "meeting":  # whiteboard on the meeting room's west wall
				var r: Rect2 = a.rect
				_add_prop({"kind": "whiteboard", "rect": Rect2(r.position.x + 2, r.get_center().y - 70, 6, 120)})
		for cb: Dictionary in office.chair_backs:
			var pos: Vector2 = cb.pos
			_add_prop({"kind": "chairback", "rect": Rect2(pos.x - 13, pos.y - 16, 26, 22), "pos": pos})
		for w: Dictionary in office.iso_walls():
			var d := w.duplicate()
			d.kind = "wall"
			for sl in _slices(w.rect, SLICE_WALL):
				_add_prop(d, sl)
	for id: String in _desk_props.keys():
		if agents.has(id):
			_desk_props[id].owner_agent = agents[id]
	_add_server_rack_hotspots()
	_build_signs()
	_place_notice_board()
	office.queue_redraw()


func _add_prop(d: Dictionary, slice: Rect2 = Rect2()) -> Node2D:
	var p := Node2D.new()
	p.set_script(PropScript)
	props_root.add_child(p)
	p.setup(d, slice)
	return p


func _link_prop(d: Dictionary, p: Node2D) -> void:
	if d.kind == "desk" and str(d.get("owner", "")) != "":
		_desk_props[str(d.owner)] = p
	elif d.kind == "foosball":
		_foosball_props.append(p)
	elif str(d.get("kind", "")) == "servers":
		_make_server_clickable(p)


## Splits `r` along its long axis into equal pieces no longer than `max_len`.
func _slices(r: Rect2, max_len: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var along_x := r.size.x >= r.size.y
	var length := r.size.x if along_x else r.size.y
	var n := maxi(1, ceili(length / max_len))
	var step := length / n
	for i in n:
		if along_x:
			out.append(Rect2(r.position.x + i * step, r.position.y, step, r.size.y))
		else:
			out.append(Rect2(r.position.x, r.position.y + i * step, r.size.x, step))
	return out


func _build_signs() -> void:
	if Iso.enabled:
		for s: Dictionary in office.signs:
			# Placard on a post in the room's back (north-west) corner.
			var tag := _add_sign_tag(s, Iso.to_screen((s.rect as Rect2).position + Vector2(18, 20)))
			if s.clickable:
				var room_id := str(s.room_id)
				var sname := str(s.get("name", "")).to_lower()
				if room_id == "__knowledge__" or sname.find("server") >= 0:
					tag.pressed.connect(func() -> void: _open_knowledge_library())
				else:
					tag.pressed.connect(func() -> void: open_team(room_id))
		for f: Dictionary in office.outer_frames:
			var o: Rect2 = (f.rect as Rect2).grow(Office.EXT_WALL)
			_add_sign_tag({"name": str(f.name), "style": "building"}, Iso.to_screen(o.position, Office.WALL_H_BACK + 6.0))
			if f.get("wing", false) and (f.door as Rect2).has_area():
				_add_sign_tag({"name": "Separate entrance", "style": "note"}, Iso.to_screen((f.door as Rect2).get_center() + Vector2(0, 46)))
		return
	for s: Dictionary in office.signs:
		if not s.clickable:
			continue
		var area := Area2D.new()
		area.input_pickable = true
		area.monitoring = false
		area.collision_layer = 8
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = (s.rect as Rect2).size * Iso.SCALE
		shape.shape = rect_shape
		area.position = Iso.to_screen((s.rect as Rect2).get_center())
		area.add_child(shape)
		var room_id := str(s.room_id)
		area.input_event.connect(func(_vp: Node, ev: InputEvent, _i: int) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				open_team(room_id)
				get_viewport().set_input_as_handled())
		signs_root.add_child(area)


func _add_sign_tag(s: Dictionary, anchor: Vector2) -> Node2D:
	var tag := Node2D.new()
	tag.set_script(SignTagScript)
	signs_root.add_child(tag)
	tag.setup(s, anchor)
	tag.scale = Vector2.ONE * _ui_scale_for(camera.zoom.x)
	_sign_tags.append(tag)
	return tag


# ---------------------------------------------------------------------------
# View mode (isometric / top-down)
# ---------------------------------------------------------------------------
## Switches between the isometric and the classic top-down view, keeping the
## camera on the same world spot.
func set_view_mode(iso: bool, persist: bool = true) -> void:
	if iso == Iso.enabled:
		_update_view_button()
		return
	var look_at := Iso.to_world(camera.position)
	var fitted := absf(camera.zoom.x - _fit_zoom()) < 0.01
	Iso.enabled = iso
	_build_visuals()
	for a: Agent in agents.values():
		a.sync_view()
	camera.set_bounds(_camera_bounds(), fitted)
	if not fitted:
		camera.focus_on(Iso.to_screen(look_at), camera.zoom.x)
	_apply_ui_scale(camera.zoom.x)
	_update_view_button()
	if persist:
		_save_view_setting()
	print("[AgentOffice] view: %s" % ("isometric" if iso else "top-down"))


func _fit_zoom() -> float:
	var view := get_viewport_rect().size - Vector2(0, float(camera.get("top_margin")))
	var b: Rect2 = camera.get("world_bounds")
	return clampf(minf(view.x / b.size.x, view.y / b.size.y) * 0.98, float(camera.get("min_zoom")), float(camera.get("max_zoom")))


## HiDPI (e.g. a MacBook's retina screen): the window opens at the base size
## in *points*, and canvas_items stretching renders text and art at the full
## pixel density, so nothing is drawn tiny or blurry.
func _setup_hidpi() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var screen := DisplayServer.window_get_current_screen()
	var dpi := DisplayServer.screen_get_scale(screen)
	if dpi <= 1.01:
		return
	var win := get_window()
	var want := Vector2i(Vector2(BASE_SIZE) * dpi)
	var usable := DisplayServer.screen_get_usable_rect(screen).size
	want = Vector2i(mini(want.x, int(usable.x * 0.94)), mini(want.y, int(usable.y * 0.94)))
	if win.mode == Window.MODE_WINDOWED and win.size.x < int(want.x * 0.8):
		win.size = want
		win.move_to_center()
	print("[AgentOffice] HiDPI screen (scale %.1f): window %s px" % [dpi, win.size])



func _load_role_catalog() -> void:
	_role_catalog = []
	_role_categories = []
	var path := "res://roles/catalog.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and parsed.get("roles") is Array:
		_role_catalog = parsed["roles"]
	if parsed is Dictionary and parsed.get("categories") is Array:
		_role_categories = parsed["categories"]


func _add_hr_buttons() -> void:
	# Keep HR buttons left of the expanding StatusLabel so a long roster cannot
	# push "+ Add Agent" off-screen (looked like a dead button).
	var hbox := roster.get_parent()
	var hud := $HUD as CanvasLayer
	if hud:
		hud.layer = maxi(hud.layer, 20)
	var insert_at := 2  # after Title + VSeparator
	for i in hbox.get_child_count():
		if hbox.get_child(i) == status_label:
			insert_at = i
			break
	_add_agent_button = Button.new()
	_add_agent_button.focus_mode = Control.FOCUS_NONE
	_add_agent_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_add_agent_button.add_theme_font_size_override("font_size", 12)
	_add_agent_button.text = "+ Add Agent"
	_add_agent_button.tooltip_text = "Hire from roles/catalog.json or Custom"
	var conn_err := _add_agent_button.pressed.connect(_on_add_agent_pressed)
	print("[AgentOffice] Add Agent pressed-signal connect err=%s catalog=%d" % [conn_err, _role_catalog.size()])
	hbox.add_child(_add_agent_button)
	hbox.move_child(_add_agent_button, insert_at)
	_kill_agent_button = Button.new()
	_kill_agent_button.focus_mode = Control.FOCUS_NONE
	_kill_agent_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_kill_agent_button.add_theme_font_size_override("font_size", 12)
	_kill_agent_button.text = "Kill Agent"
	_kill_agent_button.tooltip_text = "Archive an agent (random cartoon exit; soft-delete)"
	_kill_agent_button.pressed.connect(_on_kill_agent_pressed)
	hbox.add_child(_kill_agent_button)
	hbox.move_child(_kill_agent_button, insert_at + 1)


func _setup_files_dropped() -> void:
	get_window().files_dropped.connect(_on_files_dropped)


func _on_files_dropped(files: PackedStringArray) -> void:
	for path in files:
		if not str(path).to_lower().ends_with(".md"):
			continue
		send_json({"action": "ADD_KNOWLEDGE", "path": str(path)})


func _on_add_agent_pressed() -> void:
	print("[AgentOffice] Add Agent pressed — opening Hiring Board (catalog=%d)" % _role_catalog.size())
	_open_hiring_board()


func _catalog_categories() -> Array:
	if _role_categories.size() > 0:
		return _role_categories.duplicate()
	var cats: Array = []
	var seen := {}
	for role in _role_catalog:
		if not (role is Dictionary):
			continue
		var c := str(role.get("category", role.get("department", "")))
		if c != "" and not seen.has(c):
			seen[c] = true
			cats.append(c)
	return cats


func _open_hiring_board() -> void:
	_dismiss_exclusive_windows()
	# One board at a time — a second CanvasLayer board stacked silently.
	for child in get_children():
		var scr: Variant = child.get_script()
		if scr != null and str(scr.resource_path).ends_with("hiring/hiring_board.gd") and is_instance_valid(child):
			if child.has_method("close"):
				child.close()
			else:
				child.queue_free()
	var BoardScript = load("res://hiring/hiring_board.gd")
	if BoardScript == null:
		push_error("[AgentOffice] hiring/hiring_board.gd missing")
		return
	var board_node: Node = BoardScript.new()
	add_child(board_node)
	board_node.setup(_role_catalog, _catalog_categories())
	if board_node.has_method("set_hired_unique_ids"):
		board_node.set_hired_unique_ids(_hired_unique_role_ids())
	board_node.hire_requested.connect(func(role: Dictionary, overrides: Dictionary) -> void:
		var merged: Dictionary = role.duplicate(true)
		if overrides is Dictionary:
			merged.merge(overrides, true)
		_hire_from_role(merged)
	)
	var board_layer := 0
	if board_node is CanvasLayer:
		board_layer = (board_node as CanvasLayer).layer
	print("[AgentOffice] Hiring Board opened visible=%s layer=%d roles=%d" % [
		board_node.visible, board_layer, _role_catalog.size()])
	_set_status("Hiring Board open (%d roles)" % _role_catalog.size(), Color("#80cbc4"))
	if _open_hiring_sheet_on_start and _role_catalog.size() > 0:
		var first: Dictionary = _role_catalog[0]
		if board_node.has_method("open_for_role"):
			board_node.open_for_role(first)


func _prompt_custom_hire() -> void:
	_open_hiring_board()


func _send_hire(hname: String, hrole: String, room: String = "special_projects", job: Dictionary = {}, colour: String = "") -> void:
	var slug := hname.to_lower().replace(" ", "_")
	var cleaned := ""
	for i in slug.length():
		var ch := slug[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
			cleaned += ch
	if cleaned.is_empty():
		cleaned = "new_hire_%d" % Time.get_ticks_msec()
	var payload := {
		"action": "HIRE_AGENT",
		"agent_id": cleaned,
		"name": hname,
		"role": hrole,
		"room": room if room != "" else "special_projects",
	}
	if not job.is_empty():
		payload["job"] = job
		if str(job.get("role_id", "")) != "":
			payload["role_id"] = str(job.get("role_id"))
	if colour != "":
		payload["color"] = colour
	send_json(payload)


func _hire_from_role(role: Dictionary) -> void:
	var short := str(role.get("short_title", role.get("title", "New Hire")))
	var full_title := str(role.get("title", short))
	var hname := str(role.get("default_name", short))
	if "…" in hname or hname.length() > 40:
		hname = short
	var purpose := str(role.get("purpose", ""))
	var full := str(role.get("full_description", ""))
	if purpose == "" and full != "":
		purpose = full.left(400)
	var job := {
		"title": full_title,
		"short_title": short,
		"role_id": str(role.get("id", "")),
		"department": str(role.get("department", role.get("category", ""))),
		"purpose": purpose,
		"responsibilities": role.get("responsibilities", []),
		"tools": role.get("tools", []),
		"tools_text": str(role.get("tools_text", "")),
		"repos": role.get("repos", ["."]),
		"reports_to": str(role.get("reports_to", "")),
		"full_description": full,
		"human_owner": str(role.get("human_owner", "")),
		"outputs_and_cadence": str(role.get("outputs_and_cadence", "")),
		"decision_rights": str(role.get("decision_rights", "")),
		"capabilities_and_tests": str(role.get("capabilities_and_tests", "")),
		"performance_measures": str(role.get("performance_measures", "")),
		"handoffs_and_workflow": str(role.get("handoffs_and_workflow", "")),
	}
	_send_hire(hname, short, str(role.get("room", "special_projects")), job, str(role.get("color", "")))


func _view_job_description_for(agent: Agent) -> void:
	if agent == null:
		return
	var role := {
		"title": str(agent.job.get("title", agent.role)),
		"department": str(agent.job.get("department", "")),
		"category": str(agent.job.get("department", "")),
		"room": agent.room_id,
		"color": "#90a4ae",
		"summary": str(agent.job.get("purpose", "")).left(120),
		"purpose": str(agent.job.get("purpose", "")),
		"responsibilities": agent.job.get("responsibilities", []),
		"tools_text": str(agent.job.get("tools_text", "")),
		"reports_to": str(agent.job.get("reports_to", "")),
		"full_description": str(agent.job.get("full_description", "")),
		"outputs_and_cadence": str(agent.job.get("outputs_and_cadence", "")),
		"decision_rights": str(agent.job.get("decision_rights", "")),
		"human_owner": str(agent.job.get("human_owner", "")),
	}
	if agent.get("body_color") != null:
		role["color"] = "#%s" % agent.body_color.to_html(false)
	if str(role.get("full_description", "")) == "":
		var lines: PackedStringArray = []
		lines.append("### %s" % role["title"])
		lines.append("")
		if str(role["purpose"]) != "":
			lines.append("**Purpose and scope** — %s" % role["purpose"])
			lines.append("")
		var resp: Array = role.get("responsibilities", [])
		if resp is Array and not resp.is_empty():
			lines.append("**Key responsibilities**")
			for item in resp:
				lines.append("- %s" % str(item))
			lines.append("")
		if str(role.get("tools_text", "")) != "":
			lines.append("**Tools, data and access** — %s" % role["tools_text"])
		role["full_description"] = "\n".join(lines)
	var BoardScript = load("res://hiring/hiring_board.gd")
	if BoardScript == null:
		push_error("[AgentOffice] hiring/hiring_board.gd missing")
		return
	var board_node: Node = BoardScript.new()
	add_child(board_node)
	board_node.setup(_role_catalog, _catalog_categories())
	board_node.open_for_role(role)


func _dismiss_exclusive_windows() -> void:
	# Hiring Board JD sheets set exclusive=true; a second exclusive Window
	# fails with "another exclusive child window is already" and eats input.
	for child in get_children():
		if child is Window and is_instance_valid(child) and child.visible and child.exclusive:
			child.exclusive = false
			child.hide()
			child.queue_free()


func _ensure_kill_cursor() -> void:
	if _kill_cursor_tex != null:
		return
	var path := "res://assets/cursor_kill.png"
	if ResourceLoader.exists(path):
		_kill_cursor_tex = load(path) as Texture2D
	else:
		# Procedural fallback: red crossed circle.
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		var red := Color(0.86, 0.16, 0.16, 1)
		for a in range(360):
			var rad := deg_to_rad(float(a))
			for rr in range(20, 24):
				var x := 32 + int(cos(rad) * rr)
				var y := 32 + int(sin(rad) * rr)
				if x >= 0 and y >= 0 and x < 64 and y < 64:
					img.set_pixel(x, y, red)
		for i in range(-16, 17):
			for w in range(-2, 3):
				var x1 := 32 + i
				var y1 := 32 + i + w
				var x2 := 32 + i
				var y2 := 32 - i + w
				if x1 >= 0 and x1 < 64 and y1 >= 0 and y1 < 64:
					img.set_pixel(x1, y1, red)
				if x2 >= 0 and x2 < 64 and y2 >= 0 and y2 < 64:
					img.set_pixel(x2, y2, red)
		_kill_cursor_tex = ImageTexture.create_from_image(img)


func _enter_kill_mode() -> void:
	_dismiss_exclusive_windows()
	_kill_mode = true
	_ensure_kill_cursor()
	if _kill_cursor_tex:
		Input.set_custom_mouse_cursor(_kill_cursor_tex, Input.CURSOR_ARROW, Vector2(32, 32))
	if _kill_agent_button:
		_kill_agent_button.text = "Cancel Kill"
		_kill_agent_button.modulate = Color(1.0, 0.55, 0.55)
	for id in agents.keys():
		var ag: Agent = agents[id]
		if is_instance_valid(ag) and ag.has_method("set_kill_mode_active"):
			ag.set_kill_mode_active(true)
	_set_status("Kill mode — click an agent. Esc / right-click cancels.", Color("#ef9a9a"))


func _exit_kill_mode() -> void:
	if not _kill_mode:
		return
	_kill_mode = false
	Input.set_custom_mouse_cursor(null)
	if _kill_agent_button:
		_kill_agent_button.text = "Kill Agent"
		_kill_agent_button.modulate = Color.WHITE
	for id in agents.keys():
		var ag: Agent = agents[id]
		if is_instance_valid(ag) and ag.has_method("set_kill_mode_active"):
			ag.set_kill_mode_active(false)
	_set_status("Kill mode cancelled", Color("#b0bec5"))


func _on_kill_agent_pressed() -> void:
	if _kill_mode:
		_exit_kill_mode()
		return
	var any := false
	for id in agents.keys():
		if is_instance_valid(agents[id]):
			any = true
			break
	if not any:
		_set_status("No agents to archive", Color("#ef9a9a"))
		return
	_enter_kill_mode()


func _confirm_and_fire(agent: Agent) -> void:
	var aid := agent.agent_id
	var confirm := ConfirmationDialog.new()
	confirm.title = "Archive Chief of Staff?"
	confirm.dialog_text = "Archive %s? This is a protected executive role." % agent.display_name
	confirm.ok_button_text = "Archive"
	confirm.exclusive = true
	add_child(confirm)
	confirm.confirmed.connect(func() -> void:
		_do_fire_agent(aid)
		confirm.exclusive = false
		confirm.queue_free()
	)
	confirm.canceled.connect(func() -> void:
		confirm.exclusive = false
		confirm.queue_free()
		_enter_kill_mode()
	)
	confirm.close_requested.connect(func() -> void:
		confirm.exclusive = false
		confirm.queue_free()
		_enter_kill_mode()
	)
	confirm.popup_centered()


func _do_fire_agent(aid: String) -> void:
	send_json({"action": "FIRE_AGENT", "agent_id": aid, "force": true})
	if drawer.agent and drawer.agent.agent_id == aid:
		drawer.close()
	_set_status("Archiving %s…" % aid, Color("#ffd54f"))



func _hired_unique_role_ids() -> Dictionary:
	var out: Dictionary = {}
	var catalog: Array = _role_catalog
	var titles_live: Dictionary = {}
	var role_ids_live: Dictionary = {}
	for id in agents.keys():
		var ag: Agent = agents[id]
		if not is_instance_valid(ag):
			continue
		titles_live[str(ag.role)] = true
		titles_live[str(ag.display_name)] = true
		var j: Dictionary = ag.job
		titles_live[str(j.get("short_title", ""))] = true
		titles_live[str(j.get("title", ""))] = true
		var rid := str(j.get("role_id", ""))
		if rid != "":
			role_ids_live[rid] = true
	for role in catalog:
		if not (role is Dictionary):
			continue
		if not bool(role.get("unique", false)):
			continue
		var st := str(role.get("short_title", ""))
		var ft := str(role.get("title", ""))
		var dn := str(role.get("default_name", ""))
		var rid := str(role.get("id", ""))
		if titles_live.has(st) or titles_live.has(ft) or titles_live.has(dn) or role_ids_live.has(rid):
			out[rid] = true
	return out


func _on_knowledge_added(msg: Dictionary) -> void:
	var title := str(msg.get("title", msg.get("filename", "doc")))
	var fname := str(msg.get("filename", msg.get("name", title)))
	_set_status("Knowledge added: %s → Server Room" % title, Color("#29b6f6"))
	_notice("knowledge_add", "Knowledge + %s" % title, "Server Room",
		{"icon": "📄", "color": "#29b6f6", "meta": {"filename": fname}})
	# Visual: flash a knowledge slate onto the Server Room rack (screen space).
	var rack_name := str(msg.get("rack", "Server_Rack_1"))
	var world := Vector2(720, 520)
	if waypoints.has(rack_name) and waypoints[rack_name] is Node2D:
		world = (waypoints[rack_name] as Node2D).global_position
	elif waypoints.has("Server_Room") and waypoints["Server_Room"] is Node2D:
		world = (waypoints["Server_Room"] as Node2D).global_position
	var pos := Iso.to_screen(world)
	var slate := ColorRect.new()
	slate.mouse_filter = Control.MOUSE_FILTER_STOP  # small rack chip only
	slate.size = Vector2(28, 36)
	slate.position = pos + Vector2(-14, -48)
	slate.color = Color("#26a69a")
	slate.z_index = 40
	slate.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_open_knowledge_library()
	)
	add_child(slate)
	_knowledge_racks.append({"node": slate, "title": title, "path": str(msg.get("path", "")), "name": fname})
	var label := Label.new()
	label.text = title.left(12)
	label.add_theme_font_size_override("font_size", 9)
	label.position = Vector2(0, 38)
	slate.add_child(label)
	var tw := create_tween()
	tw.tween_property(slate, "modulate", Color(1.4, 1.4, 1.4, 1.0), 0.25)
	tw.tween_property(slate, "modulate", Color(1, 1, 1, 1), 0.4)
	if _knowledge_library and is_instance_valid(_knowledge_library):
		send_json({"action": "LIST_KNOWLEDGE"})


func _on_knowledge_list(msg: Dictionary) -> void:
	var files: Array = msg.get("files", [])
	if not (files is Array):
		files = []
	if drawer and drawer.has_method("append_system"):
		if files.is_empty():
			drawer.append_system("knowledge/: (empty)")
		else:
			drawer.append_system("knowledge/ (%d):" % files.size())
			for f in files:
				if not (f is Dictionary):
					continue
				var nm := str(f.get("name", "?"))
				var sz := int(f.get("size", 0))
				drawer.append_system("  · %s (%d B)" % [nm, sz])
	# Only refresh an already-open panel. Auto-spawning here left a layer-66
	# full-rect dim (mouse_filter STOP) that ate HUD clicks including Add Agent.
	if _knowledge_library and is_instance_valid(_knowledge_library):
		_knowledge_library.set_files(files)


func _on_knowledge_removed(msg: Dictionary) -> void:
	var title := str(msg.get("title", msg.get("filename", "doc")))
	var fname := str(msg.get("filename", msg.get("name", "")))
	_set_status("Knowledge removed: %s" % title, Color("#ef9a9a"))
	_notice("knowledge_remove", "Knowledge − %s" % title, "removed from Server Room",
		{"icon": "🗑", "color": "#ef9a9a", "meta": {"filename": fname}})
	if drawer and drawer.has_method("append_system"):
		drawer.append_system("knowledge: removed %s" % (fname if fname != "" else title))
	var kept: Array = []
	for entry in _knowledge_racks:
		var ename := str(entry.get("name", entry.get("title", "")))
		if ename == fname or str(entry.get("title", "")) == title:
			var n: Node = entry.get("node")
			if n and is_instance_valid(n):
				n.queue_free()
		else:
			kept.append(entry)
	_knowledge_racks = kept
	_play_server_spark()
	var files: Array = msg.get("files", [])
	if _knowledge_library and is_instance_valid(_knowledge_library):
		if files is Array:
			_knowledge_library.set_files(files)
		else:
			send_json({"action": "LIST_KNOWLEDGE"})


func _open_knowledge_library() -> void:
	_dismiss_exclusive_windows()
	send_json({"action": "LIST_KNOWLEDGE"})
	if _knowledge_library and is_instance_valid(_knowledge_library):
		return
	_spawn_knowledge_library([])


func _spawn_knowledge_library(files: Array) -> void:
	if _knowledge_library and is_instance_valid(_knowledge_library):
		_knowledge_library.set_files(files)
		return
	var lib: Node = KnowledgeLibraryScript.new()
	add_child(lib)
	_knowledge_library = lib
	lib.closed.connect(func() -> void:
		if _knowledge_library == lib:
			_knowledge_library = null
	)
	lib.remove_requested.connect(func(filename: String) -> void:
		send_json({"action": "REMOVE_KNOWLEDGE", "name": filename})
	)
	lib.refresh_requested.connect(func() -> void:
		send_json({"action": "LIST_KNOWLEDGE"})
	)
	lib.open_with(files)


func _make_server_clickable(prop: Node2D) -> void:
	var area := Area2D.new()
	area.name = "KnowledgeHotspot"
	area.input_pickable = true
	area.monitoring = false
	area.collision_layer = 8
	var shape := CollisionShape2D.new()
	var rect_shape := RectangleShape2D.new()
	rect_shape.size = Vector2(64, 100)
	shape.shape = rect_shape
	shape.position = Vector2(0, -20)
	area.add_child(shape)
	area.input_event.connect(func(_vp: Node, ev: InputEvent, _i: int) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_open_knowledge_library()
			get_viewport().set_input_as_handled()
	)
	prop.add_child(area)
	_server_clickables.append(area)


func _add_server_rack_hotspots() -> void:
	for rack_name in ["Server_Rack_1", "Server_Rack_2", "Server_Room"]:
		if not waypoints.has(rack_name):
			continue
		var m: Node2D = waypoints[rack_name]
		if m == null:
			continue
		var holder := Node2D.new()
		holder.name = "KnowledgeHotspotHolder_%s" % rack_name
		holder.position = Iso.to_screen(m.global_position)
		holder.z_index = 30
		signs_root.add_child(holder)
		var area := Area2D.new()
		area.name = "KnowledgeHotspot"
		area.input_pickable = true
		area.monitoring = false
		area.collision_layer = 8
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = Vector2(70, 90)
		shape.shape = rect_shape
		area.add_child(shape)
		holder.add_child(area)
		area.input_event.connect(func(_vp: Node, ev: InputEvent, _i: int) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_open_knowledge_library()
				get_viewport().set_input_as_handled()
		)
		_server_clickables.append(area)


func _play_server_spark() -> void:
	var world := Vector2(720, 520)
	if waypoints.has("Server_Rack_1") and waypoints["Server_Rack_1"] is Node2D:
		world = (waypoints["Server_Rack_1"] as Node2D).global_position
	elif waypoints.has("Server_Room") and waypoints["Server_Room"] is Node2D:
		world = (waypoints["Server_Room"] as Node2D).global_position
	var pos := Iso.to_screen(world)
	var spark := Node2D.new()
	spark.z_index = 55
	spark.position = pos
	add_child(spark)
	var bits: Array = []
	for i in 16:
		bits.append({
			"p": Vector2(randf_range(-10, 10), randf_range(-24, 0)),
			"v": Vector2(randf_range(-90, 90), randf_range(-160, -40)),
			"life": randf_range(0.35, 0.9),
			"c": Color(0.35, 1.0, 0.85, 1.0) if i % 2 == 0 else Color(0.7, 1.0, 0.4, 1.0),
		})
	spark.set_meta("bits", bits)
	var acc := {"t": 0.0}
	var tw := create_tween()
	tw.set_loops(24)
	tw.tween_callback(func() -> void:
		if not is_instance_valid(spark):
			return
		var dt := 0.045
		acc["t"] += dt
		var bits2: Array = spark.get_meta("bits")
		for b in bits2:
			b["p"] = b["p"] + b["v"] * dt
			b["v"] = b["v"] + Vector2(0, 220) * dt
			b["life"] = float(b["life"]) - dt
		for child in spark.get_children():
			child.queue_free()
		for b in bits2:
			if float(b["life"]) <= 0.0:
				continue
			var dot := ColorRect.new()
			dot.size = Vector2(3, 3)
			dot.position = b["p"]
			var c: Color = b["c"]
			c.a = clampf(float(b["life"]), 0.0, 1.0)
			dot.color = c
			spark.add_child(dot)
		if acc["t"] > 1.05:
			spark.queue_free()
	)
	tw.tween_interval(0.045)


func _on_agent_dm(msg: Dictionary) -> void:
	var to_id := str(msg.get("to", ""))
	var agent: Agent = agents.get(to_id)
	if agent == null:
		return
	agent.pending_notes.append(msg)
	agent.show_bubble("✉ " + str(msg.get("text", "")).left(40), false)


func _on_ask_human(msg: Dictionary) -> void:
	_human_queue.append(msg)
	var aname := str(msg.get("agent_name", msg.get("agent_id", "agent")))
	var prompt := str(msg.get("prompt", msg.get("text", ""))).left(100)
	_notice("ask_human", "We need to talk — %s" % aname, prompt,
		{"icon": "!", "color": "#ffb74d", "pending": true,
		 "meta": {"agent_id": str(msg.get("agent_id", "")),
				 "request_id": str(msg.get("request_id", ""))}})
	var aid := str(msg.get("agent_id", ""))
	var agent: Agent = agents.get(aid)
	if agent:
		agent.show_bubble("We need to talk", false)
		var meet := _meeting_target_for(agent)
		_route(agent, meet)
	_set_status("Agent needs you (%d waiting)" % _human_queue.size(), Color("#ffb74d"))
	_show_next_human_prompt()


func _show_next_human_prompt() -> void:
	if _human_queue.is_empty():
		return
	if _human_dialog and is_instance_valid(_human_dialog):
		return
	var msg: Dictionary = _human_queue[0]
	var win := Window.new()
	win.title = "We need to talk — %s" % str(msg.get("agent_name", msg.get("agent_id", "agent")))
	win.size = Vector2i(520, 360)
	var vbox := VBoxContainer.new()
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.text = str(msg.get("prompt", msg.get("text", "")))
	body.custom_minimum_size = Vector2(480, 160)
	vbox.add_child(body)
	var choices: Variant = msg.get("choices", [])
	var reply_edit := TextEdit.new()
	reply_edit.custom_minimum_size = Vector2(480, 80)
	reply_edit.placeholder_text = "Your reply…"
	if choices is Array and not choices.is_empty():
		var hb := HBoxContainer.new()
		for c in choices:
			var b := Button.new()
			b.text = str(c)
			var choice_text := str(c)
			b.pressed.connect(func() -> void:
				_submit_human_reply(str(msg.get("agent_id", "")), choice_text, str(msg.get("request_id", "")))
				win.queue_free()
				_human_dialog = null
			)
			hb.add_child(b)
		vbox.add_child(hb)
	vbox.add_child(reply_edit)
	var send := Button.new()
	send.text = "Send reply"
	send.pressed.connect(func() -> void:
		_submit_human_reply(str(msg.get("agent_id", "")), reply_edit.text.strip_edges(), str(msg.get("request_id", "")))
		win.queue_free()
		_human_dialog = null
	)
	vbox.add_child(send)
	win.add_child(vbox)
	add_child(win)
	_human_dialog = win
	win.close_requested.connect(func() -> void:
		win.queue_free()
		_human_dialog = null
	)
	win.popup_centered()


func _submit_human_reply(agent_id: String, text: String, request_id: String) -> void:
	if text == "":
		return
	send_json({"action": "HUMAN_REPLY", "agent_id": agent_id, "text": text, "request_id": request_id})
	if _notices_store:
		if request_id:
			_notices_store.resolve_ask(request_id)
		else:
			_notices_store.resolve_all_pending_asks_for(agent_id)
	if not _human_queue.is_empty():
		_human_queue.pop_front()
	_show_next_human_prompt()


func _on_meeting_turn(msg: Dictionary) -> void:
	var who := str(msg.get("agent_id", ""))
	var text := str(msg.get("text", ""))
	var agent: Agent = agents.get(who)
	if agent:
		agent.show_bubble(text.left(60), false)
	_set_status("Meeting: %s" % text.left(50), Color("#ce93d8"))


func _add_view_button() -> void:
	_view_button = Button.new()
	_view_button.focus_mode = Control.FOCUS_NONE
	_view_button.add_theme_font_size_override("font_size", 12)
	_view_button.tooltip_text = "Toggle isometric / top-down view (V)"
	_view_button.pressed.connect(func() -> void: set_view_mode(not Iso.enabled))
	var hbox := roster.get_parent()
	hbox.add_child(_view_button)
	hbox.move_child(_view_button, roster.get_index())
	_update_view_button()


func _update_view_button() -> void:
	if _view_button:
		_view_button.text = "◇ 3D view" if not Iso.enabled else "▦ Top view"


func _load_view_setting() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return true
	return str(cfg.get_value("view", "mode", "iso")) != "top"


func _save_view_setting() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("view", "mode", "iso" if Iso.enabled else "top")
	cfg.save(SETTINGS_PATH)


## Builds the NavigationPolygon from the generated floor minus walls and furniture.
func _bake_navigation() -> void:
	var poly := NavigationPolygon.new()
	poly.agent_radius = nav_agent_radius
	var source := NavigationMeshSourceGeometryData2D.new()
	for floor_poly: PackedVector2Array in office.get_floor_outlines():
		source.add_traversable_outline(floor_poly)
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
		b.tooltip_text = "Jump to the room and show the team summary"
		b.pressed.connect(func() -> void:
			focus_room(rid)
			open_team(rid))
		roster.add_child(b)
		_room_buttons.append(b)


## Opening view: the hub campus at a comfortable zoom (F fits everything).
func default_view() -> void:
	var main_rect: Rect2 = office.outer_frames[0].rect if not office.outer_frames.is_empty() else office.bounds
	# Prefer the hub centre when present; otherwise the first outer frame.
	for f: Dictionary in office.outer_frames:
		if bool(f.get("hub", false)):
			main_rect = f.rect
			break
	var focus := main_rect.get_center()
	camera.focus_on(Iso.to_screen(focus) + Vector2(0, -20), DEFAULT_ZOOM)


## Moves the camera onto a room (left of where the drawer opens).
func focus_room(room_id: String) -> void:
	for a: Dictionary in office.areas:
		if str(a.get("id", "")) == room_id:
			var box := Iso.screen_aabb(a.rect, Office.WALL_H_BACK)
			var view := get_viewport_rect().size - Vector2(drawer.panel_width + 40.0, float(camera.get("top_margin")) + 30.0)
			var z := clampf(minf(view.x / box.size.x, view.y / box.size.y), 0.45, 1.1)
			camera.focus_on(box.get_center() + Vector2((drawer.panel_width * 0.5) / z, -12.0 / z), z)
			return


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



func _place_notice_board() -> void:
	## Compact draggable HUD panel (defaults bottom-left). No walkmesh / door / hex changes.
	if _notice_board and is_instance_valid(_notice_board):
		_notice_board.queue_free()
		_notice_board = null
	if _notices_store == null:
		_notices_store = NoticesScript.new()
		_notices_store.load_from_disk()
	var hud := $HUD as CanvasLayer
	if hud == null:
		return
	var board: Control = NoticeBoardScript.new()
	hud.add_child(board)
	board.setup(_notices_store)
	if board.has_signal("open_requested"):
		board.open_requested.connect(func() -> void: pass)
	_notice_board = board


func _notice(kind: String, title: String, detail: String = "", opts: Dictionary = {}) -> void:
	if _notices_store == null:
		_notices_store = NoticesScript.new()
		_notices_store.load_from_disk()
	_notices_store.add(kind, title, detail, opts)


func _on_notices_requested() -> void:
	if _notices_store == null:
		_notices_store = NoticesScript.new()
		_notices_store.load_from_disk()
	var pins: Array = _notices_store.latest(12)
	if pins.is_empty():
		if drawer and drawer.has_method("append_system"):
			drawer.append_system("notices: (none yet)")
	else:
		if drawer and drawer.has_method("append_system"):
			drawer.append_system("notices: latest %d (of %d)" % [pins.size(), _notices_store.events.size()])
			for e in pins:
				var tstr: String = str(_notices_store.format_time(float(e.get("ts", 0))))
				var pending := " [OPEN]" if bool(e.get("pending", false)) else ""
				var line := "%s %s %s%s" % [tstr, str(e.get("icon", "•")), str(e.get("title", "")), pending]
				var detail := str(e.get("detail", ""))
				if detail:
					line += " — %s" % detail
				drawer.append_system(line, str(e.get("color", "#7f848e")))
	if _notice_board and is_instance_valid(_notice_board) and _notice_board.has_method("open_full_list"):
		_notice_board.open_full_list()


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
				var tgt := _str_or_empty(msg.get("target"))
				_apply_state(agent, str(msg.get("state", "IDLE")), tgt, str(msg.get("text", "")))
				if _debug_activity:
					_log_debug_activity(agent, str(msg.get("state", "IDLE")), tgt)
		"LOG_ENTRY":
			var agent := _get_or_spawn(str(msg.get("agent_id", "")))
			if agent:
				agent.add_log(str(msg.get("log", "")))
		"COLLABORATE":
			_apply_collaborate(msg)
		"ACK":
			# Quiet chat ACKs stay silent; surface mode / hire / fire confirmations.
			var act := str(msg.get("action", ""))
			if act == "SET_TERMINAL_VERBOSE":
				_set_status(str(msg.get("message", "terminal mode changed")), Color("#81c784"))
				if drawer.agent:
					drawer.append_system(str(msg.get("message", "")), "#81c784")
			elif act in ["HIRE_AGENT", "FIRE_AGENT"]:
				_set_status("%s %s" % [act, str(msg.get("name", msg.get("agent_id", "")))], Color("#ffd54f"))
				if drawer.agent:
					drawer.append_system("%s: %s" % [act, str(msg.get("name", msg.get("agent_id", "")))], "#ffd54f")
		"KNOWLEDGE_ADDED":
			_on_knowledge_added(msg)
		"KNOWLEDGE_LIST":
			_on_knowledge_list(msg)
		"KNOWLEDGE_REMOVED":
			_on_knowledge_removed(msg)
		"AGENT_DM":
			_on_agent_dm(msg)
		"ASK_HUMAN":
			_on_ask_human(msg)
		"MEETING_TURN":
			_on_meeting_turn(msg)
		"AGENT_HIRE":
			_play_hire(msg)
			var hname := str(msg.get("name", msg.get("agent_id", "agent")))
			var hrole := str(msg.get("role", ""))
			_notice("hire", "Hired %s" % hname, hrole if hrole else "new agent",
				{"icon": "✦", "color": "#ffd54f", "meta": {"agent_id": str(msg.get("agent_id", ""))}})
		"AGENT_FIRE":
			var fname := str(msg.get("name", msg.get("agent_id", "agent")))
			var variant := str(msg.get("variant", _fire_preview_variant))
			var how := NoticesScript.fire_variant_label(variant)
			var ficon := "🚑" if how == "ambulance" else ("🛸" if how == "UFO" else "☠")
			_notice("fire", "Killed %s" % fname, "via %s" % how,
				{"icon": ficon, "color": "#ef5350",
				 "meta": {"agent_id": str(msg.get("agent_id", "")), "variant": variant}})
			_play_fire(msg)
		"INBOX":
			var agent := _get_or_spawn(str(msg.get("agent_id", "")))
			if agent:
				agent.unread = maxi(0, int(msg.get("unread", 0)))
				agent.queue_redraw()
		"ERROR":
			push_warning("Harness error: %s" % str(msg.get("message", "")))
			if drawer.agent:
				drawer.append_system("harness error: %s" % str(msg.get("message", "")), "#e06c75")
			var emsg := str(msg.get("message", "error"))
			var eact := str(msg.get("action", ""))
			_notice("error", "Error%s" % ((" · " + eact) if eact else ""), emsg.left(120),
				{"icon": "⚠", "color": "#e06c75"})
		"AMBIENT":
			# Idle-life cue from the harness (no log line, nothing to do with work).
			var agent: Agent = agents.get(str(msg.get("agent_id", "")))
			if agent and str(msg.get("action", "")) == "phone":
				agent.glance_phone(float(msg.get("seconds", 4.0)), false)
		"OPEN_HIRING_BOARD":
			print("[AgentOffice] harness OPEN_HIRING_BOARD — simulating Add Agent")
			_on_add_agent_pressed()
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
		agent.unread = maxi(0, int(data.get("unread", 0)))
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
		focus_room(_open_team_for)  # same as the header room button
		open_team(_open_team_for)
		_open_team_for = ""
	if not _pending_dispatch.is_empty():
		send_json(_pending_dispatch)
		_pending_dispatch = {}


func _apply_state(agent: Agent, state: String, target: String, text: String) -> void:
	var prev := str(_agent_prev_state.get(agent.agent_id, ""))
	var st := state.to_upper()
	agent.set_state(state)
	if not target.is_empty():
		_route(agent, target)
	elif st in ["THINKING", "WORKING", "ERROR"] and agent.is_away_from_desk():
		agent.glance_phone(4.0)  # an update while away from the desk: check the phone
	if not text.is_empty():
		agent.show_bubble(Ansi.strip(text), st == "THINKING")
	# Notice board: task outcomes (skip idle chatter / ambient moves).
	if st == "ERROR":
		var fail_txt := text if text else "task failed"
		_notice("task_fail", "%s failed" % agent.display_name, fail_txt.left(100),
			{"icon": "✖", "color": "#e57373", "meta": {"agent_id": agent.agent_id}})
	elif st == "IDLE" and prev in ["WORKING", "THINKING"]:
		var low := text.to_lower()
		if "done" in low or low.begins_with("done") or "coffee" in low:
			_notice("task_ok", "%s finished" % agent.display_name, text.left(100) if text else "Done",
				{"icon": "✔", "color": "#81c784", "meta": {"agent_id": agent.agent_id}})
	# Meeting end: last collaborator leaves COLLAB.
	if prev in ["COLLAB", "COLLABORATE"] and st not in ["COLLAB", "COLLABORATE"]:
		_maybe_finish_meeting(agent)
	if st in ["WORKING", "THINKING", "ERROR", "COLLAB", "COLLABORATE", "IDLE"]:
		_agent_prev_state[agent.agent_id] = st
	drawer.on_agent_changed(agent)
	_update_counts()



func _maybe_finish_meeting(leaving: Agent) -> void:
	var still := 0
	for aid in agents.keys():
		var a: Agent = agents[aid]
		if a == null or not is_instance_valid(a) or a == leaving:
			continue
		var s := str(_agent_prev_state.get(aid, "")).to_upper()
		if s in ["COLLAB", "COLLABORATE"]:
			still += 1
	if still > 0:
		return
	var participants: PackedStringArray = []
	var topic := ""
	var key := ""
	for k in _meeting_active.keys():
		key = str(k)
		var info: Dictionary = _meeting_active[k]
		var ags: Variant = info.get("agents", [])
		if ags is PackedStringArray:
			participants = ags
		elif ags is Array:
			for n in ags:
				participants.append(str(n))
		topic = str(info.get("text", ""))
		break
	if key != "":
		_meeting_active.erase(key)
	var who := " & ".join(participants) if participants.size() > 0 else leaving.display_name
	_notice("meeting_end", "Meeting finished", ("%s · %s" % [who, topic.left(60)]).strip_edges(),
		{"icon": "✓", "color": "#b39ddb", "meta": {"agents": participants}})


func _apply_collaborate(msg: Dictionary) -> void:
	var ids: Array = msg.get("agents", [])
	var target := _str_or_empty(msg.get("target"))
	if target.is_empty():
		target = "Meeting_Room"
	var names: PackedStringArray = []
	var id_list: Array = []
	for id: Variant in ids:
		id_list.append(str(id))
		var a := _get_or_spawn(str(id))
		if a:
			names.append(a.display_name)
	var text := str(msg.get("text", ""))
	_meeting_active[target] = {"agents": names, "ids": id_list, "text": text}
	_notice("meeting_start", "Meeting started", "%s · %s" % [" & ".join(names), text.left(60)],
		{"icon": "🤝", "color": "#ce93d8", "meta": {"target": target, "agents": names}})
	for idv in id_list:
		_agent_prev_state[str(idv)] = "COLLAB"
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



func _play_hire(msg: Dictionary) -> void:
	var id := str(msg.get("agent_id", ""))
	if id.is_empty():
		return
	var agent: Agent = agents.get(id)
	if agent == null:
		agent = _spawn_agent(msg)
	var desk_name := str(msg.get("desk", agent.desk if agent else ""))
	var desk_pos := agent.global_position
	if desk_name != "" and waypoints.has(desk_name):
		desk_pos = (waypoints[desk_name] as Marker2D).global_position
		_route(agent, desk_name, true)
	var fx: Node2D = HireFireFxScript.new()
	agents_root.add_child(fx)
	fx.play_hire(agent, desk_pos)


func _play_fire(msg: Dictionary) -> void:
	var id := str(msg.get("agent_id", ""))
	var agent: Agent = agents.get(id)
	if agent == null:
		return
	# Optional delay so a hire-then-fire preview can play the beam first.
	var after_ms := int(msg.get("after_ms", 0))
	if after_ms > 0:
		var delayed := {
			"agent_id": id,
			"desk": msg.get("desk", ""),
			"room": msg.get("room", ""),
			"variant": msg.get("variant", _fire_preview_variant),
		}
		get_tree().create_timer(after_ms / 1000.0).timeout.connect(func() -> void:
			_play_fire(delayed)
		)
		return
	var entrance_name := "%s_Entrance" % agent.room_id if waypoints.has("%s_Entrance" % agent.room_id) else "Entrance"
	var entrance_pos := agent.global_position
	if waypoints.has(entrance_name):
		entrance_pos = (waypoints[entrance_name] as Marker2D).global_position
	elif waypoints.has("Entrance"):
		entrance_pos = (waypoints["Entrance"] as Marker2D).global_position
	var fx: Node2D = HireFireFxScript.new()
	agents_root.add_child(fx)
	fx.finished.connect(func(kind: String, aid: String) -> void:
		if kind == "fire":
			_remove_agent(aid)
			if _desk_props.has(aid):
				_desk_props[aid].owner_agent = null
				_desk_props[aid].queue_redraw()
	)
	var forced := str(msg.get("variant", _fire_preview_variant))
	# Focus the camera on the agent being fired (HireFireFx also zooms; this anchors us).
	if camera and camera.has_method("focus_on"):
		camera.focus_on(Iso.to_screen(agent.global_position), clampf(camera.zoom.x * 1.2, 0.45, 2.2))
	fx.play_fire(agent, entrance_pos, forced)
	_fire_preview_variant = ""


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
	if data.get("job") is Dictionary:
		agent.job = data["job"]
	elif office != null and office.agent_job.has(id):
		agent.job = office.agent_job[id]
	if not waypoints.has(desk):
		agent.desk = _break_spots_for(agent)[0]
	bodies_root.add_child(agent)
	var view := Node2D.new()
	view.set_script(AgentViewScript)
	view.agent = agent
	view.scale = Vector2.ONE * Iso.PEOPLE_SCALE
	agents_root.add_child(view)
	agent.attach_view(view)
	var entrance_name := "%s_Entrance" % agent.room_id if waypoints.has("%s_Entrance" % agent.room_id) else "Entrance"
	var entrance: Marker2D = waypoints.get(entrance_name)
	if entrance:
		agent.global_position = entrance.global_position
	agent.sync_view()
	agent.clicked.connect(_on_agent_clicked)
	agent.set_ui_scale(_ui_scale_for(camera.zoom.x) / Iso.PEOPLE_SCALE)
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
	if is_instance_valid(agent.view):
		agent.view.queue_free()
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
	if _kill_mode:
		_exit_kill_mode()
		var aid := agent.agent_id
		if aid in _KILL_PROTECTED_IDS or "chief of staff" in agent.display_name.to_lower():
			_confirm_and_fire(agent)
			return
		_do_fire_agent(aid)
		return
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
	if str(_server_info.get("mode", "")) == "live":
		# Live mode: only real reports make anyone work; everyone else is ambient.
		counts_label.text = "LIVE · %d agents · %d working · %d thinking · %d idle (ambient)" % [
			agents.size(), c.get("WORKING", 0), c.get("THINKING", 0), int(c.get("IDLE", 0)) + int(c.get("COLLAB", 0))]
	if int(c.get("ERROR", 0)) > 0:
		counts_label.text += " · %d error" % int(c.get("ERROR", 0))


## Name pills, bubbles and signs grow when zoomed out so they stay legible:
## about 1.05x their design size on screen at the default zoom, never below
## ~0.8x when zoomed right out.
func _ui_scale_for(z: float) -> float:
	return clampf(1.05 / z, 1.0, 3.2)


func _apply_ui_scale(z: float) -> void:
	var s := _ui_scale_for(z)
	for a: Agent in agents.values():
		a.set_ui_scale(s / Iso.PEOPLE_SCALE)
	for t in _sign_tags:
		if is_instance_valid(t):
			t.scale = Vector2.ONE * s


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
			"--view":
				_view_arg = value
			"--fit":
				_start_fit = true
			"--dispatch":
				var parts := value.split(":", true, 1)
				if parts.size() == 2:
					_pending_dispatch = {"action": "DISPATCH_PROMPT", "agent_id": parts[0], "prompt": parts[1]}
			"--preview-hire":
				_pending_dispatch = {"action": "PREVIEW_HIRE_FIRE", "which": "hire"}
			"--preview-fire":
				_pending_dispatch = {"action": "PREVIEW_HIRE_FIRE", "which": "fire"}
			"--preview-hire-fire":
				_pending_dispatch = {"action": "PREVIEW_HIRE_FIRE", "which": "both"}
			"--open-hiring-board":
				_open_hiring_board_on_start = true
			"--open-hiring-sheet":
				_open_hiring_board_on_start = true
				_open_hiring_sheet_on_start = true
			"--debug-activity":
				_debug_activity = true



func _start_debug_activity() -> void:
	_debug_activity_log.clear()
	_debug_activity_started_ms = Time.get_ticks_msec()
	print("[AgentOffice] debug-activity: logging walks/state for 60s")
	_debug_dump_activity_bounds()
	# Prove the HUD button signal is wired, then open the board via the same path.
	if _add_agent_button and _add_agent_button.pressed.get_connections().size() > 0:
		print("[AgentOffice] debug-activity: Add Agent connections=%d rect=%s" % [
			_add_agent_button.pressed.get_connections().size(), _add_agent_button.get_global_rect()])
		_add_agent_button.pressed.emit()
	else:
		push_error("[AgentOffice] debug-activity: Add Agent button missing or unconnected")
		_on_add_agent_pressed()
	await get_tree().create_timer(2.0).timeout
	var board_open := false
	for child in get_children():
		var scr: Variant = child.get_script()
		if scr != null and str(scr.resource_path).ends_with("hiring/hiring_board.gd") and is_instance_valid(child):
			board_open = child.visible
			print("[AgentOffice] debug-activity: hiring board child visible=%s" % child.visible)
	print("[AgentOffice] debug-activity: hiring_board_visible=%s" % board_open)
	await get_tree().create_timer(58.0).timeout
	_flush_debug_activity()



func _room_kind_match(expect: String, got: String) -> bool:
	if expect == got:
		return true
	# Desk/team cells are authored as kind "room" (hex) or "wing" (corridor).
	if expect in ["team", "room", "wing"] and got in ["team", "room", "wing"]:
		return true
	return false


## Expected amenity room kind for a waypoint name (live hex hub zones).
func _activity_expected_kind(wp_name: String) -> String:
	if wp_name.begins_with("Yoga_Mat") or wp_name.begins_with("Meditation_Cushion") or wp_name.begins_with("Chat_Rec"):
		return "rec"
	if wp_name.begins_with("Foosball") or wp_name in ["Coffee_Machine", "Water_Cooler", "Vending_Machine"] \
			or wp_name.begins_with("Sofa_") or wp_name.begins_with("Chat_Break"):
		return "break"
	if wp_name.begins_with("Canteen_") or wp_name.begins_with("Chat_Canteen"):
		return "canteen"
	if wp_name.begins_with("Meeting_") or wp_name == "Meeting_Room":
		return "meeting"
	if wp_name.begins_with("Server_"):
		return "server"
	if wp_name.begins_with("Desk_"):
		return "room"  # Office.gd uses kind "room" (wings use "wing")
	return ""


func _area_kind_at(pos: Vector2) -> String:
	var best := ""
	var best_area := INF
	for a: Dictionary in office.areas:
		var rect: Rect2 = a.rect
		if rect.has_point(pos):
			var kind := str(a.get("kind", ""))
			# Prefer specific amenity zones over the encompassing hub.
			if kind == "hub":
				continue
			var area := rect.get_area()
			if area < best_area:
				best_area = area
				best = kind
	return best


func _debug_dump_activity_bounds() -> void:
	var names := [
		"Coffee_Machine", "Water_Cooler", "Vending_Machine", "Sofa_1", "Sofa_2",
		"Foosball_1", "Foosball_2", "Foosball_3", "Foosball_4",
		"Canteen_Counter", "Canteen_Seat_1", "Canteen_Seat_2", "Canteen_Seat_3",
		"Canteen_Seat_4", "Canteen_Seat_5", "Canteen_Seat_6",
		"Yoga_Mat_1", "Yoga_Mat_2", "Meditation_Cushion_1", "Meditation_Cushion_2",
	]
	var bad := 0
	for n in names:
		if not waypoints.has(n):
			print("[AgentOffice] activity-bounds MISSING wp=%s" % n)
			bad += 1
			continue
		var pos: Vector2 = (waypoints[n] as Node2D).global_position
		var expect := _activity_expected_kind(n)
		var got := _area_kind_at(pos)
		var ok := expect == "" or _room_kind_match(expect, got)
		if not ok:
			bad += 1
		print("[AgentOffice] activity-bounds wp=%s pos=(%.1f,%.1f) expect=%s got=%s %s" % [
			n, pos.x, pos.y, expect, got, "OK" if ok else "OUTSIDE"])
	print("[AgentOffice] activity-bounds summary bad=%d / %d" % [bad, names.size()])


func _log_debug_activity(agent: Agent, state: String, target: String) -> void:
	var elapsed := (Time.get_ticks_msec() - _debug_activity_started_ms) / 1000.0
	var desk := agent.desk
	var away := target != "" and target != desk
	var wp := target if target != "" else agent.current_waypoint
	var expect := _activity_expected_kind(wp)
	var got := _area_kind_at(agent.global_position)
	var in_room := expect == "" or _room_kind_match(expect, got) or agent.is_at_destination() == false
	# When settled on an amenity, require the agent to be inside the amenity room.
	if expect != "" and agent.is_at_destination():
		in_room = _room_kind_match(expect, got)
	var entry := {
		"t": snappedf(elapsed, 0.1),
		"id": agent.agent_id,
		"state": state,
		"target": target,
		"wp": agent.current_waypoint,
		"pos": [snappedf(agent.global_position.x, 0.1), snappedf(agent.global_position.y, 0.1)],
		"nav": not agent.is_at_destination(),
		"away": away,
		"expect_room": expect,
		"got_room": got,
		"in_room": in_room,
	}
	_debug_activity_log.append(entry)
	if away or state in ["IDLE", "COLLAB"]:
		print("[AgentOffice] walk/state t=%.1f %s %s -> %s nav=%s room=%s/%s %s" % [
			elapsed, agent.agent_id, state, wp, entry["nav"], expect, got,
			"OK" if in_room else "WRONG_ROOM"])


func _flush_debug_activity() -> void:
	var walks: Array = []
	var wrong: Array = []
	for e in _debug_activity_log:
		if e.get("away", false):
			walks.append(e)
		if e.get("expect_room", "") != "" and e.get("nav") == false and not e.get("in_room", true):
			wrong.append(e)
	print("[AgentOffice] debug-activity DONE entries=%d walks=%d wrong_room=%d" % [
		_debug_activity_log.size(), walks.size(), wrong.size()])
	for e in walks:
		print("[AgentOffice] WALK %s" % e)
	for e in wrong:
		print("[AgentOffice] WRONG_ROOM %s" % e)
	_debug_dump_activity_bounds()
	var out := OS.get_environment("HOME") + "/Documents/GitHub/_agent_extracts/godot_activity_60s.json"
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"entries": _debug_activity_log,
			"walks": walks,
			"wrong_room": wrong,
		}, "\t"))
		f.close()
		print("[AgentOffice] wrote %s" % out)


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
