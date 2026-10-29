## A y-sorted piece of furniture. Main creates one per Office.props entry and
## parents it under World/Props, so agents walking behind a desk, sofa or
## table are correctly hidden by it.
##
## Desks show their owner's monitor: scrolling code in the agent's colour
## while it works at the desk, a dim screensaver otherwise. The foosball table
## animates (spinning rods, rolling ball) while `playing` is true.
##
## In the isometric view (Iso.enabled) the same props are drawn as shaded
## boxes (top + south + east faces). Long pieces (tables, counters, walls ...)
## are split by Main into several Prop nodes, each drawing only its `clip`
## slice, so the y-sort (screen y of the slice anchor = world x + y) stays
## correct for people walking around them. Walls are props too in iso
## ("wall" kind) so they sort with people.
extends Node2D

const Office := preload("res://Office.gd")
const Iso := preload("res://Iso.gd")

var kind := ""
var rect := Rect2()          ## world-space footprint
var data: Dictionary = {}
var owner_agent: Node = null ## Agent at this desk (desks only)
var playing := false         ## foosball only

var clip := Rect2()          ## iso: the part of `rect` this node draws
var _t := 0.0
var _font: Font


func setup(d: Dictionary, slice: Rect2 = Rect2()) -> void:
	kind = str(d.kind)
	rect = d.rect
	data = d
	clip = slice if slice.has_area() else rect
	_font = ThemeDB.fallback_font
	if Iso.enabled:
		position = Iso.to_screen(iso_anchor())
	else:
		position = Vector2(rect.position.x, float(d.get("sort_y", rect.end.y))) * Iso.SCALE
	set_process(kind in ["desk", "foosball", "servers", "coffee", "water", "plant", "vending", "fridge", "microwave"])


## World point whose depth (x + y) orders this prop against people.
func iso_anchor() -> Vector2:
	match kind:
		"chair":
			return Vector2(rect.get_center().x, float(data.get("sort_y", rect.end.y)))
		"chairback":
			return Vector2(rect.get_center().x, rect.position.y + 4.0)
		"sofa":
			# Seat + left arm: drawn before whoever sits on it.
			return Vector2(rect.position.x + 10.0, rect.position.y + 18.0)
		"sofaarm":
			return clip.get_center() + Vector2(0, 6)
		"sofaback":
			return Vector2(clip.get_center().x, rect.position.y)
	return clip.get_center()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	if Iso.enabled:
		_draw_iso()
		return
	# Draw in world coordinates (the node origin is only used for y-sorting).
	draw_set_transform(-position, 0.0, Vector2.ONE * Iso.SCALE)
	match kind:
		"desk": _draw_desk()
		"chair": _draw_chair()
		"coffee": _draw_coffee()
		"counter": _draw_counter()
		"water": _draw_water()
		"sofa": _draw_sofa()
		"foosball": _draw_foosball()
		"table": _draw_table()
		"plant": _draw_plant()
		"reception": _draw_reception()
		"bench": _draw_bench()
		"servers": _draw_servers()
		"vending": _draw_vending()
		"fridge": _draw_fridge()
		"menu": _draw_menu()
		"microwave": _draw_microwave()
		"bin": _draw_bin()


func _rr(r: Rect2, radius: float, c: Color) -> void:
	draw_colored_polygon(Office.rounded_rect_points(r, radius), c)


func _shadow(r: Rect2, alpha: float = 0.18) -> void:
	_rr(Rect2(r.position + Vector2(3, 5), r.size), 6, Color(0, 0, 0, alpha))


# ---------------------------------------------------------------------------
func _is_executive_desk() -> bool:
	return str(data.get("style", "")) == "executive"


func _is_executive_chair() -> bool:
	return str(data.get("style", "")) == "executive"


func _draw_exec_nameplate(r: Rect2) -> void:
	var label := str(data.get("owner", ""))
	if owner_agent != null and is_instance_valid(owner_agent):
		if "display_name" in owner_agent:
			label = str(owner_agent.display_name)
	if label.is_empty():
		label = "Chief of Staff"
	if label.length() > 18:
		label = label.substr(0, 18)
	var plate := Rect2(r.position.x + r.size.x * 0.55 - 36, r.end.y - 10, 72, 8)
	_rr(plate, 2, Color("#c9a227"))
	_rr(plate.grow(-1.0), 1, Color("#3e2723"))
	draw_string(_font, Vector2(plate.position.x + 4, plate.end.y - 2), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color("#ffe082"))


func _draw_desk() -> void:
	var r := rect
	_shadow(r)
	# Legs, top surface, darker front edge.
	draw_rect(Rect2(r.position.x + 4, r.end.y - 4, 5, 8), Color("#5d4037"))
	draw_rect(Rect2(r.end.x - 9, r.end.y - 4, 5, 8), Color("#5d4037"))
	_rr(r, 4, Color("#6d4c41"))
	_rr(Rect2(r.position, Vector2(r.size.x, r.size.y - 8)), 4, Color("#a1887f"))
	draw_rect(Rect2(r.position.x + 3, r.position.y + 3, r.size.x - 6, 2), Color(1, 1, 1, 0.18))

	if _is_executive_desk():
		# L-return wing on the left (same wood as top).
		var wing := Rect2(r.position.x, r.position.y, 40, 78)
		_shadow(wing)
		_rr(wing, 4, Color("#5d4037"))
		_rr(Rect2(wing.position, Vector2(wing.size.x, wing.size.y - 8)), 4, Color("#8d6e63"))
		# Dual monitors on the far edge.
		for side: int in [-1, 1]:
			var mx: float = r.position.x + r.size.x * 0.62 + float(side) * 34.0
			var mon := Rect2(mx - 28, r.position.y - 42, 56, 40)
			draw_rect(Rect2(mon.get_center().x - 3, mon.end.y - 2, 6, 8), Color("#37474f"))
			draw_rect(Rect2(mon.get_center().x - 10, mon.end.y + 5, 20, 3), Color("#37474f"))
			_rr(mon.grow(1.5), 4, Color("#1c2328"))
			_rr(mon, 3, Color("#263238"))
			_draw_screen(mon.grow(-3.0))
		var kb := Rect2(r.position.x + r.size.x * 0.55 - 24, r.position.y + 16, 48, 9)
		_draw_keyboard(kb)
		draw_rect(Rect2(r.end.x - 18, r.position.y + 10, 9, 11), Color("#fafafa"))
		_draw_exec_nameplate(r)
	else:
		# Monitor: stands on the far edge, screen facing us (the agent sits in front).
		var mon := Rect2(r.position.x + r.size.x * 0.5 - 32, r.position.y - 40, 64, 44)
		draw_rect(Rect2(mon.get_center().x - 4, mon.end.y - 2, 8, 9), Color("#37474f"))
		draw_rect(Rect2(mon.get_center().x - 12, mon.end.y + 6, 24, 3), Color("#37474f"))
		_rr(mon.grow(1.5), 4, Color("#1c2328"))
		_rr(mon, 3, Color("#263238"))
		_draw_screen(mon.grow(-3.5))
		# Keyboard + mouse on the near edge, mug on the side.
		var kb := Rect2(r.position.x + r.size.x * 0.5 - 22, r.position.y + 14, 44, 9)
		_draw_keyboard(kb)
		draw_rect(Rect2(r.position.x + 7, r.position.y + 10, 9, 11), Color("#fafafa"))
		draw_rect(Rect2(r.position.x + 8, r.position.y + 11, 7, 3), Color("#6d4c41"))
		if (owner_agent == null or not is_instance_valid(owner_agent)) and str(data.get("owner", "")) == "":
			draw_string(_font, Vector2(r.position.x + 22, r.end.y - 11), "free desk", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0, 0, 0, 0.35))


func _draw_keyboard(kb: Rect2) -> void:
	_rr(kb, 2, Color("#cfd8dc"))
	for k in 5:
		draw_line(kb.position + Vector2(4 + k * 8, 3), kb.position + Vector2(8 + k * 8, 3), Color("#90a4ae"), 1.0)
	draw_line(kb.position + Vector2(8, 6), kb.position + Vector2(36, 6), Color("#90a4ae"), 1.0)
	_rr(Rect2(kb.end.x + 7, kb.position.y + 1, 7, 9), 3, Color("#eceff1"))


## Monitor contents (in whatever transform is current): code scrolling in the
## owner's colour while it works, a red error screen, or a dim screensaver.
func _draw_screen(screen: Rect2) -> void:
	var agent := owner_agent if is_instance_valid(owner_agent) else null
	var col := Color.from_string(str(data.get("color", "")), Color("#4fc3f7"))
	if agent:
		col = agent.body_color
	var active: bool = agent != null and agent.is_seated_at_desk() and agent.state in ["WORKING", "THINKING"]
	if agent != null and agent.is_seated_at_desk() and agent.state == "ERROR":
		# Error screen: dark red with a blinking warning bar.
		draw_rect(screen, Color("#3b0d0d"))
		draw_rect(Rect2(screen.position.x + 4, screen.position.y + 5, screen.size.x - 8, 6), Color("#e53935", 0.9 if fmod(_t, 1.0) < 0.6 else 0.45))
		for i in 3:
			draw_line(Vector2(screen.position.x + 5, screen.position.y + 17 + i * 5), Vector2(screen.position.x + 12 + (i * 9) % 22, screen.position.y + 17 + i * 5), Color("#ef9a9a", 0.8), 1.6)
	elif active:
		draw_rect(screen, Color("#0d1b24"))
		# Scrolling code lines in the agent's colour.
		var line_h := 4.0
		var speed := 9.0 if agent.state == "WORKING" else 2.0
		var scroll := fmod(_t * speed, line_h)
		var first := int(_t * speed / line_h)
		var y := screen.position.y + 2.0 - scroll
		var i := 0
		while y < screen.end.y - 2.0:
			if y > screen.position.y:
				var seed := (first + i) * 7919 + int(rect.position.x)
				var indent := float((seed % 4) * 4)
				var w := 8.0 + float((seed / 5) % 26)
				var lc := col.lightened(0.35) if (seed % 5) != 0 else Color("#e5c07b")
				draw_line(Vector2(screen.position.x + 3 + indent, y), Vector2(minf(screen.position.x + 3 + indent + w, screen.end.x - 3), y), Color(lc, 0.9), 1.6)
			y += line_h
			i += 1
		# Screen glow + blinking cursor.
		draw_rect(screen, Color(col, 0.10))
		if fmod(_t, 1.0) < 0.5:
			draw_rect(Rect2(screen.position.x + 4, screen.end.y - 5, 4, 2), Color.WHITE)
	else:
		# Dim screensaver: a slow drifting dot.
		draw_rect(screen, Color("#10161a"))
		var p := screen.position + Vector2(
			screen.size.x * (0.5 + 0.42 * sin(_t * 0.7 + rect.position.x)),
			screen.size.y * (0.5 + 0.38 * sin(_t * 0.9 + rect.position.y)))
		draw_circle(p, 2.2, Color(col, 0.35))
		draw_circle(p, 4.5, Color(col, 0.08))
	draw_rect(Rect2(screen.position, Vector2(screen.size.x, 2)), Color(1, 1, 1, 0.06))


func _draw_chair() -> void:
	# Office chair seen from behind: the back covers the sitter's lower back.
	var r := rect
	var c := r.get_center()
	var exec := _is_executive_chair()
	var base := Color("#3e2723") if exec else Color("#263238")
	var seat := Color("#5d4037") if exec else Color("#455a64")
	var stem := Color("#4e342e") if exec else Color("#37474f")
	draw_circle(Vector2(c.x, r.end.y + 1), 10.0 if exec else 9.0, Color(0, 0, 0, 0.15))
	draw_line(Vector2(c.x, r.end.y - 6), Vector2(c.x, r.end.y + 2), stem, 3.5 if exec else 3.0)
	for dx: float in ([-10.0, -3.0, 3.0, 10.0] if exec else [-8.0, 0.0, 8.0]):
		draw_circle(Vector2(c.x + dx, r.end.y + 2), 1.8, base)
	_rr(Rect2(r.position.x - 1, r.position.y + 6, r.size.x + 2, r.size.y - 10), 6, base)
	_rr(Rect2(r.position.x + 2, r.position.y + 8, r.size.x - 4, r.size.y - 15), 5, seat)
	draw_line(Vector2(r.position.x + 6, r.position.y + 11), Vector2(r.end.x - 6, r.position.y + 11), Color(1, 1, 1, 0.15), 1.5)
	if exec:
		# High back + brass rivets.
		_rr(Rect2(r.position.x + 4, r.position.y - 4, r.size.x - 8, 12), 4, base)
		draw_circle(Vector2(r.position.x + 8, r.position.y + 14), 1.4, Color("#c9a227"))
		draw_circle(Vector2(r.end.x - 8, r.position.y + 14), 1.4, Color("#c9a227"))


func _draw_coffee() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 5, Color("#3e2723"))
	_rr(Rect2(r.position + Vector2(4, 4), Vector2(r.size.x - 8, 14)), 3, Color("#c62828"))
	draw_circle(r.position + Vector2(r.size.x - 12, 11), 2.5, Color("#69f0ae") if fmod(_t, 2.0) < 1.6 else Color("#1b5e20"))
	draw_rect(Rect2(r.position.x + r.size.x * 0.5 - 7, r.position.y + 22, 14, 3), Color("#212121"))
	_rr(Rect2(r.position.x + r.size.x * 0.5 - 5, r.end.y - 14, 10, 10), 2, Color("#fafafa"))
	# Steam.
	for i in 2:
		var s := fmod(_t * 12.0 + i * 8.0, 16.0)
		draw_circle(Vector2(r.position.x + r.size.x * 0.5 + sin(_t * 3.0 + i) * 2.0, r.end.y - 16 - s), 2.0, Color(1, 1, 1, 0.35 * (1.0 - s / 16.0)))


func _draw_counter() -> void:
	var r := rect
	_shadow(r, 0.12)
	_rr(r, 3, Color("#b0bec5"))
	_rr(Rect2(r.position, Vector2(r.size.x, r.size.y - 7)), 3, Color("#eceff1"))
	_rr(Rect2(r.position.x + r.size.x - 52, r.position.y + 5, 40, 16), 4, Color("#b0bec5"))
	draw_circle(Vector2(r.position.x + 30, r.position.y + 12), 7.0, Color("#ffcc80"))  # fruit bowl
	draw_circle(Vector2(r.position.x + 27, r.position.y + 10), 3.0, Color("#e53935"))
	draw_circle(Vector2(r.position.x + 33, r.position.y + 11), 3.0, Color("#fdd835"))


func _draw_water() -> void:
	var r := rect
	_shadow(r)
	_rr(Rect2(r.position.x + 4, r.position.y + 18, r.size.x - 8, r.size.y - 18), 4, Color("#eceff1"))
	draw_rect(Rect2(r.position.x + 8, r.position.y + 30, r.size.x - 16, 4), Color("#90a4ae"))
	_rr(Rect2(r.position.x + 7, r.position.y - 6, r.size.x - 14, 26), 9, Color("#4fc3f7", 0.85))
	draw_rect(Rect2(r.position.x + 11, r.position.y - 2, 4, 16), Color(1, 1, 1, 0.45))
	var bub := fmod(_t * 10.0, 20.0)
	draw_circle(Vector2(r.position.x + r.size.x * 0.5 + 3, r.position.y + 16 - bub), 1.5, Color(1, 1, 1, 0.7))


func _draw_sofa() -> void:
	var r := rect
	_shadow(r)
	_rr(Rect2(r.position.x, r.position.y + 6, r.size.x, r.size.y - 6), 8, Color("#283593"))
	_rr(Rect2(r.position.x + 14, r.position.y + 8, r.size.x - 28, r.size.y - 18), 6, Color("#5c6bc0"))
	draw_line(Vector2(r.get_center().x, r.position.y + 10), Vector2(r.get_center().x, r.end.y - 12), Color("#3f51b5"), 2.0)
	_rr(Rect2(r.position.x, r.position.y, 16, r.size.y), 7, Color("#3949ab"))
	_rr(Rect2(r.end.x - 16, r.position.y, 16, r.size.y), 7, Color("#3949ab"))


func _draw_foosball() -> void:
	var r := rect
	_shadow(r, 0.22)
	# Legs + cabinet.
	for lx: float in [r.position.x + 6, r.end.x - 12]:
		draw_rect(Rect2(lx, r.end.y - 4, 6, 10), Color("#3e2723"))
	_rr(r, 5, Color("#5d4037"))
	var field := r.grow(-6)
	draw_rect(field, Color("#2e7d32"))
	draw_rect(field, Color(1, 1, 1, 0.5), false, 1.0)
	draw_line(Vector2(field.get_center().x, field.position.y), Vector2(field.get_center().x, field.end.y), Color(1, 1, 1, 0.45), 1.0)
	draw_arc(field.get_center(), 7.0, 0, TAU, 16, Color(1, 1, 1, 0.45), 1.0)
	# Goals.
	draw_rect(Rect2(field.position.x - 3, field.get_center().y - 8, 3, 16), Color("#eeeeee"))
	draw_rect(Rect2(field.end.x, field.get_center().y - 8, 3, 16), Color("#eeeeee"))
	# Ball.
	var ball := field.get_center()
	if playing:
		ball += Vector2(sin(_t * 2.3) * field.size.x * 0.42, sin(_t * 3.7 + 1.0) * field.size.y * 0.36)
	draw_circle(ball + Vector2(1, 1), 2.6, Color(0, 0, 0, 0.3))
	draw_circle(ball, 2.6, Color.WHITE)
	# Rods with little players; they slide and flip while a game is on.
	var rods := 4
	for i in rods:
		var x := field.position.x + field.size.x * (i + 0.5) / rods
		var team_red := i % 2 == 0
		var col := Color("#e53935") if team_red else Color("#1e88e5")
		draw_line(Vector2(x, r.position.y - 6), Vector2(x, r.end.y + 6), Color("#b0bec5"), 2.0)
		draw_circle(Vector2(x, r.position.y - 7), 2.5, Color("#212121"))
		draw_circle(Vector2(x, r.end.y + 7), 2.5, Color("#212121"))
		var slide := sin(_t * (5.0 + i) + i) * 6.0 if playing else 0.0
		var spin := sin(_t * (9.0 + i * 1.7)) if playing else 1.0  # >0 upright, <0 flipped
		for k in 2:
			var py := field.position.y + field.size.y * (0.3 + 0.4 * k) + slide
			var len := 5.0 * spin
			draw_rect(Rect2(x - 2.5, py - maxf(len, 0.0) - 2.0, 5, absf(len) + 4.0), col)
			draw_circle(Vector2(x, py), 2.0, col.lightened(0.3))


func _draw_table() -> void:
	var r := rect
	_shadow(r, 0.22)
	_rr(r, 8, Color("#5d4037"))
	_rr(Rect2(r.position, Vector2(r.size.x, r.size.y - 8)), 8, Color("#8d6e63"))
	draw_rect(Rect2(r.position.x + 8, r.position.y + 4, r.size.x - 16, 2), Color(1, 1, 1, 0.15))
	# Papers, laptop and mugs.
	var n := int(r.size.x / 70.0)
	for i in n:
		var px := r.position.x + 24 + i * (r.size.x - 48) / maxf(n - 1, 1)
		draw_rect(Rect2(px - 9, r.position.y + 14 + (i % 2) * 14, 18, 13), Color(1, 1, 1, 0.85))
	draw_circle(Vector2(r.end.x - 20, r.position.y + 14), 4.0, Color("#fafafa"))


func _draw_plant() -> void:
	var r := rect
	var c := r.get_center()
	draw_circle(c + Vector2(3, 8), r.size.x * 0.42, Color(0, 0, 0, 0.18))
	_rr(Rect2(c.x - 9, c.y, 18, 15), 4, Color("#8d6e63"))
	_rr(Rect2(c.x - 10, c.y - 2, 20, 5), 2, Color("#6d4c41"))
	var sway := sin(_t * 1.2 + r.position.x) * 1.0
	draw_circle(c + Vector2(-7 + sway, -6), 9, Color("#2e7d32"))
	draw_circle(c + Vector2(7 + sway, -7), 9, Color("#388e3c"))
	draw_circle(c + Vector2(sway, -15), 10, Color("#43a047"))
	draw_circle(c + Vector2(-3 + sway, -17), 4, Color("#66bb6a"))


func _draw_reception() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 8, Color("#455a64"))
	_rr(Rect2(r.position, Vector2(r.size.x, r.size.y - 9)), 8, Color("#eceff1"))
	draw_string(_font, Vector2(r.position.x + 22, r.end.y - 2), "RECEPTION", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.85))
	draw_circle(Vector2(r.position.x + 20, r.position.y + 12), 5, Color("#ffca28"))


func _draw_bench() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 6, Color("#6d4c41"))
	_rr(r.grow(-4), 5, Color("#a1887f"))


func _draw_servers() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 3, Color("#212121"))
	for i in int(r.size.y / 18.0):
		var y := r.position.y + 8 + i * 18
		draw_rect(Rect2(r.position.x + 5, y, r.size.x - 10, 10), Color("#424242"))
		var on := fmod(_t * (1.0 + i * 0.3), 1.0) < 0.7
		draw_circle(Vector2(r.end.x - 10, y + 5), 2.0, Color("#69f0ae") if on else Color("#1b5e20"))


func _draw_vending() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 4, Color("#b71c1c"))
	_rr(Rect2(r.position.x + 4, r.position.y + 4, r.size.x - 8, r.size.y - 14), 3, Color("#263238"))
	for i in 3:
		for j in 2:
			draw_circle(r.position + Vector2(12 + i * 10, 12 + j * 10), 3.0, [Color("#4fc3f7"), Color("#ffca28"), Color("#81c784")][(i + j) % 3])


# ===========================================================================
# Isometric drawing
# ===========================================================================
const WALL_TOP := Color("#d5d9e0")

## Screen point (in this node's local space) of world point `w` at height `z`.
func _p(w: Vector2, z: float = 0.0) -> Vector2:
	return Iso.to_screen(w, z) - position


func _poly(pts: Array, c: Color) -> void:
	draw_colored_polygon(PackedVector2Array(pts), c)


## A shaded box standing on world footprint `r` from height z0 to z0 + h,
## clipped to this node's slice. `south`/`east` override the face colours.
func _box(r: Rect2, z0: float, h: float, top: Color, south: Color = Color(0, 0, 0, 0), east: Color = Color(0, 0, 0, 0), edge: bool = true) -> void:
	var full := r
	r = r.intersection(clip)
	if r.size.x < 0.01 or r.size.y < 0.01:
		return
	var z1 := z0 + h
	var a := r.position
	var b := Vector2(r.end.x, r.position.y)
	var c := r.end
	var d := Vector2(r.position.x, r.end.y)
	if south.a == 0.0:
		south = top.darkened(0.2)
	if east.a == 0.0:
		east = top.darkened(0.36)
	if h > 0.0:
		_poly([_p(d, z0), _p(c, z0), _p(c, z1), _p(d, z1)], south)
		_poly([_p(b, z0), _p(c, z0), _p(c, z1), _p(b, z1)], east)
	_poly([_p(a, z1), _p(b, z1), _p(c, z1), _p(d, z1)], top)
	if edge:
		var hl := Color(top.lightened(0.35), 0.55)
		if r.end.y >= full.end.y - 0.01:
			draw_line(_p(d, z1), _p(c, z1), hl, 1.0)
		if r.end.x >= full.end.x - 0.01:
			draw_line(_p(c, z1), _p(b, z1), hl, 1.0)


## Switch drawing to the floor-parallel plane at height z (world coordinates).
func _plane_top(z: float) -> void:
	draw_set_transform_matrix(Iso.floor_xf(z, -position))


## Vertical plane at world y = y0 facing south: x = world x, y = px below z_top.
func _plane_south(y0: float, z_top: float) -> void:
	draw_set_transform_matrix(Iso.south_xf(y0, z_top, -position))


## Vertical plane at world x = x0 facing east: x = world y, y = px below z_top.
func _plane_east(x0: float, z_top: float) -> void:
	draw_set_transform_matrix(Iso.east_xf(x0, z_top, -position))


## Billboard: upright drawing at screen point `p`, scaled like the world.
func _bb(p: Vector2) -> void:
	draw_set_transform(p, 0, Vector2.ONE * Iso.SCALE)


func _plane_reset() -> void:
	draw_set_transform_matrix(Transform2D.IDENTITY)


## Soft contact shadow on the floor under this slice of `r`.
func _floor_shadow(r: Rect2, alpha: float = 0.16) -> void:
	var s := Rect2(r.position + Vector2(2, 3), r.size).intersection(clip.grow_individual(0, 0, 3, 4))
	if not s.has_area():
		return
	_plane_top(0.0)
	draw_rect(s, Color(0, 0, 0, alpha))
	_plane_reset()


## True for the slice drawn last (east/south-most): details that straddle
## slices are drawn by it so later slices don't paint over them.
func _last_slice() -> bool:
	return clip.end.x >= rect.end.x - 0.5 and clip.end.y >= rect.end.y - 0.5


func _in_clip(p: Vector2) -> bool:
	return clip.grow(0.01).has_point(p)


func _draw_iso() -> void:
	match kind:
		"desk": _iso_desk()
		"chair": _iso_chair()
		"chairback": _iso_chairback()
		"coffee": _iso_coffee()
		"counter": _iso_counter()
		"water": _iso_water()
		"vending": _iso_vending()
		"sofa": _iso_sofa_seat()
		"sofaarm": _box(rect, 0, 26, Color("#3949ab"))
		"sofaback": _iso_sofa_back()
		"foosball": _iso_foosball()
		"table": _iso_table()
		"plant": _iso_plant()
		"reception": _iso_reception()
		"bench": _iso_bench()
		"servers": _iso_servers()
		"wall": _iso_wall()
		"whiteboard": _iso_whiteboard()
		"fridge": _iso_fridge()
		"menu": _iso_menu()
		"microwave": _iso_microwave()
		"bin": _iso_bin()
		_: _box(rect, 0, 20, Color("#90a4ae"))


func _legs(r: Rect2, h: float, c: Color, inset: float = 3.0, size: float = 4.0) -> void:
	for p: Vector2 in [r.position + Vector2(inset, inset), Vector2(r.end.x - inset - size, r.position.y + inset),
			Vector2(r.position.x + inset, r.end.y - inset - size), r.end - Vector2(inset + size, inset + size)]:
		_box(Rect2(p, Vector2(size, size)), 0, h, c, Color(0, 0, 0, 0), Color(0, 0, 0, 0), false)


const DESK_H := 26.0

func _iso_desk() -> void:
	var r := rect
	_floor_shadow(r)
	_legs(r, DESK_H - 4.0, Color("#5d4037"))
	# Modesty panel along the back so the desk reads as a solid piece.
	_box(Rect2(r.position.x + 3, r.position.y + 3, r.size.x - 6, 3), 6, DESK_H - 10, Color("#6d4c41"))
	_box(r, DESK_H - 4.0, 4.0, Color("#a1887f"), Color("#7b5e57"), Color("#6d4c41"))
	# Desk-top clutter: keyboard + mouse near the sitter, a mug.
	_plane_top(DESK_H)
	draw_rect(Rect2(r.position.x + 3, r.position.y + 3, r.size.x - 6, 2), Color(1, 1, 1, 0.16))
	_draw_keyboard(Rect2(r.position.x + r.size.x * 0.5 - 22, r.position.y + 18, 44, 9))
	if (owner_agent == null or not is_instance_valid(owner_agent)) and str(data.get("owner", "")) == "":
		draw_string(_font, Vector2(r.position.x + 8, r.end.y - 4), "free desk", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0, 0, 0, 0.35))
	_plane_reset()
	var cx := r.get_center().x
	_box(Rect2(r.position.x + 8, r.position.y + 10, 7, 7), DESK_H, 9, Color("#fafafa"))  # mug
	if _is_executive_desk():
		# L-return wing (left) + dual monitors (executive dual iso).
		var wing := Rect2(r.position.x, r.position.y, 40, 78)
		_box(wing, DESK_H - 4.0, 4.0, Color("#8d6e63"), Color("#6d4c41"), Color("#5d4037"))
		var z0 := DESK_H + 8.0
		var mh := 38.0
		for side: int in [-1, 1]:
			var mx: float = cx + 12.0 + float(side) * 30.0
			_box(Rect2(mx - 2, r.position.y + 5, 4, 4), DESK_H, 10, Color("#37474f"))
			var mon := Rect2(mx - 26, r.position.y + 3, 52, 5)
			_box(mon, z0, mh, Color("#2b343a"), Color("#1c2328"), Color("#151b1f"))
			_plane_south(mon.end.y, z0 + mh)
			draw_rect(Rect2(mx - 24, 2, 48, mh - 4), Color("#263238"))
			_draw_screen(Rect2(mx - 22.5, 3.5, 45, mh - 7))
			_plane_reset()
		_plane_top(DESK_H)
		_draw_exec_nameplate(r)
		_plane_reset()
	else:
		# Monitor on the far edge, screen facing the sitter (south).
		_box(Rect2(cx - 3, r.position.y + 5, 6, 4), DESK_H, 10, Color("#37474f"))
		_box(Rect2(cx - 10, r.position.y + 4, 20, 8), DESK_H, 1.5, Color("#37474f"))
		var mon := Rect2(cx - 31, r.position.y + 3, 62, 5)
		var z0 := DESK_H + 8.0
		var mh := 40.0
		_box(mon, z0, mh, Color("#2b343a"), Color("#1c2328"), Color("#151b1f"))
		_plane_south(mon.end.y, z0 + mh)
		draw_rect(Rect2(cx - 29, 2, 58, mh - 4), Color("#263238"))
		_draw_screen(Rect2(cx - 27.5, 3.5, 55, mh - 7))
		_plane_reset()


func _iso_chair() -> void:
	var r := rect
	var c := Vector2(r.get_center().x, r.position.y + r.size.y * 0.5 + 1)
	_plane_top(0)
	draw_circle(c + Vector2(2, 2), 11.0, Color(0, 0, 0, 0.14))
	_plane_reset()
	_box(Rect2(c - Vector2(2, 2), Vector2(4, 4)), 0, 13, Color("#37474f"), Color(0, 0, 0, 0), Color(0, 0, 0, 0), false)
	var seat := Rect2(c.x - 12, c.y - 11, 24, 22)
	_box(seat, 13, 5, Color("#455a64"), Color("#263238"), Color("#1f2a30"))
	# Backrest on the south side (we look at the sitter's back from the south-east).
	_box(Rect2(seat.position.x + 1, seat.end.y - 4, seat.size.x - 2, 4), 18, 24, Color("#37474f"), Color("#455a64"), Color("#263238"))


## Meeting chair whose sitter faces south (towards us): backrest on the north.
func _iso_chairback() -> void:
	var p: Vector2 = data.pos
	var seat := Rect2(p.x - 12, p.y - 14, 24, 20)
	_box(Rect2(p - Vector2(2, 6), Vector2(4, 4)), 0, 13, Color("#4e342e"), Color(0, 0, 0, 0), Color(0, 0, 0, 0), false)
	_box(seat, 13, 5, Color("#8d6e63"), Color("#5d4037"), Color("#4e342e"))
	_box(Rect2(seat.position.x + 1, seat.position.y, seat.size.x - 2, 4), 18, 26, Color("#795548"), Color("#8d6e63"), Color("#4e342e"))


func _iso_coffee() -> void:
	var r := rect
	var h := 46.0
	_floor_shadow(r)
	_box(r, 0, h, Color("#4e342e"), Color("#3e2723"), Color("#2c1b17"))
	_plane_south(r.end.y, h)
	draw_rect(Rect2(r.position.x + 5, 4, r.size.x - 10, 12), Color("#c62828"))
	draw_circle(Vector2(r.end.x - 11, 10), 2.5, Color("#69f0ae") if fmod(_t, 2.0) < 1.6 else Color("#1b5e20"))
	draw_rect(Rect2(r.position.x + r.size.x * 0.5 - 8, 20, 16, 4), Color("#212121"))
	draw_rect(Rect2(r.position.x + r.size.x * 0.5 - 5, h - 16, 10, 10), Color("#fafafa"))
	_plane_reset()
	_bb(_p(Vector2(r.position.x + r.size.x * 0.5, r.end.y), 14))
	for i in 2:
		var s := fmod(_t * 12.0 + i * 8.0, 16.0)
		draw_circle(Vector2(sin(_t * 3.0 + i) * 2.0, -s), 2.0, Color(1, 1, 1, 0.35 * (1.0 - s / 16.0)))
	_plane_reset()


func _iso_counter() -> void:
	var r := rect
	var h := 30.0
	var canteen := str(data.get("set", "")) == "canteen"
	_floor_shadow(r, 0.12)
	_box(r, 0, h, Color("#eceff1") if canteen else Color("#eceff1"), Color("#b0bec5"), Color("#90a4ae"))
	# Stainless front strip for a serving counter.
	if canteen:
		_plane_south(r.end.y, h)
		draw_rect(Rect2(r.position.x + 2, 4, r.size.x - 4, 6), Color("#cfd8dc"))
		_plane_reset()
	_plane_top(h)
	if canteen:
		# Trays of food along the counter: pizza, salad, burgers, fruit bowls.
		var foods := [
			{"c": Color("#ef6c00"), "label": "pizza"},
			{"c": Color("#66bb6a"), "label": "salad"},
			{"c": Color("#8d6e63"), "label": "burgers"},
			{"c": Color("#ff7043"), "label": "fruit"},
		]
		var n := foods.size()
		for i in n:
			var fx := r.position.x + 18.0 + i * ((r.size.x - 36.0) / maxf(n - 1, 1))
			var tray := Rect2(fx - 14, r.position.y + 6, 28, 20)
			if not _in_clip(tray.get_center()):
				continue
			draw_rect(tray, Color("#eceff1"))
			draw_rect(tray.grow(-2), foods[i].c)
			# Garnish dots.
			draw_circle(tray.get_center() + Vector2(-4, -2), 2.2, Color(1, 1, 1, 0.55))
			draw_circle(tray.get_center() + Vector2(4, 1), 2.0, Color(0, 0, 0, 0.18))
		_plane_reset()
		# Sneeze guard (glass panel rising from the counter front).
		var guard_h := 28.0
		_plane_south(r.end.y - 2.0, h + guard_h)
		var glass := Rect2(r.position.x + 6, 2, r.size.x - 12, guard_h - 4)
		draw_rect(glass, Color(0.75, 0.9, 1.0, 0.28))
		draw_rect(glass, Color(1, 1, 1, 0.45), false, 1.0)
		draw_line(Vector2(glass.position.x + 4, glass.position.y + 3), Vector2(glass.position.x + 18, glass.position.y + 3), Color(1, 1, 1, 0.35), 1.0)
		_plane_reset()
		# Metal posts holding the guard.
		for px in [r.position.x + 10.0, r.end.x - 10.0]:
			draw_line(_p(Vector2(px, r.end.y - 2), h), _p(Vector2(px, r.end.y - 2), h + guard_h), Color("#90a4ae"), 2.0)
	else:
		var sink := Rect2(r.end.x - 52, r.position.y + 6, 40, 18)
		if _in_clip(sink.get_center()):
			draw_rect(sink, Color("#b0bec5"))
			draw_rect(sink.grow(-3), Color("#cfd8dc"))
		_plane_reset()
		var bowl := Vector2(r.position.x + 30, r.position.y + 14)
		if _in_clip(bowl):
			var bp := _p(bowl, h)
			draw_set_transform(bp, 0, Vector2(1, 0.55) * Iso.SCALE)
			draw_circle(Vector2.ZERO, 9.0, Color("#ffcc80"))
			_bb(bp)
			draw_circle(Vector2(-3, -3), 3.2, Color("#e53935"))
			draw_circle(Vector2(3, -2), 3.2, Color("#fdd835"))
			draw_circle(Vector2(0, -5), 3.0, Color("#7cb342"))
			_plane_reset()


func _iso_water() -> void:
	var r := rect
	_floor_shadow(r)
	var base := r.grow(-6)
	_box(base, 0, 34, Color("#eceff1"), Color("#cfd8dc"), Color("#b0bec5"))
	_plane_south(base.end.y, 34)
	draw_rect(Rect2(base.position.x + 6, 10, base.size.x - 12, 4), Color("#90a4ae"))
	draw_circle(Vector2(base.get_center().x - 4, 20), 1.8, Color("#e53935"))
	draw_circle(Vector2(base.get_center().x + 4, 20), 1.8, Color("#1e88e5"))
	_plane_reset()
	# Bottle (billboard).
	_bb(_p(base.get_center(), 34))
	_rr(Rect2(-10, -30, 20, 30), 8, Color("#4fc3f7", 0.85))
	draw_rect(Rect2(-6, -26, 3, 18), Color(1, 1, 1, 0.45))
	var bub := fmod(_t * 10.0, 22.0)
	draw_circle(Vector2(3, -4 - bub), 1.5, Color(1, 1, 1, 0.7))
	_plane_reset()


func _iso_vending() -> void:
	var r := rect
	var h := 74.0
	_floor_shadow(r)
	_box(r, 0, h, Color("#c62828"), Color("#b71c1c"), Color("#8e1414"))
	_plane_south(r.end.y, h)
	var glass := Rect2(r.position.x + 4, 8, r.size.x - 16, h - 26)
	draw_rect(glass, Color("#1c2a33"))
	var cols := [Color("#4fc3f7"), Color("#ffca28"), Color("#81c784"), Color("#f06292")]
	for row in 4:
		for i in 3:
			draw_rect(Rect2(glass.position.x + 3 + i * 8, glass.position.y + 4 + row * 11, 5, 7), cols[(row + i) % 4])
		draw_line(Vector2(glass.position.x, glass.position.y + 12 + row * 11), Vector2(glass.end.x, glass.position.y + 12 + row * 11), Color(1, 1, 1, 0.25), 1.0)
	draw_rect(Rect2(glass.position.x, glass.position.y, 3, glass.size.y), Color(1, 1, 1, 0.12))
	draw_rect(Rect2(r.end.x - 10, 12, 6, 14), Color("#eceff1"))
	draw_rect(Rect2(r.position.x + 6, h - 14, r.size.x - 20, 7), Color("#111111"))
	_plane_reset()
	_plane_top(h)
	draw_rect(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, 4), Color(1, 1, 1, 0.12))
	_plane_reset()


func _iso_sofa_back() -> void:
	var r := rect
	_box(Rect2(r.position.x, r.position.y, r.size.x, 12), 0, 40, Color("#3949ab"), Color("#3f51b5"), Color("#283593"))


func _iso_sofa_seat() -> void:
	var r := rect
	_floor_shadow(r)
	var seat := Rect2(r.position.x + 14, r.position.y + 12, r.size.x - 28, r.size.y - 12)
	_box(seat, 0, 16, Color("#5c6bc0"), Color("#3949ab"), Color("#303f9f"))
	_plane_top(16)
	draw_line(Vector2(r.get_center().x, seat.position.y + 2), Vector2(r.get_center().x, seat.end.y - 2), Color("#3f51b5"), 2.0)
	_plane_reset()
	_box(Rect2(r.position.x, r.position.y, 14, r.size.y), 0, 26, Color("#3949ab"))


func _iso_foosball() -> void:
	var r := rect
	var h := 30.0
	_floor_shadow(r, 0.22)
	_legs(r, h - 10, Color("#3e2723"), 4.0, 6.0)
	_box(r, h - 10, 10, Color("#5d4037"), Color("#4e342e"), Color("#3e2723"))
	var field := r.grow(-6)
	_plane_top(h)
	draw_rect(field, Color("#2e7d32"))
	draw_rect(field, Color(1, 1, 1, 0.5), false, 1.0)
	draw_line(Vector2(field.get_center().x, field.position.y), Vector2(field.get_center().x, field.end.y), Color(1, 1, 1, 0.45), 1.0)
	draw_arc(field.get_center(), 7.0, 0, TAU, 16, Color(1, 1, 1, 0.45), 1.0)
	draw_rect(Rect2(field.position.x - 3, field.get_center().y - 8, 3, 16), Color("#eeeeee"))
	draw_rect(Rect2(field.end.x, field.get_center().y - 8, 3, 16), Color("#eeeeee"))
	var ball := field.get_center()
	if playing:
		ball += Vector2(sin(_t * 2.3) * field.size.x * 0.42, sin(_t * 3.7 + 1.0) * field.size.y * 0.36)
	draw_circle(ball + Vector2(1, 1), 2.6, Color(0, 0, 0, 0.3))
	_plane_reset()
	_bb(_p(ball, h))
	draw_circle(Vector2(0, -2.5), 2.6, Color.WHITE)
	_plane_reset()
	var ks := Iso.SCALE
	# Rods across the table (north-south) with little upright players.
	var rods := 4
	for i in rods:
		var x := field.position.x + field.size.x * (i + 0.5) / rods
		var col := Color("#e53935") if i % 2 == 0 else Color("#1e88e5")
		var rz := h + 7.0
		draw_line(_p(Vector2(x, r.position.y - 7), rz), _p(Vector2(x, r.end.y + 7), rz), Color("#b0bec5"), 2.0 * ks)
		draw_circle(_p(Vector2(x, r.position.y - 8), rz), 2.5 * ks, Color("#212121"))
		draw_circle(_p(Vector2(x, r.end.y + 8), rz), 2.8 * ks, Color("#212121"))
		var slide := sin(_t * (5.0 + i) + i) * 6.0 if playing else 0.0
		var spin := sin(_t * (9.0 + i * 1.7)) if playing else 1.0
		for k in 2:
			var py := field.position.y + field.size.y * (0.3 + 0.4 * k) + slide
			_bb(_p(Vector2(x, py), h))
			var len := 9.0 * spin
			draw_rect(Rect2(-2.5, -maxf(len, 0.0) - 2.0, 5, absf(len) + 3.0), col)
			draw_circle(Vector2(0, -7.0), 2.0, col.lightened(0.35))
			_plane_reset()


func _iso_table() -> void:
	var r := rect
	var h := 26.0
	var canteen := str(data.get("set", "")) == "canteen"
	_floor_shadow(r, 0.2)
	_legs(r, h - 5, Color("#4e342e"), 6.0, 6.0)
	_box(r, h - 5, 5, Color("#a1887f") if canteen else Color("#8d6e63"), Color("#6d4c41"), Color("#5d4037"))
	_plane_top(h)
	draw_rect(Rect2(r.position.x + 8, r.position.y + 4, r.size.x - 16, 2).intersection(clip), Color(1, 1, 1, 0.15))
	if canteen:
		# Place settings / trays of food on the dining tables.
		var foods := [Color("#ef6c00"), Color("#66bb6a"), Color("#8d6e63"), Color("#ff7043"), Color("#42a5f5")]
		var slots := maxi(2, int(r.size.x / 40.0))
		for i in slots:
			var px := r.position.x + 18.0 + i * ((r.size.x - 36.0) / maxf(slots - 1, 1))
			var py := r.position.y + (14.0 if i % 2 == 0 else 28.0)
			if not _in_clip(Vector2(px, py)):
				continue
			# Tray
			draw_rect(Rect2(px - 10, py - 7, 20, 14), Color("#eceff1"))
			# Plate
			draw_circle(Vector2(px - 2, py), 5.5, Color("#fafafa"))
			draw_circle(Vector2(px - 2, py), 3.5, foods[i % foods.size()])
			# Cup
			draw_rect(Rect2(px + 5, py - 3, 4, 5), Color("#fff8e1"))
	else:
		var n := int(r.size.x / 70.0)
		for i in n:
			var px := r.position.x + 24 + i * (r.size.x - 48) / maxf(n - 1, 1)
			var paper := Rect2(px - 9, r.position.y + 14 + (i % 2) * 22, 18, 13)
			if _in_clip(paper.get_center()):
				draw_rect(paper, Color(1, 1, 1, 0.85))
				draw_line(paper.position + Vector2(3, 4), paper.position + Vector2(14, 4), Color("#90a4ae"), 1.0)
				draw_line(paper.position + Vector2(3, 8), paper.position + Vector2(11, 8), Color("#90a4ae"), 1.0)
		_plane_reset()
		var mug := Vector2(r.end.x - 20, r.position.y + 14)
		if _in_clip(mug):
			_box(Rect2(mug - Vector2(4, 4), Vector2(8, 8)), h, 8, Color("#fafafa"))
			return
	_plane_reset()


func _iso_plant() -> void:
	var r := rect
	var c := r.get_center()
	_plane_top(0)
	draw_circle(c + Vector2(3, 4), r.size.x * 0.4, Color(0, 0, 0, 0.16))
	_plane_reset()
	_box(Rect2(c - Vector2(9, 9), Vector2(18, 18)), 0, 16, Color("#8d6e63"), Color("#a1887f"), Color("#6d4c41"))
	_plane_top(16)
	draw_rect(Rect2(c - Vector2(7, 7), Vector2(14, 14)), Color("#4e342e"))
	_plane_reset()
	_bb(_p(c, 16))
	var sway := sin(_t * 1.2 + r.position.x) * 1.0
	draw_circle(Vector2(-8 + sway, -9), 10, Color("#2e7d32"))
	draw_circle(Vector2(8 + sway, -11), 10, Color("#388e3c"))
	draw_circle(Vector2(sway, -21), 11, Color("#43a047"))
	draw_circle(Vector2(-4 + sway, -25), 4.5, Color("#66bb6a"))
	draw_circle(Vector2(6 + sway, -17), 3.5, Color("#66bb6a"))
	_plane_reset()


func _iso_reception() -> void:
	var r := rect
	var h := 34.0
	_floor_shadow(r)
	_box(r, 0, h, Color("#eceff1"), Color("#546e7a"), Color("#455a64"))
	if _last_slice():
		_plane_south(r.end.y, h)
		draw_string(_font, Vector2(r.position.x + 30, 21), "RECEPTION", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.9))
		_plane_reset()
	var bell := Vector2(r.position.x + 20, r.position.y + 12)
	if _in_clip(bell):
		_bb(_p(bell, h))
		draw_circle(Vector2(0, -3), 4.5, Color("#ffca28"))
		_plane_reset()


func _iso_bench() -> void:
	var r := rect
	_floor_shadow(r)
	_legs(r, 12, Color("#4e342e"), 3.0, 5.0)
	_box(r.grow(-1), 12, 6, Color("#a1887f"), Color("#8d6e63"), Color("#6d4c41"))


func _iso_servers() -> void:
	var r := rect
	var h := 70.0
	_floor_shadow(r)
	_box(r, 0, h, Color("#303030"), Color("#212121"), Color("#151515"))
	_plane_south(r.end.y, h)
	for i in int((h - 10) / 12.0):
		var y := 6.0 + i * 12.0
		draw_rect(Rect2(r.position.x + 4, y, r.size.x - 8, 8), Color("#424242"))
		var on := fmod(_t * (1.0 + i * 0.3), 1.0) < 0.7
		draw_circle(Vector2(r.end.x - 8, y + 4), 1.8, Color("#69f0ae") if on else Color("#1b5e20"))
	_plane_reset()


## Wall slice. data: h (height), color, and optionally windows ("south" or
## "east": the visible inner face of a tall back wall gets windows).
func _iso_wall() -> void:
	var h := float(data.get("h", 30.0))
	var c: Color = data.get("color", Color("#8a909c"))
	var top := c.lightened(0.45)
	_box(rect, 0, h, top, c.lightened(0.12), c.darkened(0.12), false)
	var face := str(data.get("windows", ""))
	if face != "" and h > 48.0:
		# Windows every 96 px along the wall; each slice paints its own part.
		var wh := h - 30.0
		if face == "south":
			_plane_south(rect.end.y, h)
			var x := rect.position.x + 40.0
			while x < rect.end.x - 40.0:
				var win := Rect2(x, 10.0, 52.0, wh).intersection(Rect2(clip.position.x, -1000, clip.size.x, 3000))
				if win.has_area():
					draw_rect(win, Color("#9fc7e6"))
					draw_rect(Rect2(win.position.x, win.position.y, win.size.x, 3), Color("#cfe6f5"))
					if x + 26.0 >= win.position.x and x + 26.0 <= win.end.x:
						draw_line(Vector2(x + 26.0, 10.0), Vector2(x + 26.0, 10.0 + wh), c.lightened(0.3), 2.0)
				x += 96.0
		else:
			_plane_east(rect.end.x, h)
			var y := rect.position.y + 40.0
			while y < rect.end.y - 40.0:
				var win := Rect2(y, 10.0, 52.0, wh).intersection(Rect2(clip.position.y, -1000, clip.size.y, 3000))
				if win.has_area():
					draw_rect(win, Color("#8db7d6"))
					draw_rect(Rect2(win.position.x, win.position.y, win.size.x, 3), Color("#c2dcef"))
					if y + 26.0 >= win.position.x and y + 26.0 <= win.end.x:
						draw_line(Vector2(y + 26.0, 10.0), Vector2(y + 26.0, 10.0 + wh), c.lightened(0.2), 2.0)
				y += 96.0
		_plane_reset()
	# Crisp top edge.
	var r := rect.intersection(clip)
	if r.end.y >= rect.end.y - 0.01:
		draw_line(_p(Vector2(r.position.x, r.end.y), h), _p(r.end, h), Color(1, 1, 1, 0.35), 1.0)
	if r.end.x >= rect.end.x - 0.01:
		draw_line(_p(r.end, h), _p(Vector2(r.end.x, r.position.y), h), Color(1, 1, 1, 0.2), 1.0)


## Whiteboard hung on a west wall, facing east (into the room).
func _iso_whiteboard() -> void:
	var r := rect
	var z0 := 14.0
	var h := 40.0
	_box(r, z0, h, Color("#cfd8dc"), Color("#b0bec5"), Color("#eceff1"))
	_plane_east(r.end.x, z0 + h)
	draw_rect(Rect2(r.position.y, 0, r.size.y, h), Color("#90a4ae"), false, 2.0)
	var cols := [Color("#e57373"), Color("#64b5f6"), Color("#81c784")]
	for i in 3:
		draw_line(Vector2(r.position.y + 14, 10 + i * 9), Vector2(r.position.y + 50 + i * 18, 10 + i * 9), cols[i], 2.0)
	draw_rect(Rect2(r.position.y + 80, 8, 26, 20), Color("#ffe082"))
	draw_rect(Rect2(r.position.y + 10, h - 5, 40, 3), Color("#78909c"))
	_plane_reset()


# ---- canteen extras -----------------------------------------------------------
func _draw_fridge() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 4, Color("#37474f"))
	_rr(Rect2(r.position + Vector2(3, 4), r.size - Vector2(6, 10)), 3, Color("#263238"))
	# Coloured cans / bottles behind glass.
	var cols := [Color("#e53935"), Color("#1e88e5"), Color("#43a047"), Color("#fdd835"), Color("#8e24aa")]
	for row in 3:
		for i in 3:
			var c: Color = cols[(row + i) % cols.size()]
			draw_rect(Rect2(r.position.x + 6 + i * 10, r.position.y + 8 + row * 12, 7, 9), c)
	draw_rect(Rect2(r.position.x + 4, r.end.y - 8, r.size.x - 8, 4), Color("#546e7a"))
	draw_circle(Vector2(r.end.x - 8, r.position.y + 8), 2.0, Color("#69f0ae") if fmod(_t, 2.0) < 1.5 else Color("#1b5e20"))


func _draw_menu() -> void:
	var r := rect
	_rr(r, 3, Color("#5d4037"))
	_rr(r.grow(-3), 2, Color("#fff8e1"))
	for i in 4:
		draw_line(r.position + Vector2(6, 7 + i * 5), r.position + Vector2(r.size.x - 8, 7 + i * 5), Color("#8d6e63"), 1.2)
	draw_rect(Rect2(r.position.x + 4, r.position.y + 2, r.size.x - 8, 4), Color("#ef6c00"))


func _draw_microwave() -> void:
	var r := rect
	_shadow(r)
	_rr(r, 3, Color("#546e7a"))
	_rr(Rect2(r.position + Vector2(3, 4), Vector2(r.size.x * 0.62, r.size.y - 10)), 2, Color("#212121"))
	draw_rect(Rect2(r.end.x - 12, r.position.y + 6, 6, 8), Color("#90a4ae"))
	draw_circle(Vector2(r.end.x - 9, r.end.y - 8), 2.0, Color("#ffca28") if fmod(_t, 1.6) < 0.8 else Color("#795548"))


func _draw_bin() -> void:
	var r := rect
	_shadow(r, 0.12)
	_rr(r, 3, Color("#455a64"))
	draw_rect(Rect2(r.position.x + 2, r.position.y - 3, r.size.x - 4, 5), Color("#37474f"))
	draw_rect(Rect2(r.position.x + 5, r.position.y + 4, r.size.x - 10, 3), Color("#607d8b"))


func _iso_fridge() -> void:
	var r := rect
	var h := 64.0
	_floor_shadow(r)
	_box(r, 0, h, Color("#455a64"), Color("#37474f"), Color("#263238"))
	_plane_south(r.end.y, h)
	var glass := Rect2(r.position.x + 4, 6, r.size.x - 10, h - 18)
	draw_rect(glass, Color("#1c2a33"))
	var cols := [Color("#e53935"), Color("#1e88e5"), Color("#43a047"), Color("#fdd835"), Color("#8e24aa"), Color("#26c6da")]
	for row in 4:
		for i in 2:
			draw_rect(Rect2(glass.position.x + 4 + i * 12, glass.position.y + 4 + row * 11, 8, 8), cols[(row * 2 + i) % cols.size()])
		draw_line(Vector2(glass.position.x, glass.position.y + 13 + row * 11), Vector2(glass.end.x, glass.position.y + 13 + row * 11), Color(1, 1, 1, 0.2), 1.0)
	draw_rect(Rect2(glass.position.x, glass.position.y, 3, glass.size.y), Color(1, 1, 1, 0.15))
	draw_circle(Vector2(r.end.x - 8, 10), 2.2, Color("#69f0ae") if fmod(_t, 2.0) < 1.5 else Color("#1b5e20"))
	_plane_reset()
	_plane_top(h)
	draw_rect(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, 4), Color(1, 1, 1, 0.12))
	_plane_reset()


func _iso_menu() -> void:
	var r := rect
	var h := 40.0
	# Wall-mounted board: thin box raised off the floor.
	_box(r, 18, h - 10, Color("#5d4037"), Color("#4e342e"), Color("#3e2723"))
	_plane_south(r.end.y, 18 + h - 10)
	var board := Rect2(r.position.x + 3, 4, r.size.x - 6, h - 18)
	draw_rect(board, Color("#fff8e1"))
	draw_rect(Rect2(board.position.x, board.position.y, board.size.x, 5), Color("#ef6c00"))
	for i in 4:
		draw_line(Vector2(board.position.x + 4, board.position.y + 10 + i * 5), Vector2(board.end.x - 4, board.position.y + 10 + i * 5), Color("#8d6e63"), 1.2)
	# Price dots
	for i in 4:
		draw_circle(Vector2(board.end.x - 7, board.position.y + 10 + i * 5), 1.4, Color("#43a047"))
	_plane_reset()


func _iso_microwave() -> void:
	var r := rect
	var h := 28.0
	_floor_shadow(r, 0.1)
	_box(r, 8, h, Color("#607d8b"), Color("#546e7a"), Color("#455a64"))
	_plane_south(r.end.y, 8 + h)
	var window := Rect2(r.position.x + 4, 6, r.size.x * 0.58, h - 12)
	draw_rect(window, Color("#212121"))
	draw_rect(window.grow(-2), Color("#37474f", 0.6))
	draw_rect(Rect2(r.end.x - 12, 8, 6, 8), Color("#cfd8dc"))
	draw_circle(Vector2(r.end.x - 9, h - 6), 2.0, Color("#ffca28") if fmod(_t, 1.6) < 0.8 else Color("#795548"))
	_plane_reset()


func _iso_bin() -> void:
	var r := rect
	var h := 22.0
	_floor_shadow(r, 0.12)
	_box(r, 0, h, Color("#546e7a"), Color("#455a64"), Color("#37474f"))
	_plane_top(h)
	draw_rect(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, 4), Color("#263238"))
	# Lid flap
	draw_rect(Rect2(r.position.x + 4, r.position.y + 3, r.size.x - 8, 2), Color("#78909c"))
	_plane_reset()
