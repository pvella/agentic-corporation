## A y-sorted piece of furniture. Main creates one per Office.props entry and
## parents it under World/Props, so agents walking behind a desk, sofa or
## table are correctly hidden by it.
##
## Desks show their owner's monitor: scrolling code in the agent's colour
## while it works at the desk, a dim screensaver otherwise. The foosball table
## animates (spinning rods, rolling ball) while `playing` is true.
extends Node2D

const Office := preload("res://Office.gd")

var kind := ""
var rect := Rect2()          ## world-space footprint
var data: Dictionary = {}
var owner_agent: Node = null ## Agent at this desk (desks only)
var playing := false         ## foosball only

var _t := 0.0
var _font: Font


func setup(d: Dictionary) -> void:
	kind = str(d.kind)
	rect = d.rect
	data = d
	position = Vector2(rect.position.x, float(d.get("sort_y", rect.end.y)))
	_font = ThemeDB.fallback_font
	set_process(kind in ["desk", "foosball", "servers", "coffee"])


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	# Draw in world coordinates (the node origin is only used for y-sorting).
	draw_set_transform(-position, 0.0, Vector2.ONE)
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


func _rr(r: Rect2, radius: float, c: Color) -> void:
	draw_colored_polygon(Office.rounded_rect_points(r, radius), c)


func _shadow(r: Rect2, alpha: float = 0.18) -> void:
	_rr(Rect2(r.position + Vector2(3, 5), r.size), 6, Color(0, 0, 0, alpha))


# ---------------------------------------------------------------------------
func _draw_desk() -> void:
	var r := rect
	_shadow(r)
	# Legs, top surface, darker front edge.
	draw_rect(Rect2(r.position.x + 4, r.end.y - 4, 5, 8), Color("#5d4037"))
	draw_rect(Rect2(r.end.x - 9, r.end.y - 4, 5, 8), Color("#5d4037"))
	_rr(r, 4, Color("#6d4c41"))
	_rr(Rect2(r.position, Vector2(r.size.x, r.size.y - 8)), 4, Color("#a1887f"))
	draw_rect(Rect2(r.position.x + 3, r.position.y + 3, r.size.x - 6, 2), Color(1, 1, 1, 0.18))

	# Monitor: stands on the far edge, screen facing us (the agent sits in front).
	var mon := Rect2(r.position.x + r.size.x * 0.5 - 32, r.position.y - 40, 64, 44)
	draw_rect(Rect2(mon.get_center().x - 4, mon.end.y - 2, 8, 9), Color("#37474f"))
	draw_rect(Rect2(mon.get_center().x - 12, mon.end.y + 6, 24, 3), Color("#37474f"))
	_rr(mon.grow(1.5), 4, Color("#1c2328"))
	_rr(mon, 3, Color("#263238"))
	var screen := mon.grow(-3.5)
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
	# Keyboard + mouse on the near edge, mug on the side.
	var kb := Rect2(r.position.x + r.size.x * 0.5 - 22, r.position.y + 14, 44, 9)
	_rr(kb, 2, Color("#cfd8dc"))
	for k in 5:
		draw_line(kb.position + Vector2(4 + k * 8, 3), kb.position + Vector2(8 + k * 8, 3), Color("#90a4ae"), 1.0)
	draw_line(kb.position + Vector2(8, 6), kb.position + Vector2(36, 6), Color("#90a4ae"), 1.0)
	_rr(Rect2(kb.end.x + 7, kb.position.y + 1, 7, 9), 3, Color("#eceff1"))
	draw_rect(Rect2(r.position.x + 7, r.position.y + 10, 9, 11), Color("#fafafa"))
	draw_rect(Rect2(r.position.x + 8, r.position.y + 11, 7, 3), Color("#6d4c41"))
	if agent == null and str(data.get("owner", "")) == "":
		draw_string(_font, Vector2(r.position.x + 22, r.end.y - 11), "free desk", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0, 0, 0, 0.35))


func _draw_chair() -> void:
	# Office chair seen from behind: the back covers the sitter's lower back.
	var r := rect
	var c := r.get_center()
	draw_circle(Vector2(c.x, r.end.y + 1), 9.0, Color(0, 0, 0, 0.15))
	draw_line(Vector2(c.x, r.end.y - 6), Vector2(c.x, r.end.y + 2), Color("#37474f"), 3.0)
	for dx: float in [-8.0, 0.0, 8.0]:
		draw_circle(Vector2(c.x + dx, r.end.y + 2), 1.8, Color("#263238"))
	_rr(Rect2(r.position.x - 1, r.position.y + 6, r.size.x + 2, r.size.y - 10), 6, Color("#263238"))
	_rr(Rect2(r.position.x + 2, r.position.y + 8, r.size.x - 4, r.size.y - 15), 5, Color("#455a64"))
	draw_line(Vector2(r.position.x + 6, r.position.y + 11), Vector2(r.end.x - 6, r.position.y + 11), Color(1, 1, 1, 0.15), 1.5)


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
