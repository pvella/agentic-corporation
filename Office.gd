## Office floor plan: builds a layout (rooms, walls, furniture, waypoints,
## signs) from an OFFICE_LAYOUT config and draws the flat parts of it (floors,
## rugs, walls, signs). Furniture that agents can stand behind is drawn by
## y-sorted Prop nodes that Main creates from `props`.
##
## Layout: team rooms and the shared Break Room / Meeting Room / Canteen sit in
## two rows either side of a central corridor, each with a door onto it. A filler
## cell becomes the Lobby (main entrance). Rooms marked "isolated" are built as a
## separate walled wing to the right, with their own door, kitchenette and meeting
## nook, and no connection to the main building.
##
## Waypoint naming (shared with agent_harness.py):
##   Desk_<agent_id> (or the member's "desk"), Coffee_Machine, Water_Cooler,
##   Vending_Machine, Sofa_1/2, Foosball_1..4, Canteen_Counter, Canteen_Seat_1..6,
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
	"corridor": [Color("#bfb6a6"), Color("#b3aa99")],
}

# ---- Built layout (read by Main) ------------------------------------------
var layout_name := ""
var bounds := Rect2()            ## everything incl. outer walls (camera limits)
var walk_rect := Rect2()         ## single traversable outline
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
				spots = ["Coffee_Machine", "Water_Cooler", "Sofa_1", "Sofa_2"]
		room_break_spots[str(r.id)] = spots
		for m: Dictionary in r.get("members", []):
			var aid := str(m.agent_id)
			agent_room[aid] = str(r.id)
			desk_of[aid] = str(m.get("desk", "Desk_" + aid))
			if typeof(m.get("job", null)) == TYPE_DICTIONARY:
				agent_job[aid] = m["job"]

	# --- Grid of cells: top row / corridor / bottom row ----------------------
	var top: Array = []
	var bottom: Array = []
	for i in team_rooms.size():
		(top if i % 2 == 0 else bottom).append({"kind": "team", "room": team_rooms[i]})
	top.insert(mini(1, top.size()), {"kind": "break", "name": str(shared.get("break_room", {}).get("name", "Break Room"))})
	var seats := clampi(int(shared.get("meeting_room", {}).get("seats", 6)), 2, 8)
	bottom.insert(mini(1, bottom.size()), {"kind": "meeting", "name": str(shared.get("meeting_room", {}).get("name", "Meeting Room")), "seats": seats})
	var canteen_name := str(shared.get("canteen", {}).get("name", "Canteen")) if typeof(shared.get("canteen", {})) == TYPE_DICTIONARY else "Canteen"
	# Put the canteen opposite the break room when space allows.
	if top.size() >= bottom.size():
		bottom.insert(mini(2, bottom.size()), {"kind": "canteen", "name": canteen_name})
	else:
		top.insert(mini(2, top.size()), {"kind": "canteen", "name": canteen_name})
	var has_lobby := false
	while bottom.size() < top.size():
		bottom.append({"kind": "lobby" if not has_lobby else "lounge"})
		has_lobby = true
	while top.size() < bottom.size():
		top.append({"kind": "lounge"})
	var cols := top.size()
	var col_w: Array[float] = []
	for c in cols:
		col_w.append(maxf(_cell_size(top[c]).x, _cell_size(bottom[c]).x))
	var h_top := 0.0
	var h_bot := 0.0
	for c in cols:
		h_top = maxf(h_top, _cell_size(top[c]).y)
		h_bot = maxf(h_bot, _cell_size(bottom[c]).y)

	var x0 := ORIGIN.x + EXT_WALL
	var y0 := ORIGIN.y + EXT_WALL + 30.0  # a little sky for the building name
	var total_w := 0.0
	for w in col_w:
		total_w += w
	total_w += WALL * (cols - 1)
	var y_corr := y0 + h_top + WALL
	var y_bot := y_corr + CORRIDOR + WALL
	var b := Rect2(x0, y0, total_w, y_bot + h_bot - y0)

	areas.append({"kind": "corridor", "rect": Rect2(x0, y_corr, total_w, CORRIDOR), "theme": "corridor", "name": ""})
	# Small-talk spot in the corridor, on the wall line between the first two columns.
	_chat("Chat_Corridor", Vector2(x0 + col_w[0] + (WALL * 0.5 if cols > 1 else -60.0), y_corr + CORRIDOR * 0.5 - 8))
	var main_door := Rect2()
	var x := x0
	for c in cols:
		var cell_top := Rect2(x, y0, col_w[c], h_top)
		var cell_bot := Rect2(x, y_bot, col_w[c], h_bot)
		_build_cell(top[c], cell_top, true)
		var lobby_door := _build_cell(bottom[c], cell_bot, false)
		if lobby_door.size.x > 0.0:
			main_door = lobby_door
		if c > 0:
			walls.append(Rect2(x - WALL, y0, WALL, h_top))
			walls.append(Rect2(x - WALL, y_bot, WALL, h_bot))
		_corridor_wall(top[c], Rect2(x - (WALL if c > 0 else 0.0), y0 + h_top, col_w[c] + (WALL if c > 0 else 0.0), WALL))
		_corridor_wall(bottom[c], Rect2(x - (WALL if c > 0 else 0.0), y_corr + CORRIDOR, col_w[c] + (WALL if c > 0 else 0.0), WALL))
		x += col_w[c] + WALL
	if main_door.size.x == 0.0:  # no lobby: entrance at the corridor's left end
		main_door = Rect2(b.position.x - EXT_WALL, y_corr + 16, EXT_WALL, CORRIDOR - 32)
		_wp("Entrance", Vector2(x0 + 30, y_corr + CORRIDOR * 0.5), "right")
	outer_frames.append({"rect": b, "door": main_door, "color": Color("#59606e"), "name": layout_name})

	# --- Isolated wings ------------------------------------------------------
	var right := b.end.x
	for r: Dictionary in wings:
		var wx := right + EXT_WALL * 2.0 + WING_GAP
		var team_size := _team_size(r)
		var wing := Rect2(wx, y0, team_size.x + AMENITY_W, b.size.y)
		obstacles.append(Rect2(right, y0, wx - right, b.size.y))  # the gap between buildings
		var door := _build_wing(r, wing)
		outer_frames.append({"rect": wing, "door": door, "color": Color("#2f3a52"), "name": str(r.get("name", r.id)), "wing": true})
		right = wing.end.x

	walk_rect = Rect2(b.position, Vector2(right - b.position.x, b.size.y))
	bounds = Rect2(ORIGIN - Vector2(20, 20), Vector2(right + EXT_WALL + 20.0 - ORIGIN.x + 20.0, b.end.y + EXT_WALL + 50.0 - ORIGIN.y + 20.0))
	for w in walls:
		obstacles.append(w)
	queue_redraw()


func _reset() -> void:
	obstacles.clear(); areas.clear(); walls.clear(); outer_frames.clear(); props.clear()
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
		"meeting":
			var per_side := ceili(int(cell.seats) / 2.0)
			return Vector2(maxf(360.0, per_side * 84.0 + 190.0), 450)
		_: return Vector2(320, 450)


func _corridor_wall(cell: Dictionary, r: Rect2) -> void:
	if str(cell.kind) in ["lobby", "lounge"]:
		return  # open onto the corridor
	var door_w := 110.0 if str(cell.kind) in ["break", "meeting"] else DOOR
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
	areas.append({"kind": "break", "rect": r, "theme": "tile", "name": cell.name})
	signs.append({"room_id": "", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#6f8fa8"), "clickable": false})
	var p := r.position
	_prop("counter", Rect2(p.x + 92, p.y + 50, 150, 34))
	_prop("coffee", Rect2(p.x + 30, p.y + 44, 52, 42))
	_wp("Coffee_Machine", Vector2(p.x + 56, p.y + 112), "up")
	_prop("water", Rect2(r.end.x - 66, p.y + 44, 40, 44))
	_prop("vending", Rect2(p.x + 264, p.y + 42, 44, 40))
	_wp("Vending_Machine", Vector2(p.x + 286, p.y + 114), "up")
	_chat("Chat_Break", Vector2(p.x + 190, p.y + 200))  # open floor between sofa and counter
	_wp("Water_Cooler", Vector2(r.end.x - 46, p.y + 114), "down")
	var sofa := Rect2(p.x + 22, p.y + 296, 156, 46)
	_prop("sofa", sofa)
	_wp("Sofa_1", Vector2(sofa.position.x + 48, sofa.position.y + 26), "down", "sofa")
	_wp("Sofa_2", Vector2(sofa.position.x + 108, sofa.position.y + 26), "down", "sofa")
	var table := Rect2(r.end.x - 186, p.y + 296, 120, 58)
	_prop("foosball", table)
	_wp("Foosball_1", Vector2(table.position.x - 22, table.position.y + 22), "right", "foosball")
	_wp("Foosball_2", Vector2(table.end.x + 22, table.position.y + 22), "left", "foosball")
	_wp("Foosball_3", Vector2(table.position.x - 22, table.position.y + 50), "right", "foosball")
	_wp("Foosball_4", Vector2(table.end.x + 22, table.position.y + 50), "left", "foosball")
	_prop("plant", Rect2(p.x + 14, r.end.y - 50, 34, 34))



func _build_canteen(cell: Dictionary, r: Rect2) -> void:
	areas.append({"kind": "canteen", "rect": r, "theme": "tile", "name": cell.name})
	signs.append({"room_id": "", "name": str(cell.name), "rect": _sign_rect(r, str(cell.name)), "color": Color("#c47a4a"), "clickable": false})
	var p := r.position
	# Serving counter with sneeze guard + trays of food along the back wall.
	_prop("counter", Rect2(p.x + 28, p.y + 42, 200, 40), {"set": "canteen"})
	# Menu board on the wall above / beside the counter.
	_prop("menu", Rect2(p.x + 40, p.y + 10, 72, 28), {"sort_y": p.y + 20.0})
	# Drinks fridge, coffee machine, microwave.
	_prop("fridge", Rect2(p.x + 240, p.y + 36, 40, 52))
	_prop("coffee", Rect2(p.x + 290, p.y + 44, 48, 40))
	_prop("microwave", Rect2(p.x + 348, p.y + 52, 36, 28))
	# Bin near the exit.
	_prop("bin", Rect2(r.end.x - 40, r.end.y - 56, 22, 22))
	_wp("Canteen_Counter", Vector2(p.x + 130, p.y + 108), "up")
	# Long dining tables with chairs and place settings.
	var tables := [
		Vector2(p.x + 36, p.y + 170),
		Vector2(p.x + 200, p.y + 170),
		Vector2(p.x + 100, p.y + 290),
	]
	var seat_i := 1
	for tpos in tables:
		var table := Rect2(tpos.x, tpos.y, 96, 52)
		_prop("table", table, {"set": "canteen"})
		_wp("Canteen_Seat_%d" % seat_i, Vector2(table.position.x - 18, table.get_center().y), "right", "chair")
		seat_i += 1
		_wp("Canteen_Seat_%d" % seat_i, Vector2(table.end.x + 18, table.get_center().y), "left", "chair")
		seat_i += 1
		_prop("chair", Rect2(table.position.x - 28, table.get_center().y - 12, 24, 24))
		_prop("chair", Rect2(table.end.x + 4, table.get_center().y - 12, 24, 24))
	_prop("plant", Rect2(r.end.x - 44, p.y + 16, 30, 30))
	_chat("Chat_Canteen", Vector2(p.x + r.size.x * 0.5, r.end.y - 40))


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
	if kind != "chair":
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
	return _outline(walk_rect)


func get_obstacle_outlines() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for r in obstacles:
		out.append(_outline(r))
	return out


func _outline(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


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
	# Paths from the doors.
	for f: Dictionary in outer_frames:
		var d: Rect2 = f.door
		if d.size.x > 0.0:
			if d.size.x > d.size.y:
				draw_rect(Rect2(d.position.x + 10, d.position.y, d.size.x - 20, bounds.end.y - d.position.y + 400), Color("#cdbf9f"))
			else:
				draw_rect(Rect2(bounds.position.x - 400, d.position.y + 8, d.position.x - bounds.position.x + 400, d.size.y - 16), Color("#cdbf9f"))
	# Floors (a base under each building first, so door gaps aren't grass).
	for f: Dictionary in outer_frames:
		draw_rect(f.rect, Color("#b3aa99"))
	for a: Dictionary in areas:
		_draw_floor(a)
	# Corridor runner.
	for a: Dictionary in areas:
		if a.kind == "corridor":
			var r: Rect2 = a.rect
			draw_rect(Rect2(r.position.x + 20, r.position.y + r.size.y * 0.5 - 16, r.size.x - 40, 32), Color("#9c5b4a", 0.55))
			draw_rect(Rect2(r.position.x + 24, r.position.y + r.size.y * 0.5 - 12, r.size.x - 48, 24), Color("#b7735f", 0.45), false, 2.0)
	# Building names on the roof edge.
	for f: Dictionary in outer_frames:
		var r: Rect2 = f.rect
		draw_string(_font, Vector2(r.position.x, r.position.y - EXT_WALL - 10), str(f.name).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.85))
	# Walls.
	for w in walls:
		_draw_wall(w, Color("#6b7280"))
	for f: Dictionary in outer_frames:
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


func _draw_wall(w: Rect2, c: Color) -> void:
	# Top face + a darker front face, for a hint of 3/4 depth.
	draw_rect(w, c)
	draw_rect(Rect2(w.position.x, w.end.y - 4, w.size.x, 4), c.darkened(0.35))
	draw_rect(Rect2(w.position.x, w.position.y, w.size.x, 2), c.lightened(0.25))


func _draw_frame(f: Dictionary) -> void:
	var r: Rect2 = f.rect
	var c: Color = f.color
	var o := r.grow(EXT_WALL)
	var parts := [Rect2(o.position, Vector2(o.size.x, EXT_WALL)), Rect2(o.position.x, r.end.y, o.size.x, EXT_WALL),
		Rect2(o.position, Vector2(EXT_WALL, o.size.y)), Rect2(r.end.x, o.position.y, EXT_WALL, o.size.y)]
	for p: Rect2 in parts:
		_draw_wall(p, c)
	var d: Rect2 = f.door
	if d.size.x > 0.0:
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
	# Building foundations: a slab edge under each building.
	for f: Dictionary in outer_frames:
		var o: Rect2 = (f.rect as Rect2).grow(EXT_WALL)
		var a := Vector2(o.position.x, o.end.y)
		var b := o.end
		var c := Vector2(o.end.x, o.position.y)
		_iso_poly([[a, 0.0], [b, 0.0], [b, -9.0], [a, -9.0]], Color("#8f8778"))
		_iso_poly([[b, 0.0], [c, 0.0], [c, -9.0], [b, -9.0]], Color("#6f685c"))
	# Everything else on the floor plane.
	draw_set_transform_matrix(Iso.floor_xf())
	for f: Dictionary in outer_frames:
		var d: Rect2 = f.door
		if d.size.x > d.size.y:
			draw_rect(Rect2(d.position.x + 10, d.position.y, d.size.x - 20, bounds.end.y - d.position.y + 600), Color("#cdbf9f"))
		elif d.has_area():
			draw_rect(Rect2(bounds.position.x - 600, d.position.y + 8, d.position.x - bounds.position.x + 600, d.size.y - 16), Color("#cdbf9f"))
	for f: Dictionary in outer_frames:
		var o: Rect2 = (f.rect as Rect2).grow(EXT_WALL)
		draw_rect(o, Color("#b3aa99"))  # base under door gaps / wall feet
	for a: Dictionary in areas:
		_draw_floor(a)
	for a: Dictionary in areas:
		if a.kind == "corridor":
			var r: Rect2 = a.rect
			draw_rect(Rect2(r.position.x + 20, r.position.y + r.size.y * 0.5 - 16, r.size.x - 40, 32), Color("#9c5b4a", 0.55))
			draw_rect(Rect2(r.position.x + 24, r.position.y + r.size.y * 0.5 - 12, r.size.x - 48, 24), Color("#b7735f", 0.45), false, 2.0)
	# Subtle 32 px tile grid so the floor reads as Habbo-style diamonds.
	for a: Dictionary in areas:
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
	# Door mats.
	for f: Dictionary in outer_frames:
		var d: Rect2 = f.door
		if d.has_area():
			draw_rect(d, Color("#8d6e63"))
			draw_rect(d.grow(-3), Color("#a1887f"))
	draw_set_transform_matrix(Transform2D.IDENTITY)
