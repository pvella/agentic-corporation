## Office floor plan: builds a layout (rooms, walls, furniture, waypoints,
## signs) from an OFFICE_LAYOUT config and draws the flat parts of it (floors,
## rugs, walls, signs). Furniture that agents can stand behind is drawn by
## y-sorted Prop nodes that Main creates from `props`.
##
## Layout: hexagonal hub-and-spoke campus. The centre hub holds the Break Room,
## Canteen and Rec Room as open zones. Department offices plus the Meeting Room
## and Server Room sit as satellites on an elliptical (landscape / ~16:9) ring,
## each joined to the hub by a short corridor. The Executive (Chief of Staff)
## satellite is larger and sits prominently on the south arc. Rooms marked
## "isolated" remain a separate walled wing to the right.
##
## Waypoint naming (shared with agent_harness.py):
##   Desk_<agent_id> (or the member's "desk"), Coffee_Machine, Water_Cooler,
##   Vending_Machine, Sofa_1/2, Foosball_1..4, Canteen_Counter, Canteen_Seat_1..6,
##   Yoga_Mat_1/2, Meditation_Cushion_1/2 (Rec Room),
##   Meeting_Table_1..N, Entrance;
##   isolated room <id>: <id>_Coffee, <id>_Water, <id>_Sofa_1/2,
##   <id>_Meeting_1..4, <id>_Entrance.
##   Chat spots (small talk, 3 slots facing each other, _1 west / _2 east /
##   _3 north): Chat_Break, Chat_Corridor, Chat_<room id> for every team room,
##   <id>_Chat inside an isolated wing.
##   Virtual targets: Meeting_Room and <id>_Meeting_Room (resolved to seats).
extends Node2D

const Iso := preload("res://Iso.gd")
const WALL := 12.0
const EXT_WALL := 14.0
const CORRIDOR := 96.0
const CELL := Vector2(176, 162)   ## one desk + chair + aisle
const PAD_X := 26.0
const ROOM_TOP := 68.0            ## space above the first desk row (sign, plant)
const ROOM_BOTTOM := 84.0         ## open floor below the last desk row (chat spot)
const DOOR := 84.0
const WING_GAP := 34.0
const AMENITY_W := 176.0
const ORIGIN := Vector2(40, 40)
## Isometric wall heights (screen px): tall back walls (north / west of each
## building), medium interior walls, low front walls so the rooms stay visible.
const WALL_H_BACK := 66.0
const WALL_H_INNER := 30.0
const WALL_H_FRONT := 10.0

## The layout used when the harness sends no OFFICE_LAYOUT (legacy 3 agents).
const LEGACY_LAYOUT := {
	"name": "Agent Office",
	"rooms": [{
		"id": "team", "name": "Team", "color": "#4fc3f7", "theme": "wood", "desks": 3, "isolated": false,
		"members": [
			{"agent_id": "coder_agent", "name": "Coder", "role": "Implementation", "desk": "Desk_Coder"},
			{"agent_id": "qa_agent", "name": "QA", "role": "Testing", "desk": "Desk_QA"},
			{"agent_id": "architect_agent", "name": "Architect", "role": "Design", "desk": "Desk_Architect"},
		],
	}],
	"shared": {"break_room": {"name": "Break Room"}, "meeting_room": {"name": "Meeting Room", "seats": 4}},
}

const THEMES := {
	"wood": [Color("#d9c09a"), Color("#c9ab80")],
	"sage": [Color("#c9d8bf"), Color("#b5c9a8")],
	"lilac": [Color("#d9cce6"), Color("#c6b5d9")],
	"navy": [Color("#3d4a66"), Color("#34405a")],
	"tile": [Color("#e8e4dc"), Color("#d6d1c6")],
	"carpet": [Color("#a99bc4"), Color("#9a8bb7")],
	"lobby": [Color("#d7d2c8"), Color("#cbc4b8")],
	"zen": [Color("#c8d9c4"), Color("#b5cbb0")],
	"corridor": [Color("#bfb6a6"), Color("#b3aa99")],
}

# ---- Built layout (read by Main) ------------------------------------------
var layout_name := ""
var bounds := Rect2()            ## everything incl. outer walls (camera limits)
var walk_rect := Rect2()         ## bounding traversable AABB (legacy / debug)
var walk_polys: Array[PackedVector2Array] = [] ## hub + corridors + satellites for nav bake
var obstacles: Array[Rect2] = [] ## walls + furniture footprints (nav obstructions)
var areas: Array[Dictionary] = []    ## {kind, id, name, rect, theme, color}
var walls: Array[Rect2] = []         ## interior walls (drawn + obstacles)
var outer_frames: Array[Dictionary] = []  ## {rect, door: Rect2, color}
var props: Array[Dictionary] = []    ## {kind, rect, sort_y, ...}
var waypoints: Array[Dictionary] = [] ## {name, pos, facing, seat}
var signs: Array[Dictionary] = []    ## {room_id, name, sub, rect, color, clickable}
var rooms: Array[Dictionary] = []    ## team room configs (members ...)
var meeting_groups: Dictionary = {}  ## virtual target -> Array[String] seat names
var agent_room: Dictionary = {}      ## agent_id -> room id
var agent_job: Dictionary = {}       ## agent_id -> job{}
var room_break_spots: Dictionary = {} ## room id -> Array[String]
var desk_of: Dictionary = {}         ## agent_id -> desk waypoint name
var chair_backs: Array[Dictionary] = [] ## floor-drawn chair backs (behind front-facing sitters)

var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font


# ===========================================================================
# Building
# ===========================================================================
func build(cfg: Dictionary) -> void:
	_reset()
	layout_name = str(cfg.get("name", "Office"))
	var shared: Dictionary = cfg.get("shared", {})
	var team_rooms: Array = []
	var wings: Array = []
	for r: Dictionary in cfg.get("rooms", []):
		rooms.append(r)
		var spots: Array = r.get("break_spots", [])
		if bool(r.get("isolated", false)):
			wings.append(r)
			if spots.is_empty():
				spots = ["%s_Coffee" % r.id, "%s_Water" % r.id]
		else:
			team_rooms.append(r)
			if spots.is_empty():
				spots = ["Coffee_Machine", "Water_Cooler", "Vending_Machine", "Sofa_1", "Sofa_2",
					"Yoga_Mat_1", "Yoga_Mat_2", "Meditation_Cushion_1", "Meditation_Cushion_2"]
		room_break_spots[str(r.id)] = spots
		for m: Dictionary in r.get("members", []):
			var aid := str(m.agent_id)
			agent_room[aid] = str(r.id)
			desk_of[aid] = str(m.get("desk", "Desk_" + aid))
			if typeof(m.get("job", null)) == TYPE_DICTIONARY:
				agent_job[aid] = m["job"]

	# --- Hex hub + satellite ring (landscape ~16:9) ---------------------------
	var seats := clampi(int(shared.get("meeting_room", {}).get("seats", 6)), 2, 8)
	var break_name := str(shared.get("break_room", {}).get("name", "Break Room"))
	var meeting_name := str(shared.get("meeting_room", {}).get("name", "Meeting Room"))
	var canteen_name := str(shared.get("canteen", {}).get("name", "Canteen")) if typeof(shared.get("canteen", {})) == TYPE_DICTIONARY else "Canteen"
	var server_name := "Server Room"
	if typeof(shared.get("server_room", {})) == TYPE_DICTIONARY:
		server_name = str(shared.get("server_room", {}).get("name", "Server Room"))
	var rec_name := "Rec Room"
	if typeof(shared.get("rec_room", {})) == TYPE_DICTIONARY:
		rec_name = str(shared.get("rec_room", {}).get("name", "Rec Room"))

	# Hub sized so Break / Canteen / Rec sit side-by-side as open zones.
	var hub_size := Vector2(1320, 700)
	# Place hub so the elliptical ring fits a wide landscape frame.
	var hub := Rect2(ORIGIN + Vector2(760, 420), hub_size)
	var hub_c := hub.get_center()

	# Elliptical ring radii (Rx > Ry → ~16:9 campus).
	var ring_rx := 1400.0
	var ring_ry := 780.0
	var corridor_w := 78.0

	# Satellites around the hub (θ=0 east, +θ clockwise with y-down = south-positive).
	# Executive sits south and is built larger for the Chief of Staff.
	var sat_specs: Array = [
		{"kind": "meeting", "name": meeting_name, "seats": seats, "theta": -PI * 0.5, "id": ""},
		{"kind": "server", "name": server_name, "theta": -PI * 0.25, "id": ""},
	]
	# Map team rooms onto remaining slots; Executive forced to south.
	var exec_room: Variant = null
	var other_teams: Array = []
	for r: Dictionary in team_rooms:
		if str(r.id) == "executive":
			exec_room = r
		else:
			other_teams.append(r)
	sat_specs.append({"kind": "team", "room": exec_room if exec_room != null else {}, "theta": PI * 0.5, "prominent": true, "id": "executive"})
	var other_thetas: Array = [0.0, PI * 0.25, PI * 0.75, PI, PI * 1.25]
	# Prefer stable order matching office.json departments when possible.
	var prefer := ["engineering", "product_design", "operations", "finance", "special_projects"]
	var ordered: Array = []
	for pid in prefer:
		for r: Dictionary in other_teams:
			if str(r.id) == pid and r not in ordered:
				ordered.append(r)
	for r: Dictionary in other_teams:
		if r not in ordered:
			ordered.append(r)
	for i in ordered.size():
		var th: float = other_thetas[i] if i < other_thetas.size() else (float(i) * TAU / maxf(1.0, float(ordered.size())))
		sat_specs.append({"kind": "team", "room": ordered[i], "theta": th, "id": str(ordered[i].id)})
	# If there was no executive room, the south slot used an empty dict — drop it.
	if exec_room == null:
		for i in range(sat_specs.size() - 1, -1, -1):
			if bool(sat_specs[i].get("prominent", false)) and sat_specs[i].kind == "team" and (sat_specs[i].room as Dictionary).is_empty():
				sat_specs.remove_at(i)

	# --- Build hub zones (Break | Canteen | Rec), open to each other ----------
	# Inset so zone rects stay inside the inscribed hex (avoid corner spill).
	var pad := 56.0
	var zone_w := (hub_size.x - pad * 4.0) / 3.0
	var zone_h := hub_size.y * 0.70
	var zone_y := hub.position.y + (hub_size.y - zone_h) * 0.5
	var break_r := Rect2(hub.position.x + pad, zone_y, zone_w, zone_h)
	var canteen_r := Rect2(break_r.end.x + pad, zone_y, zone_w, zone_h)
	var rec_r := Rect2(canteen_r.end.x + pad, zone_y, zone_w, zone_h)
	areas.append({"kind": "hub", "rect": hub, "theme": "lobby", "name": "Hub"})
	_build_break({"kind": "break", "name": break_name}, break_r)
	_build_canteen({"kind": "canteen", "name": canteen_name}, canteen_r)
	_build_rec({"kind": "rec", "name": rec_name}, rec_r)
	_chat("Chat_Corridor", hub_c + Vector2(0, 40))
	_wp("Entrance", Vector2(hub_c.x, hub.end.y - 24), "up")
	# Soft inner dividers (gaps in the middle so agents walk between zones).
	var div_gap := 110.0
	for dx in [break_r.end.x + pad * 0.5 - WALL * 0.5, canteen_r.end.x + pad * 0.5 - WALL * 0.5]:
		var top_h := (zone_h - div_gap) * 0.5
		walls.append(Rect2(dx, break_r.position.y, WALL, top_h))
		walls.append(Rect2(dx, break_r.end.y - top_h, WALL, top_h))

	walk_polys.append(_outline(hub))
	var hub_doors: Array[Vector2] = []  # points on hub edge where spokes attach

	# --- Satellites + spoke corridors ----------------------------------------
	var campus := hub
	for spec: Dictionary in sat_specs:
		var theta: float = float(spec.theta)
		var prominent := bool(spec.get("prominent", false))
		var sat_size := Vector2(360, 360)
		match str(spec.kind):
			"team":
				var room: Dictionary = spec.room
				sat_size = _team_size(room)
				if prominent:
					sat_size *= Vector2(1.28, 1.18)
			"meeting":
				var per_side := ceili(seats / 2.0)
				sat_size = Vector2(maxf(360.0, per_side * 84.0 + 190.0), 400)
			"server":
				sat_size = Vector2(380, 390)
		# Centre of satellite on the ellipse.
		var sc := Vector2(hub_c.x + cos(theta) * ring_rx, hub_c.y + sin(theta) * ring_ry)
		var sat := Rect2(sc - sat_size * 0.5, sat_size)
		# Spoke corridor: AABB from hub exit toward satellite entrance.
		var dir := (sc - hub_c).normalized()
		var hub_exit := _snap_to_edge(hub, _rect_exit(hub, dir))
		var sat_exit := _snap_to_edge(sat, _rect_exit(sat, -dir))
		hub_doors.append(hub_exit)
		var corr := _spoke_rect(hub_exit, sat_exit, corridor_w)
		areas.append({"kind": "corridor", "rect": corr, "theme": "corridor", "name": "",
			"from": hub_exit, "to": sat_exit, "width": corridor_w})
		# Oriented strip (not AABB) so nav cannot shortcut across walls.
		walk_polys.append(_spoke_poly(hub_exit, sat_exit, corridor_w, 18.0))
		# Door gap matches spoke width so the opening sits on the spoke junction.
		var door_w := corridor_w + 10.0
		_frame_walls(sat, sat_exit, door_w)
		# Build interior.
		match str(spec.kind):
			"team":
				var room2: Dictionary = spec.room
				var content := Rect2(sat.position, _team_size(room2))
				# Centre desks inside the (possibly enlarged) satellite.
				_build_team(room2, sat, content)
				if prominent:
					# Extra plants / rug cue so the CoS office reads as the flagship.
					_prop("plant", Rect2(sat.position.x + 12, sat.position.y + 12, 34, 34))
					_prop("plant", Rect2(sat.end.x - 46, sat.end.y - 46, 34, 34))
			"meeting":
				_build_meeting({"kind": "meeting", "name": meeting_name, "seats": seats}, sat)
			"server":
				_build_server({"kind": "server", "name": server_name}, sat)
		walk_polys.append(_outline(sat))
		var frame_col := Color("#2f3a52") if prominent else Color("#59606e")
		if prominent:
			frame_col = Color("#5c6bc0")
		var sat_label := str(spec.get("name", spec.get("id", spec.kind)))
		if str(spec.kind) == "team":
			sat_label = str((spec.room as Dictionary).get("name", spec.get("id", "Team")))
		outer_frames.append({"rect": sat, "door": _door_rect(sat, sat_exit, door_w), "color": frame_col, "name": sat_label, "wing": false, "satellite": true, "prominent": prominent})
		campus = campus.merge(sat).merge(corr)

	# Hub outer wall with gaps at each spoke (same door width as satellites).
	_hub_perimeter(hub, hub_doors, corridor_w + 10.0)
	outer_frames.insert(0, {"rect": hub, "door": Rect2(hub_c.x - 50, hub.end.y, 100, EXT_WALL), "color": Color("#455a64"), "name": layout_name, "hub": true})

	# --- Isolated wings (unchanged idea: separate building to the right) ------
	var right := campus.end.x
	for r: Dictionary in wings:
		var wx := right + EXT_WALL * 2.0 + WING_GAP
		var team_size := _team_size(r)
		var wing := Rect2(wx, hub.position.y, team_size.x + AMENITY_W, maxf(team_size.y + 40.0, hub_size.y))
		obstacles.append(Rect2(right, hub.position.y, wx - right, wing.size.y))
		var door := _build_wing(r, wing)
		outer_frames.append({"rect": wing, "door": door, "color": Color("#2f3a52"), "name": str(r.get("name", r.id)), "wing": true})
		walk_polys.append(_outline(wing))
		campus = campus.merge(wing)
		right = wing.end.x

	walk_rect = campus
	bounds = Rect2(ORIGIN - Vector2(40, 40), campus.end - ORIGIN + Vector2(80, 100))
	# Inflate bounds to a landscape frame (~16:9) if the campus is taller than that.
	var target_aspect := 16.0 / 9.0
	if bounds.size.x / maxf(bounds.size.y, 1.0) < target_aspect:
		var need_w := bounds.size.y * target_aspect
		var extra := need_w - bounds.size.x
		bounds.position.x -= extra * 0.5
		bounds.size.x = need_w
	for w in walls:
		obstacles.append(w)
	queue_redraw()



func _reset() -> void:
	obstacles.clear(); areas.clear(); walls.clear(); outer_frames.clear(); props.clear()
	walk_polys.clear()
	waypoints.clear(); signs.clear(); rooms.clear(); meeting_groups.clear(); agent_room.clear()
	agent_job.clear()
	room_break_spots.clear(); desk_of.clear(); chair_backs.clear()


func _team_size(r: Dictionary) -> Vector2:
	var members: Array = r.get("members", [])
	var desks := maxi(int(r.get("desks", 1)), members.size())
	desks = maxi(desks, 1)
	var cols := mini(3, desks)
	var rows := ceili(desks / float(cols))
	var exec_extra := 0.0
	for m in members:
		if str(m.get("desk_style", "")) == "executive" or str(m.get("agent_id", "")) == "chief_of_staff":
			exec_extra += CELL.x * 0.55
	return Vector2(cols * CELL.x + PAD_X * 2.0 + exec_extra, ROOM_TOP + rows * CELL.y + ROOM_BOTTOM)


func _cell_size(cell: Dictionary) -> Vector2:
	match str(cell.kind):
		"team": return _team_size(cell.room)
		"break": return Vector2(480, 470)
		"canteen": return Vector2(420, 470)
		"server": return Vector2(380, 420)
		"rec": return Vector2(400, 430)
		"meeting":
			var per_side := ceili(int(cell.seats) / 2.0)
			return Vector2(maxf(360.0, per_side * 84.0 + 190.0), 450)
		_: return Vector2(320, 450)


func _corridor_wall(cell: Dictionary, r: Rect2) -> void:
	if str(cell.kind) in ["lobby", "lounge"]:
		return  # open onto the corridor
	var door_w := 110.0 if str(cell.kind) in ["break", "meeting", "rec"] else DOOR
	var cx := r.position.x + r.size.x * 0.5
	walls.append(Rect2(r.position.x, r.position.y, cx - door_w * 0.5 - r.position.x, r.size.y))
	walls.append(Rect2(cx + door_w * 0.5, r.position.y, r.end.x - cx - door_w * 0.5, r.size.y))


## Returns the exterior door rect for a lobby cell, otherwise an empty rect.
func _build_cell(cell: Dictionary, r: Rect2, is_top: bool) -> Rect2:
	match str(cell.kind):
		"team":
			_build_team(cell.room, r, Rect2(r.position, _team_size(cell.room)))
		"break":
			_build_break(cell, r)
		"meeting":
			_build_meeting(cell, r)
		"canteen":
			_build_canteen(cell, r)
		"server":
			_build_server(cell, r)
		"rec":
			_build_rec(cell, r)
		"lobby":
			areas.append({"kind": "lobby", "rect": r, "theme": "lobby", "name": "Lobby"})
			_prop("reception", Rect2(r.position.x + r.size.x * 0.5 - 70, r.position.y + 70, 140, 38))
			_prop("plant", Rect2(r.position.x + 16, r.position.y + 54, 34, 34))
			_prop("plant", Rect2(r.end.x - 50, r.position.y + 16, 34, 34))
			_prop("bench", Rect2(r.position.x + 24, r.end.y - 120, 40, 90))
			_wp("Entrance", Vector2(r.position.x + r.size.x * 0.5, r.end.y - 30), "up")
			signs.append({"room_id": "", "name": "Lobby", "rect": _sign_rect(r, "Lobby"), "color": Color("#8d8577"), "clickable": false})
			var door_y := r.end.y if not is_top else r.position.y - EXT_WALL
			return Rect2(r.position.x + r.size.x * 0.5 - 45, door_y, 90, EXT_WALL)
		_:
			areas.append({"kind": "lounge", "rect": r, "theme": "lobby", "name": ""})
			_prop("plant", Rect2(r.position.x + r.size.x * 0.5 - 17, r.position.y + r.size.y * 0.5 - 17, 34, 34))
	return Rect2()


func _sign_rect(r: Rect2, text: String, sub: String = "") -> Rect2:
	var w := maxf(_text_w(text, 14), _text_w(sub, 10)) + 30.0
	return Rect2(r.position.x + 10, r.position.y + 8, w, 26 if sub.is_empty() else 36)


func _text_w(text: String, size: int) -> float:
	if text.is_empty():
		return 0.0
	var f := _font if _font else ThemeDB.fallback_font
	return f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


func _build_team(room: Dictionary, cell: Rect2, content: Rect2) -> void:
	var col := Color.from_string(str(room.get("color", "#90a4ae")), Color("#90a4ae"))
	areas.append({"kind": "room", "id": room.id, "rect": cell, "theme": str(room.get("theme", "wood")), "name": room.name, "color": col})
	var sub := "%d members" % (room.get("members", []) as Array).size()
	signs.append({"room_id": str(room.id), "name": str(room.name), "sub": sub, "rect": _sign_rect(cell, str(room.name), sub), "color": col, "clickable": true})
	# Centre the desk grid horizontally inside the (possibly wider) cell.
	var origin := Vector2(cell.position.x + (cell.size.x - content.size.x) * 0.5, cell.position.y)
	_desk_grid(room, origin)
	_prop("plant", Rect2(cell.end.x - 44, cell.position.y + 10, 30, 30))
	_chat("Chat_" + str(room.id), Vector2(cell.get_center().x, cell.end.y - 46))


func _desk_grid(room: Dictionary, origin: Vector2) -> void:
	var members: Array = room.get("members", [])
	var desks := maxi(int(room.get("desks", 1)), members.size())
	var cols := mini(3, maxi(desks, 1))
	# Track x per row so an executive (double-width) desk pushes neighbours aside.
	var row_x: Dictionary = {}
	for i in desks:
		var c := i % cols
		var row := int(i / cols)
		var owner := ""
		var desk_name := ""
		var color := ""
		var is_exec := false
		if i < members.size():
			owner = str(members[i].agent_id)
			desk_name = str(members[i].get("desk", "Desk_" + owner))
			color = str(members[i].get("color", ""))
			var style := str(members[i].get("desk_style", ""))
			is_exec = style == "executive" or owner == "chief_of_staff"
		var cell_w: float = CELL.x * (1.55 if is_exec else 1.0)
		if not row_x.has(row):
			row_x[row] = origin.x + PAD_X
		# First desk in a row resets; subsequent use the running cursor.
		if c == 0:
			row_x[row] = origin.x + PAD_X
		var cell := Vector2(float(row_x[row]), origin.y + ROOM_TOP + row * CELL.y)
		var cx := cell.x + cell_w * 0.5
		if is_exec:
			# Large L-shaped executive desk: wide main top + left return wing
			# (drawn in Prop when style=executive). Seat centres on the main
			# work surface (right of the return) so sit / waypoint still line up.
			var desk := Rect2(cx - 78, cell.y + 26, 156, 42)
			_prop("desk", desk, {"owner": owner, "color": color, "style": "executive"})
			var seat := Vector2(cx + 18, desk.end.y + 16)
			_prop("chair", Rect2(seat.x - 16, seat.y - 28, 32, 30), {"sort_y": seat.y + 2.0, "style": "executive"})
			_prop("plant", Rect2(desk.position.x - 30, desk.position.y + 6, 28, 28))
			if not desk_name.is_empty():
				_wp(desk_name, seat, "up", "desk")
		else:
			var desk := Rect2(cx - 44, cell.y + 34, 88, 36)
			_prop("desk", desk, {"owner": owner, "color": color})
			var seat := Vector2(cx, desk.end.y + 14)
			_prop("chair", Rect2(seat.x - 13, seat.y - 22, 26, 24), {"sort_y": seat.y + 2.0})
			if not desk_name.is_empty():
				_wp(desk_name, seat, "up", "desk")
		row_x[row] = cell.x + cell_w

func _build_break(cell: Dictionary, r: Rect2) -> void:
	# Furniture + waypoints derived from the live zone rect (hex hub or corridor cell),
	# never from old absolute corridor-map coordinates.
	areas.append({"kind": "break", "rect": r, "theme": "tile", "name": cell.name})
	signs.append({"room_id": "", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#6f8fa8"), "clickable": false})
	var p := r.position
	var e := r.end
	var m := 14.0
	# Top row: coffee (L) · counter · vending · water (R) — packed from edges so a
	# narrow hub zone (~365px) never spills into Canteen.
	var coffee := Rect2(p.x + m, p.y + 44, 52, 42)
	_prop("coffee", coffee)
	_wp("Coffee_Machine", Vector2(coffee.get_center().x, coffee.end.y + 26), "up")
	var water := Rect2(e.x - m - 40, p.y + 44, 40, 44)
	_prop("water", water)
	_wp("Water_Cooler", Vector2(water.get_center().x, water.end.y + 26), "down")
	var vend := Rect2(water.position.x - 12 - 44, p.y + 42, 44, 40)
	_prop("vending", vend)
	_wp("Vending_Machine", Vector2(vend.get_center().x, vend.end.y + 28), "up")
	var counter_w := minf(150.0, maxf(80.0, vend.position.x - coffee.end.x - 24.0))
	var counter_x := coffee.end.x + (vend.position.x - coffee.end.x - counter_w) * 0.5
	_prop("counter", Rect2(counter_x, p.y + 50, counter_w, 34))
	_chat("Chat_Break", Vector2(r.get_center().x, p.y + r.size.y * 0.42))
	# Bottom: sofa (L) + foosball (R), sized to the live floor.
	var sofa_w := minf(156.0, r.size.x * 0.42)
	var sofa := Rect2(p.x + m, e.y - 50 - 46, sofa_w, 46)
	_prop("sofa", sofa)
	_wp("Sofa_1", Vector2(sofa.position.x + sofa.size.x * 0.30, sofa.position.y + 26), "down", "sofa")
	_wp("Sofa_2", Vector2(sofa.position.x + sofa.size.x * 0.70, sofa.position.y + 26), "down", "sofa")
	var table_w := minf(120.0, r.size.x * 0.34)
	var table := Rect2(e.x - m - table_w, sofa.position.y, table_w, 58)
	# Keep a gap between sofa and foosball when the zone is tight.
	if table.position.x < sofa.end.x + 20.0:
		table.position.x = sofa.end.x + 20.0
		table.size.x = maxf(72.0, e.x - m - table.position.x)
	_prop("foosball", table)
	_wp("Foosball_1", Vector2(table.position.x - 18, table.position.y + 22), "right", "foosball")
	_wp("Foosball_2", Vector2(table.end.x + 18, table.position.y + 22), "left", "foosball")
	_wp("Foosball_3", Vector2(table.position.x - 18, table.position.y + 50), "right", "foosball")
	_wp("Foosball_4", Vector2(table.end.x + 18, table.position.y + 50), "left", "foosball")
	_prop("plant", Rect2(p.x + m, e.y - 50, 34, 34))



func _build_canteen(cell: Dictionary, r: Rect2) -> void:
	# Props + seats from the live zone rect so nothing spills into Rec on a narrow hub.
	areas.append({"kind": "canteen", "rect": r, "theme": "tile", "name": cell.name})
	signs.append({"room_id": "", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#c47a4a"), "clickable": false})
	var p := r.position
	var e := r.end
	var m := 14.0
	# Back-wall appliances packed from the right edge; counter fills the left.
	var micro := Rect2(e.x - m - 36, p.y + 52, 36, 28)
	_prop("microwave", micro)
	var coffee := Rect2(micro.position.x - 10 - 48, p.y + 44, 48, 40)
	_prop("coffee", coffee)
	var fridge := Rect2(coffee.position.x - 10 - 40, p.y + 36, 40, 52)
	_prop("fridge", fridge)
	var counter_w := maxf(120.0, fridge.position.x - (p.x + m) - 12.0)
	var counter := Rect2(p.x + m, p.y + 42, counter_w, 40)
	_prop("counter", counter, {"set": "canteen"})
	_prop("menu", Rect2(p.x + m + 12, p.y + 10, 72, 28), {"sort_y": p.y + 20.0})
	_prop("bin", Rect2(e.x - m - 22, e.y - 56, 22, 22))
	_wp("Canteen_Counter", Vector2(counter.get_center().x, counter.end.y + 26), "up")
	# Dining tables: 2 on the upper row when wide enough, else 1; one below.
	var tw := minf(96.0, (r.size.x - m * 2.0 - 40.0) * 0.42)
	var tables: Array = []
	var y1 := p.y + maxf(150.0, r.size.y * 0.34)
	tables.append(Vector2(p.x + m + 10, y1))
	if r.size.x >= 300.0:
		tables.append(Vector2(e.x - m - 10 - tw, y1))
	tables.append(Vector2(r.get_center().x - tw * 0.5, e.y - 52 - 70))
	var seat_i := 1
	for tpos in tables:
		var table := Rect2(tpos.x, tpos.y, tw, 52)
		_prop("table", table, {"set": "canteen"})
		_wp("Canteen_Seat_%d" % seat_i, Vector2(table.position.x - 16, table.get_center().y), "right", "chair")
		seat_i += 1
		_wp("Canteen_Seat_%d" % seat_i, Vector2(table.end.x + 16, table.get_center().y), "left", "chair")
		seat_i += 1
		_prop("chair", Rect2(table.position.x - 26, table.get_center().y - 12, 24, 24))
		_prop("chair", Rect2(table.end.x + 2, table.get_center().y - 12, 24, 24))
	# Ensure 6 seat names exist even when only 2 tables fit (narrow zone).
	while seat_i <= 6:
		var fallback := Vector2(r.get_center().x + (seat_i - 5) * 28.0, e.y - 60)
		_wp("Canteen_Seat_%d" % seat_i, fallback, "down", "chair")
		seat_i += 1
	_prop("plant", Rect2(e.x - m - 30, p.y + 16, 30, 30))
	_chat("Chat_Canteen", Vector2(r.get_center().x, e.y - 36))



func _build_server(cell: Dictionary, r: Rect2) -> void:
	areas.append({"kind": "server", "rect": r, "theme": "tile", "name": cell.name})
	signs.append({"room_id": "__knowledge__", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#26a69a"), "clickable": true})
	var p := r.position
	# Cold aisle of server racks.
	for i in 4:
		var rx := p.x + 28 + i * 78
		_prop("servers", Rect2(rx, p.y + 48, 56, 120), {"set": "server", "rack_id": i})
	# Drop zone marker in the centre aisle — files dropped on the office land here.
	_prop("bench", Rect2(p.x + r.size.x * 0.5 - 50, p.y + 200, 100, 36), {"set": "server", "label": "DROP"})
	_wp("Server_Room", Vector2(p.x + r.size.x * 0.5, p.y + 230), "up")
	_wp("Server_Rack_1", Vector2(p.x + 56, p.y + 180), "up")
	_wp("Server_Rack_2", Vector2(p.x + 210, p.y + 180), "up")
	_prop("plant", Rect2(r.end.x - 40, r.end.y - 48, 28, 28))
	_chat("Chat_Server", Vector2(p.x + r.size.x * 0.5, r.end.y - 36))



func _build_rec(cell: Dictionary, r: Rect2) -> void:
	# Yoga / cushions placed from the live Rec zone so they stay inside the hub
	# Rec third (not leftover corridor-map offsets that spilled into Canteen).
	areas.append({"kind": "rec", "rect": r, "theme": "zen", "name": cell.name})
	signs.append({"room_id": "", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#7cb342"), "clickable": false})
	var p := r.position
	var e := r.end
	var m := 16.0
	var rug := Rect2(p.x + m, p.y + 70, r.size.x - m * 2.0, r.size.y - 120)
	_prop("rug", rug, {"sort_y": p.y + 72.0})
	_prop("lamp", Rect2(p.x + m, p.y + 48, 22, 36), {"set": "rec"})
	_prop("lamp", Rect2(e.x - m - 22, p.y + 48, 22, 36), {"set": "rec"})
	_prop("fountain", Rect2(r.get_center().x - 28, p.y + 40, 56, 48), {"set": "rec"})
	_prop("plant", Rect2(r.get_center().x - 70, p.y + 44, 30, 30))
	_prop("plant", Rect2(r.get_center().x + 40, p.y + 44, 30, 30))
	_prop("plant", Rect2(p.x + m, e.y - 52, 30, 30))
	_prop("plant", Rect2(e.x - m - 30, e.y - 52, 30, 30))
	# Mats on the left half of the rug; cushions on the right.
	var mat_w := minf(70.0, rug.size.x * 0.22)
	var mat_h := minf(110.0, rug.size.y * 0.55)
	var mat_y := rug.position.y + rug.size.y * 0.22
	var mat1 := Rect2(rug.position.x + rug.size.x * 0.08, mat_y, mat_w, mat_h)
	var mat2 := Rect2(rug.position.x + rug.size.x * 0.08 + mat_w + 18.0, mat_y, mat_w, mat_h)
	_prop("yoga_mat", mat1, {"set": "rec", "tint": "#81c784"})
	_prop("yoga_mat", mat2, {"set": "rec", "tint": "#aed581"})
	_wp("Yoga_Mat_1", Vector2(mat1.get_center().x, mat1.get_center().y + 10), "down", "yoga")
	_wp("Yoga_Mat_2", Vector2(mat2.get_center().x, mat2.get_center().y + 10), "down", "yoga")
	var cw := minf(44.0, rug.size.x * 0.14)
	var ch := minf(36.0, rug.size.y * 0.18)
	var c1 := Rect2(rug.end.x - rug.size.x * 0.38, rug.position.y + rug.size.y * 0.28, cw, ch)
	var c2 := Rect2(rug.end.x - rug.size.x * 0.22, rug.position.y + rug.size.y * 0.48, cw, ch)
	_prop("cushion", c1, {"set": "rec", "tint": "#ce93d8"})
	_prop("cushion", c2, {"set": "rec", "tint": "#b39ddb"})
	_wp("Meditation_Cushion_1", Vector2(c1.get_center().x, c1.get_center().y - 2), "down", "meditate")
	_wp("Meditation_Cushion_2", Vector2(c2.get_center().x, c2.get_center().y - 2), "down", "meditate")
	_chat("Chat_Rec", Vector2(p.x + r.size.x * 0.35, e.y - 40))


func _build_meeting(cell: Dictionary, r: Rect2) -> void:
	areas.append({"kind": "meeting", "rect": r, "theme": "carpet", "name": cell.name})
	signs.append({"room_id": "", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#7e6aa6"), "clickable": false})
	var n := int(cell.seats)
	var per_side := ceili(n / 2.0)
	var tw := per_side * 84.0 + 20.0
	var table := Rect2(r.position.x + r.size.x * 0.5 - tw * 0.5, r.position.y + maxf(120.0, r.size.y * 0.5 - 40.0), tw, 64)
	_prop("table", table)
	var names: Array[String] = []
	for i in n:
		var top_side := i < per_side
		var k := i if top_side else i - per_side
		var sx := table.position.x + 52.0 + k * 84.0
		var name := "Meeting_Table_%d" % (i + 1)
		names.append(name)
		if top_side:
			var pos := Vector2(sx, table.position.y - 16)
			chair_backs.append({"pos": pos})
			_wp(name, pos, "down", "chair")
		else:
			var pos := Vector2(sx, table.end.y + 24)
			_prop("chair", Rect2(pos.x - 13, pos.y - 22, 26, 24), {"sort_y": pos.y + 2.0})
			_wp(name, pos, "up", "chair")
	meeting_groups["Meeting_Room"] = names
	_prop("plant", Rect2(r.end.x - 48, r.end.y - 48, 34, 34))


func _build_wing(room: Dictionary, wing: Rect2) -> Rect2:
	var rid := str(room.id)
	var col := Color.from_string(str(room.get("color", "#ffb74d")), Color("#ffb74d"))
	areas.append({"kind": "wing", "id": rid, "rect": wing, "theme": str(room.get("theme", "navy")), "name": room.name, "color": col})
	var sub := "Separate wing · %d members" % (room.get("members", []) as Array).size()
	signs.append({"room_id": rid, "name": str(room.name), "sub": sub, "rect": _sign_rect(wing, str(room.name), sub), "color": col, "clickable": true})
	var team := _team_size(room)
	_desk_grid(room, Vector2(wing.position.x, wing.position.y + 6))
	# Amenity column on the right: kitchenette + meeting nook.
	var ax := wing.position.x + team.x
	_prop("coffee", Rect2(ax + 18, wing.position.y + 50, 52, 42))
	_wp(rid + "_Coffee", Vector2(ax + 44, wing.position.y + 118), "up")
	_prop("water", Rect2(ax + 112, wing.position.y + 48, 40, 44))
	_wp(rid + "_Water", Vector2(ax + 132, wing.position.y + 118), "down")
	var table := Rect2(ax + 28, wing.position.y + 330, 120, 60)
	_prop("table", table)
	var seats: Array[String] = []
	for i in 4:
		var top_side := i < 2
		var sx := table.position.x + 30.0 + (i % 2) * 60.0
		var name := "%s_Meeting_%d" % [rid, i + 1]
		seats.append(name)
		if top_side:
			var pos := Vector2(sx, table.position.y - 16)
			chair_backs.append({"pos": pos})
			_wp(name, pos, "down", "chair")
		else:
			var pos := Vector2(sx, table.end.y + 24)
			_prop("chair", Rect2(pos.x - 13, pos.y - 22, 26, 24), {"sort_y": pos.y + 2.0})
			_wp(name, pos, "up", "chair")
	meeting_groups[rid + "_Meeting_Room"] = seats
	_prop("plant", Rect2(wing.position.x + 16, wing.end.y - 52, 34, 34))
	_prop("plant", Rect2(wing.end.x - 50, wing.end.y - 52, 34, 34))
	var sofa := Rect2(wing.position.x + 80, wing.end.y - 110, 156, 46)
	_prop("sofa", sofa)
	_wp(rid + "_Sofa_1", Vector2(sofa.position.x + 48, sofa.position.y + 26), "down", "sofa")
	_wp(rid + "_Sofa_2", Vector2(sofa.position.x + 108, sofa.position.y + 26), "down", "sofa")
	_chat(rid + "_Chat", Vector2(ax + 88, wing.position.y + 230))
	_wp(rid + "_Entrance", Vector2(wing.position.x + wing.size.x * 0.5, wing.end.y - 30), "up")
	# Own exterior door at the bottom of the wing.
	return Rect2(wing.position.x + wing.size.x * 0.5 - 45, wing.end.y, 90, EXT_WALL)


func _prop(kind: String, r: Rect2, extra: Dictionary = {}) -> void:
	var d := {"kind": kind, "rect": r, "sort_y": r.end.y}
	d.merge(extra, true)
	props.append(d)
	# Walkable surface props (mats, rugs, cushions, floor lamps glow) must not block nav.
	if kind not in ["chair", "rug", "yoga_mat", "cushion"]:
		obstacles.append(r)


## Three standing slots around `c` that face each other: _1 west (looks
## east), _2 east (looks west), _3 north (looks south).
func _chat(name: String, c: Vector2) -> void:
	_wp(name + "_1", c + Vector2(-40, 6), "right")
	_wp(name + "_2", c + Vector2(40, 6), "left")
	_wp(name + "_3", c + Vector2(0, -30), "down")


func _wp(name: String, pos: Vector2, facing: String, seat: String = "") -> void:
	waypoints.append({"name": name, "pos": pos, "facing": facing, "seat": seat})


# ===========================================================================
# Geometry for navigation baking
# ===========================================================================
func get_floor_outline() -> PackedVector2Array:
	if not walk_polys.is_empty():
		return walk_polys[0]
	return _outline(walk_rect)


func get_floor_outlines() -> Array[PackedVector2Array]:
	if not walk_polys.is_empty():
		return walk_polys
	return [get_floor_outline()]


func get_obstacle_outlines() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for r in obstacles:
		out.append(_outline(r))
	return out


func _outline(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


## Flat-top hexagon inscribed in rect (visual hub cue; nav still uses the rect).
func _hub_hex(r: Rect2) -> PackedVector2Array:
	var c := r.get_center()
	var rx := r.size.x * 0.48
	var ry := r.size.y * 0.48
	var pts := PackedVector2Array()
	for i in 6:
		var ang := deg_to_rad(60.0 * float(i) - 30.0)  # flat-top
		pts.append(c + Vector2(cos(ang) * rx, sin(ang) * ry))
	return pts


## Point where a ray from rect centre along `dir` exits the rect edge.
func _rect_exit(r: Rect2, dir: Vector2) -> Vector2:
	var d := dir.normalized()
	if d.length_squared() < 0.0001:
		return r.get_center()
	var c := r.get_center()
	var tx := INF
	if absf(d.x) > 0.0001:
		var edge_x := r.end.x if d.x > 0.0 else r.position.x
		tx = (edge_x - c.x) / d.x
	var ty := INF
	if absf(d.y) > 0.0001:
		var edge_y := r.end.y if d.y > 0.0 else r.position.y
		ty = (edge_y - c.y) / d.y
	var t := minf(tx, ty)
	return c + d * t


## Axis-aligned corridor slab covering the segment a→b with thickness `width`.
## Used for campus bounds merging only — nav uses `_spoke_poly`.
func _spoke_rect(a: Vector2, b: Vector2, width: float) -> Rect2:
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	var r := Rect2(lo, hi - lo)
	# Ensure minimum thickness so diagonal spokes stay walkable.
	if r.size.x < width:
		var m := r.get_center().x
		r.position.x = m - width * 0.5
		r.size.x = width
	if r.size.y < width:
		var m2 := r.get_center().y
		r.position.y = m2 - width * 0.5
		r.size.y = width
	# Slightly overlap hub/sat so campus merge covers the junction.
	return r.grow(6.0)


## Oriented corridor strip polygon for nav bake (room↔door↔spoke only).
## `extend` pushes ends into the rooms so the strip meets walkable interiors
## through the door gaps; walls carve everything else.
func _spoke_poly(a: Vector2, b: Vector2, width: float, extend: float = 18.0) -> PackedVector2Array:
	var d := b - a
	if d.length_squared() < 1.0:
		return PackedVector2Array()
	var along := d.normalized()
	var a2 := a - along * extend
	var b2 := b + along * extend
	var n := Vector2(-along.y, along.x) * (width * 0.5)
	return PackedVector2Array([a2 + n, b2 + n, b2 - n, a2 - n])


## Which side of rect `r` is closest to `p` (n/s/w/e).
func _nearest_edge(r: Rect2, p: Vector2) -> String:
	var dn := absf(p.y - r.position.y)
	var ds := absf(p.y - r.end.y)
	var dw := absf(p.x - r.position.x)
	var de := absf(p.x - r.end.x)
	var m := minf(minf(dn, ds), minf(dw, de))
	if m == dn:
		return "n"
	if m == ds:
		return "s"
	if m == dw:
		return "w"
	return "e"


## Door mat / iso cut-out aligned to the edge where `door_pt` sits.
func _door_rect(r: Rect2, door_pt: Vector2, door_w: float) -> Rect2:
	var edge := _nearest_edge(r, door_pt)
	var thick := 12.0
	var hw := door_w * 0.5
	match edge:
		"n":
			return Rect2(door_pt.x - hw, r.position.y - thick * 0.5, door_w, thick)
		"s":
			return Rect2(door_pt.x - hw, r.end.y - thick * 0.5, door_w, thick)
		"w":
			return Rect2(r.position.x - thick * 0.5, door_pt.y - hw, thick, door_w)
		_:
			return Rect2(r.end.x - thick * 0.5, door_pt.y - hw, thick, door_w)


## Pin a door point exactly onto its nearest edge (spoke junction).
func _snap_to_edge(r: Rect2, door_pt: Vector2) -> Vector2:
	var edge := _nearest_edge(r, door_pt)
	match edge:
		"n":
			return Vector2(door_pt.x, r.position.y)
		"s":
			return Vector2(door_pt.x, r.end.y)
		"w":
			return Vector2(r.position.x, door_pt.y)
		_:
			return Vector2(r.end.x, door_pt.y)


## Four wall segments around `r` with a door gap centred on `door_pt`.
func _frame_walls(r: Rect2, door_pt: Vector2, door_w: float) -> void:
	# Build perimeter via the same gap helper as the hub so near-corner spokes
	# open a mouth on both meeting edges.
	var gaps_n: Array = []
	var gaps_s: Array = []
	var gaps_w: Array = []
	var gaps_e: Array = []
	var edge := _nearest_edge(r, door_pt)
	var corner_slop := door_w * 0.5 + WALL
	match edge:
		"n":
			gaps_n.append(door_pt.x)
			if door_pt.x - r.position.x <= corner_slop:
				gaps_w.append(door_pt.y)
			if r.end.x - door_pt.x <= corner_slop:
				gaps_e.append(door_pt.y)
		"s":
			gaps_s.append(door_pt.x)
			if door_pt.x - r.position.x <= corner_slop:
				gaps_w.append(door_pt.y)
			if r.end.x - door_pt.x <= corner_slop:
				gaps_e.append(door_pt.y)
		"w":
			gaps_w.append(door_pt.y)
			if door_pt.y - r.position.y <= corner_slop:
				gaps_n.append(door_pt.x)
			if r.end.y - door_pt.y <= corner_slop:
				gaps_s.append(door_pt.x)
		_:
			gaps_e.append(door_pt.y)
			if door_pt.y - r.position.y <= corner_slop:
				gaps_n.append(door_pt.x)
			if r.end.y - door_pt.y <= corner_slop:
				gaps_s.append(door_pt.x)
	var hw := door_w * 0.5
	_wall_edge_with_gaps(r.position.x, r.position.y, r.end.x, r.position.y, WALL, true, gaps_n, hw)
	_wall_edge_with_gaps(r.position.x, r.end.y - WALL, r.end.x, r.end.y - WALL, WALL, true, gaps_s, hw)
	_wall_edge_with_gaps(r.position.x, r.position.y, r.position.x, r.end.y, WALL, false, gaps_w, hw)
	_wall_edge_with_gaps(r.end.x - WALL, r.position.y, r.end.x - WALL, r.end.y, WALL, false, gaps_e, hw)


## Hub perimeter walls with door gaps at each spoke attachment point.
func _hub_perimeter(hub: Rect2, doors: Array[Vector2], door_w: float) -> void:
	var x0 := hub.position.x
	var y0 := hub.position.y
	var x1 := hub.end.x
	var y1 := hub.end.y
	var hw := door_w * 0.5
	# Collect door intervals per edge.
	var north: Array = []
	var south: Array = []
	var west: Array = []
	var east: Array = []
	var corner_slop := door_w * 0.5 + WALL
	for p: Vector2 in doors:
		var dn := absf(p.y - y0)
		var ds := absf(p.y - y1)
		var dw := absf(p.x - x0)
		var de := absf(p.x - x1)
		var m := minf(minf(dn, ds), minf(dw, de))
		if m == dn:
			north.append(p.x)
		elif m == ds:
			south.append(p.x)
		elif m == dw:
			west.append(p.y)
		else:
			east.append(p.y)
		# Near-corner spoke: also open the adjacent edge so the mouth is clear.
		if m == dn or m == ds:
			if dw <= corner_slop:
				west.append(p.y)
			if de <= corner_slop:
				east.append(p.y)
		else:
			if dn <= corner_slop:
				north.append(p.x)
			if ds <= corner_slop:
				south.append(p.x)
	# Also leave the main Entrance open on the south edge.
	south.append(hub.get_center().x)
	_wall_edge_with_gaps(x0, y0, x1, y0, WALL, true, north, hw)   # north horizontal
	_wall_edge_with_gaps(x0, y1 - WALL, x1, y1 - WALL, WALL, true, south, hw)
	_wall_edge_with_gaps(x0, y0, x0, y1, WALL, false, west, hw)
	_wall_edge_with_gaps(x1 - WALL, y0, x1 - WALL, y1, WALL, false, east, hw)


func _wall_edge_with_gaps(ax: float, ay: float, bx: float, by: float, thickness: float, horizontal: bool, gaps: Array, hw: float) -> void:
	var pts: Array = gaps.duplicate()
	pts.sort()
	if horizontal:
		var x := ax
		var y := ay
		var end_x := bx
		for g in pts:
			var gx := float(g)
			if gx - hw > x:
				walls.append(Rect2(x, y, gx - hw - x, thickness))
			x = maxf(x, gx + hw)
		if end_x > x:
			walls.append(Rect2(x, y, end_x - x, thickness))
	else:
		var x2 := ax
		var y2 := ay
		var end_y := by
		for g in pts:
			var gy := float(g)
			if gy - hw > y2:
				walls.append(Rect2(x2, y2, thickness, gy - hw - y2))
			y2 = maxf(y2, gy + hw)
		if end_y > y2:
			walls.append(Rect2(x2, y2, thickness, end_y - y2))


## Sign rect that contains `world_pos` (for hover), or {}.
func sign_at(world_pos: Vector2) -> Dictionary:
	for s: Dictionary in signs:
		if (s.rect as Rect2).has_point(world_pos):
			return s
	return {}


# ===========================================================================
# Drawing (flat layer under everything else)
# ===========================================================================
func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	if Iso.enabled:
		_draw_iso()
		return
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * Iso.SCALE)
	# Grass / outdoor ground around the buildings.
	draw_rect(bounds.grow(400), Color("#7da36b"))
	for i in 60:
		var gx := bounds.position.x + fmod(i * 137.0, bounds.size.x)
		var gy := bounds.position.y + fmod(i * 89.0, bounds.size.y)
		draw_circle(Vector2(gx, gy), 3.0, Color("#6e955d"))
	# Wing entrance paths only (hub/satellite doors must not paint AABB streaks).
	for f: Dictionary in outer_frames:
		if not bool(f.get("wing", false)):
			continue
		var d: Rect2 = f.door
		if d.size.x > d.size.y and d.has_area():
			draw_rect(Rect2(d.position.x + 10, d.position.y, d.size.x - 20, minf(180.0, bounds.end.y - d.position.y + 40.0)), Color("#cdbf9f"))
	# Floors (a base under each building first, so door gaps aren't grass).
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue  # hub uses hex floor; rectangular base would show as corner junk
		draw_rect(f.rect, Color("#b3aa99"))
	for a: Dictionary in areas:
		if a.kind == "corridor":
			_draw_spoke(a)
			continue
		if a.kind == "hub":
			_draw_hub_floor(a)
			continue
		_draw_floor(a)
	# Re-stroke hub hex so zone floors don't hide the outline.
	for a: Dictionary in areas:
		if a.kind == "hub":
			var hex := _hub_hex(a.rect)
			for i in hex.size():
				draw_line(hex[i], hex[(i + 1) % hex.size()], Color("#455a64", 0.95), 3.0)
	# Building names on the roof edge (skip hub — campus title drawn centred on hub roof).
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue
		var r: Rect2 = f.rect
		draw_string(_font, Vector2(r.position.x, r.position.y - EXT_WALL - 10), str(f.name).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.85))
	# Campus title: centred on the hub roof band (clear of zones / corridors / agents).
	for f: Dictionary in outer_frames:
		if not bool(f.get("hub", false)):
			continue
		var hr: Rect2 = f.rect
		var title := str(layout_name if layout_name else f.name).to_upper()
		var title_size := 22
		var tw := _font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size).x
		var tx := hr.position.x + hr.size.x * 0.5 - tw * 0.5
		var ty := hr.position.y + 36.0
		draw_string(_font, Vector2(tx, ty), title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size, Color(1, 1, 1, 0.92))
		break
	# Walls.
	for w in walls:
		_draw_wall(w, Color("#6b7280"))
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue  # hub perimeter already in walls[]; frame would re-draw a solid rect
		_draw_frame(f)
	# Chair backs behind front-facing sitters (meeting top rows).
	for cb: Dictionary in chair_backs:
		var p: Vector2 = cb.pos
		_rrect(Rect2(p.x - 13, p.y - 30, 26, 22), 6, Color("#4e342e"))
		_rrect(Rect2(p.x - 10, p.y - 27, 20, 16), 5, Color("#795548"))
	# Sofa backs (the seat/arms are y-sorted props).
	for pr: Dictionary in props:
		if pr.kind == "sofa":
			var s: Rect2 = pr.rect
			_rrect(Rect2(s.position.x - 2, s.position.y - 22, s.size.x + 4, 30), 8, Color("#283593"))
			_rrect(Rect2(s.position.x + 2, s.position.y - 19, s.size.x - 4, 24), 7, Color("#3949ab"))
	# Whiteboard on the meeting room's top wall.
	for a: Dictionary in areas:
		if a.kind == "meeting":
			var r: Rect2 = a.rect
			var wb := Rect2(r.position.x + r.size.x * 0.5 - 90, r.position.y + 6, 180, 30)
			_rrect(wb, 3, Color("#eceff1"))
			draw_rect(wb, Color("#90a4ae"), false, 2.0)
			for i in 3:
				draw_line(wb.position + Vector2(14, 8 + i * 7), wb.position + Vector2(60 + i * 25, 8 + i * 7), [Color("#e57373"), Color("#64b5f6"), Color("#81c784")][i], 2.0)
	# Signs.
	for s: Dictionary in signs:
		_draw_sign(s)


func _draw_floor(a: Dictionary) -> void:
	var r: Rect2 = a.rect
	var pal: Array = THEMES.get(str(a.get("theme", "wood")), THEMES["wood"])
	var c1: Color = pal[0]
	var c2: Color = pal[1]
	draw_rect(r, c1)
	match str(a.get("theme", "wood")):
		"tile", "lobby":
			var t := 32
			for x in range(int(r.position.x), int(r.end.x), t):
				for y in range(int(r.position.y), int(r.end.y), t):
					if int((x - r.position.x) / t + (y - r.position.y) / t) % 2 == 0:
						draw_rect(Rect2(x, y, t, t).intersection(r), c2)
		"carpet", "navy":
			for y in range(int(r.position.y), int(r.end.y), 8):
				draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(c2, 0.5), 1.0)
		_:
			# Wood planks with staggered joints.
			var row := 0
			for y in range(int(r.position.y), int(r.end.y), 20):
				draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(c2, 0.9), 1.0)
				var off := 70.0 if row % 2 == 0 else 0.0
				var x := r.position.x + off
				while x < r.end.x:
					draw_line(Vector2(x, y), Vector2(x, minf(y + 20, r.end.y)), Color(c2, 0.9), 1.0)
					x += 140.0
				row += 1
	if a.kind == "rec":
		# Soft warm calm lighting wash.
		draw_rect(r.grow(-8), Color(1.0, 0.95, 0.7, 0.08))
		var rug := Rect2(r.position.x + 28, r.position.y + 80, r.size.x - 56, r.size.y - 130)
		_rrect(rug, 18, Color("#8d6e63", 0.35))
		_rrect(rug.grow(-6), 14, Color("#a1887f", 0.28))
	if a.has("color") and a.kind in ["room", "wing"]:
		# A soft rug in the team colour under the desks.
		var c: Color = a.color
		draw_rect(r.grow(-14), Color(c, 0.10))
		draw_rect(r.grow(-14), Color(c, 0.35), false, 2.0)
	if a.kind == "wing":
		# Hazard stripe along the bottom (restricted wing).
		var y := r.end.y - 8
		var x := r.position.x
		while x < r.end.x:
			draw_colored_polygon(PackedVector2Array([Vector2(x, y), Vector2(x + 10, y), Vector2(x + 18, y + 8), Vector2(x + 8, y + 8)]), Color("#fbc02d", 0.6))
			x += 20.0



## Hex hub floor only (no rectangular AABB fill — that left corner shading junk).
func _draw_hub_floor(a: Dictionary) -> void:
	var r: Rect2 = a.rect
	var pal: Array = THEMES.get(str(a.get("theme", "lobby")), THEMES["lobby"])
	var c1: Color = pal[0]
	var hex := _hub_hex(r)
	draw_colored_polygon(hex, c1)
	for i in hex.size():
		draw_line(hex[i], hex[(i + 1) % hex.size()], Color("#455a64", 0.9), 3.0)


## Oriented spoke strip (AABB corridors are nav-only; do not paint their full rect).
func _draw_spoke(a: Dictionary) -> void:
	if not a.has("from") or not a.has("to"):
		return
	var a_pt: Vector2 = a["from"]
	var b_pt: Vector2 = a["to"]
	var w: float = float(a.get("width", 78.0))
	var d := b_pt - a_pt
	if d.length_squared() < 1.0:
		return
	var n := Vector2(-d.y, d.x).normalized() * (w * 0.42)
	var pts := PackedVector2Array([a_pt + n, b_pt + n, b_pt - n, a_pt - n])
	draw_colored_polygon(pts, Color("#bfb6a6"))
	# Soft edge lines along the spoke (not the old E–W runner).
	draw_line(a_pt + n, b_pt + n, Color("#9c5b4a", 0.35), 2.0)
	draw_line(a_pt - n, b_pt - n, Color("#9c5b4a", 0.35), 2.0)


func _draw_wall(w: Rect2, c: Color) -> void:
	# Top face + a darker front face, for a hint of 3/4 depth.
	draw_rect(w, c)
	draw_rect(Rect2(w.position.x, w.end.y - 4, w.size.x, 4), c.darkened(0.35))
	draw_rect(Rect2(w.position.x, w.position.y, w.size.x, 2), c.lightened(0.25))


func _draw_frame(f: Dictionary) -> void:
	var r: Rect2 = f.rect
	var c: Color = f.color
	var d: Rect2 = f.door
	# Satellites: walls[] already carve the door gap — do not paint a solid outer
	# frame over it (that made doors look misaligned with the spokes).
	if bool(f.get("satellite", false)):
		if d.has_area():
			draw_rect(d, Color("#8d6e63"))
			draw_rect(d.grow(-3), Color("#a1887f"))
		return
	var o := r.grow(EXT_WALL)
	var parts := [Rect2(o.position, Vector2(o.size.x, EXT_WALL)), Rect2(o.position.x, r.end.y, o.size.x, EXT_WALL),
		Rect2(o.position, Vector2(EXT_WALL, o.size.y)), Rect2(r.end.x, o.position.y, EXT_WALL, o.size.y)]
	for p: Rect2 in parts:
		_draw_wall(p, c)
	if d.size.x > 0.0 or d.size.y > 0.0:
		# Door opening + mat.
		draw_rect(d, Color("#8d6e63"))
		draw_rect(d.grow(-3), Color("#a1887f"))
		if f.get("wing", false):
			draw_string(_font, Vector2(d.get_center().x - 60, d.end.y + 20), "Separate entrance", HORIZONTAL_ALIGNMENT_CENTER, 120, 13, Color(1, 1, 1, 0.9))


func _draw_sign(s: Dictionary) -> void:
	var r: Rect2 = s.rect
	var c: Color = s.color
	_rrect(Rect2(r.position + Vector2(2, 3), r.size), 9, Color(0, 0, 0, 0.25))
	_rrect(r, 9, c.darkened(0.25))
	_rrect(r.grow(-2), 8, c.darkened(0.05) if s.clickable else c)
	var text_col := Color.WHITE if c.get_luminance() < 0.62 else Color("#1f2430")
	draw_string(_font, r.position + Vector2(12, 18), str(s.name), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, text_col)
	if s.has("sub") and str(s.sub) != "":
		draw_string(_font, r.position + Vector2(12, 31), str(s.sub), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(text_col, 0.8))
	if s.clickable:
		draw_string(_font, Vector2(r.end.x - 16, r.position.y + 18), "›", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(text_col, 0.8))


func _rrect(r: Rect2, radius: float, c: Color) -> void:
	draw_colored_polygon(rounded_rect_points(r, radius), c)


static func rounded_rect_points(r: Rect2, radius: float, steps: int = 4) -> PackedVector2Array:
	# Stay just under half the short side: coincident points break triangulation.
	radius = maxf(0.0, minf(radius, minf(r.size.x, r.size.y) * 0.5 - 0.05))
	var pts := PackedVector2Array()
	if radius < 0.1:
		return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var corners := [
		[Vector2(r.end.x - radius, r.position.y + radius), -PI / 2],
		[Vector2(r.end.x - radius, r.end.y - radius), 0.0],
		[Vector2(r.position.x + radius, r.end.y - radius), PI / 2],
		[Vector2(r.position.x + radius, r.position.y + radius), PI],
	]
	for c: Array in corners:
		for i in steps + 1:
			var a: float = c[1] + (PI / 2) * i / steps
			pts.append(c[0] + Vector2(cos(a), sin(a)) * radius)
	return pts


# ===========================================================================
# Isometric view: floors only (walls, furniture and signs are sorted nodes)
# ===========================================================================
## Wall pieces for the isometric view: {rect, h, color, windows}. Exterior
## frames get tall north/west walls (with windows) and low south/east walls,
## with the door cut out; interior walls are medium height.
func iso_walls() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for w in walls:
		out.append({"rect": w, "h": WALL_H_INNER, "color": Color("#8a909c")})
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue  # hub gaps live in walls[]; a second frame would cover spoke doors
		var r: Rect2 = f.rect
		var c: Color = f.color
		var o := r.grow(EXT_WALL)
		var wing: bool = f.get("wing", false)
		var sides := [
			{"rect": Rect2(o.position, Vector2(o.size.x, EXT_WALL)), "h": WALL_H_BACK, "windows": "south"},
			{"rect": Rect2(o.position.x, r.position.y, EXT_WALL, r.size.y), "h": WALL_H_INNER if wing else WALL_H_BACK, "windows": "" if wing else "east"},
			{"rect": Rect2(o.position.x, r.end.y, o.size.x, EXT_WALL), "h": WALL_H_FRONT, "windows": ""},
			{"rect": Rect2(r.end.x, r.position.y, EXT_WALL, r.size.y), "h": WALL_H_FRONT, "windows": ""},
		]
		var door: Rect2 = f.door
		for sd: Dictionary in sides:
			for piece: Rect2 in _cut(sd.rect, door):
				out.append({"rect": piece, "h": sd.h, "color": c.lightened(0.18), "windows": sd.windows})
	return out


## `r` minus the door opening (split along r's long axis).
func _cut(r: Rect2, door: Rect2) -> Array[Rect2]:
	if not door.has_area() or not r.intersects(door):
		return [r]
	var out: Array[Rect2] = []
	if r.size.x >= r.size.y:
		if door.position.x > r.position.x:
			out.append(Rect2(r.position.x, r.position.y, door.position.x - r.position.x, r.size.y))
		if door.end.x < r.end.x:
			out.append(Rect2(door.end.x, r.position.y, r.end.x - door.end.x, r.size.y))
	else:
		if door.position.y > r.position.y:
			out.append(Rect2(r.position.x, r.position.y, r.size.x, door.position.y - r.position.y))
		if door.end.y < r.end.y:
			out.append(Rect2(r.position.x, door.end.y, r.size.x, r.end.y - door.end.y))
	return out


func _iso_poly(pts: Array, c: Color) -> void:
	draw_colored_polygon(PackedVector2Array(pts.map(func(p: Variant) -> Vector2: return Iso.to_screen(p[0], p[1]))), c)


func _draw_iso() -> void:
	# Grass all around, in screen space.
	var sb := Iso.screen_aabb(bounds, WALL_H_BACK)
	draw_rect(sb.grow(1600), Color("#7da36b"))
	for i in 140:
		var gx := sb.position.x - 300 + fmod(i * 137.0, sb.size.x + 600)
		var gy := sb.position.y - 200 + fmod(i * 89.0, sb.size.y + 400)
		draw_circle(Vector2(gx, gy), 3.0, Color("#6e955d"))
		draw_circle(Vector2(gx + 9, gy + 2), 2.0, Color("#8db27a"))
	# Building foundations: a slab edge under each building (skip hub — hex floor).
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue
		var o: Rect2 = (f.rect as Rect2).grow(EXT_WALL)
		var a := Vector2(o.position.x, o.end.y)
		var b := o.end
		var c := Vector2(o.end.x, o.position.y)
		_iso_poly([[a, 0.0], [b, 0.0], [b, -9.0], [a, -9.0]], Color("#8f8778"))
		_iso_poly([[b, 0.0], [c, 0.0], [c, -9.0], [b, -9.0]], Color("#6f685c"))
	# Everything else on the floor plane.
	draw_set_transform_matrix(Iso.floor_xf())
	# Wing entrance paths only — never paint campus-wide door streaks.
	for f: Dictionary in outer_frames:
		if not bool(f.get("wing", false)):
			continue
		var d: Rect2 = f.door
		if d.size.x > d.size.y and d.has_area():
			draw_rect(Rect2(d.position.x + 10, d.position.y, d.size.x - 20, 160.0), Color("#cdbf9f"))
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue
		var o: Rect2 = (f.rect as Rect2).grow(EXT_WALL)
		draw_rect(o, Color("#b3aa99"))  # base under door gaps / wall feet
	for a: Dictionary in areas:
		if a.kind == "corridor":
			_draw_spoke(a)
			continue
		if a.kind == "hub":
			_draw_hub_floor(a)
			continue
		_draw_floor(a)
	for a: Dictionary in areas:
		if a.kind == "hub":
			var hex2 := _hub_hex(a.rect)
			for i in hex2.size():
				draw_line(hex2[i], hex2[(i + 1) % hex2.size()], Color("#455a64", 0.95), 3.0)
	# Subtle 32 px tile grid on rooms only (not corridors / hub AABB).
	for a: Dictionary in areas:
		if a.kind in ["corridor", "hub"]:
			continue
		var r: Rect2 = a.rect
		var gc := Color(0, 0, 0, 0.045)
		var x := ceilf(r.position.x / 32.0) * 32.0
		while x < r.end.x:
			draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), gc, 1.0)
			x += 32.0
		var y := ceilf(r.position.y / 32.0) * 32.0
		while y < r.end.y:
			draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), gc, 1.0)
			y += 32.0
	# Door mats (satellites / wings only — hub has no rect frame).
	for f: Dictionary in outer_frames:
		if bool(f.get("hub", false)):
			continue
		var d: Rect2 = f.door
		if d.has_area():
			draw_rect(d, Color("#8d6e63"))
			draw_rect(d.grow(-3), Color("#a1887f"))
	draw_set_transform_matrix(Transform2D.IDENTITY)
