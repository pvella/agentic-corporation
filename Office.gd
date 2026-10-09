## Placeholder office art, drawn procedurally with _draw() so the project needs
## no external assets. Also the single source of truth for the walkable floor
## and furniture obstacles that Main.gd bakes into the navigation polygon.
##
## Swap this for a TileMapLayer + sprites later: keep FLOOR / OBSTACLES (or
## derive them from tile collision) and the Marker2D waypoints in Main.tscn.
@tool
extends Node2D

## Walkable interior of the office (inside the walls).
const FLOOR := Rect2(24, 64, 1232, 640)
const WALL := 12.0

## Furniture / partition walls. kind controls how it is drawn.
const OBSTACLES: Array[Dictionary] = [
	{"name": "Coder", "kind": "desk", "rect": Rect2(110, 130, 160, 64)},
	{"name": "QA", "kind": "desk", "rect": Rect2(330, 130, 160, 64)},
	{"name": "Architect", "kind": "desk", "rect": Rect2(550, 130, 160, 64)},
	{"name": "Partition", "kind": "wall", "rect": Rect2(790, 64, 12, 230)},
	{"name": "Partition", "kind": "wall", "rect": Rect2(1010, 430, 246, 12)},
	{"name": "Coffee", "kind": "coffee", "rect": Rect2(870, 76, 64, 48)},
	{"name": "Counter", "kind": "counter", "rect": Rect2(950, 76, 160, 40)},
	{"name": "Water", "kind": "water", "rect": Rect2(1170, 76, 44, 44)},
	{"name": "Sofa", "kind": "sofa", "rect": Rect2(920, 320, 200, 50)},
	{"name": "Meeting table", "kind": "table", "rect": Rect2(560, 520, 300, 100)},
	{"name": "Bookshelf", "kind": "shelf", "rect": Rect2(36, 400, 36, 170)},
	{"name": "Servers", "kind": "servers", "rect": Rect2(1190, 520, 52, 160)},
	{"name": "Plant", "kind": "plant", "rect": Rect2(740, 80, 36, 36)},
	{"name": "Plant", "kind": "plant", "rect": Rect2(40, 650, 36, 36)},
	{"name": "Plant", "kind": "plant", "rect": Rect2(1200, 370, 36, 36)},
]

const ZONES: Array[Dictionary] = [
	{"label": "WORK AREA", "rect": Rect2(24, 64, 766, 330), "color": Color("#c9a77c")},
	{"label": "BREAK ROOM", "rect": Rect2(802, 64, 454, 366), "color": Color("#9fb7c9")},
	{"label": "MEETING ROOM", "rect": Rect2(470, 450, 520, 254), "color": Color("#8f7fb0")},
]

var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font


## Obstacle outlines (clockwise points) for navigation baking.
func get_obstacle_outlines() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for o in OBSTACLES:
		var r: Rect2 = o.rect
		out.append(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]))
	return out


func get_floor_outline() -> PackedVector2Array:
	var r := FLOOR
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	# Outside / background
	draw_rect(Rect2(0, 0, 1280, 720), Color("#2b2f3a"))
	# Base floor with a subtle plank pattern
	draw_rect(FLOOR, Color("#d8c3a0"))
	for y in range(int(FLOOR.position.y), int(FLOOR.end.y), 24):
		draw_line(Vector2(FLOOR.position.x, y), Vector2(FLOOR.end.x, y), Color(0, 0, 0, 0.05), 1.0)
	# Zone rugs / tiles
	for z in ZONES:
		var r: Rect2 = z.rect
		var c: Color = z.color
		draw_rect(r.grow(-6), Color(c, 0.35))
		draw_rect(r.grow(-6), Color(c.darkened(0.3), 0.6), false, 2.0)
		draw_string(_font, r.position + Vector2(14, r.size.y - 14), z.label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0, 0, 0, 0.35))
	# Break-room checker tiles
	var br: Rect2 = ZONES[1].rect
	for x in range(int(br.position.x) + 6, int(br.end.x) - 6, 32):
		for y in range(int(br.position.y) + 6, int(br.end.y) - 6, 32):
			if int((x + y) / 32.0) % 2 == 0:
				draw_rect(Rect2(x, y, 32, 32).intersection(br.grow(-6)), Color(1, 1, 1, 0.12))
	# Outer walls
	var outer := FLOOR.grow(WALL)
	draw_rect(Rect2(outer.position, Vector2(outer.size.x, WALL)), Color("#4a4f5c"))
	draw_rect(Rect2(outer.position.x, FLOOR.end.y, outer.size.x, WALL), Color("#4a4f5c"))
	draw_rect(Rect2(outer.position, Vector2(WALL, outer.size.y)), Color("#4a4f5c"))
	draw_rect(Rect2(FLOOR.end.x, outer.position.y, WALL, outer.size.y), Color("#4a4f5c"))
	# Door (bottom-left)
	draw_rect(Rect2(96, FLOOR.end.y, 70, WALL), Color("#8d6e63"))
	# Whiteboard on the meeting room wall
	draw_rect(Rect2(600, 456, 220, 10), Color("#eceff1"))
	draw_rect(Rect2(600, 456, 220, 10), Color("#90a4ae"), false, 1.0)

	for o in OBSTACLES:
		_draw_furniture(o.kind, o.rect, o.name)


func _draw_furniture(kind: String, r: Rect2, label: String) -> void:
	var shadow := Rect2(r.position + Vector2(4, 5), r.size)
	match kind:
		"desk":
			draw_rect(shadow, Color(0, 0, 0, 0.18))
			draw_rect(r, Color("#8d6e63"))
			draw_rect(r.grow(-4), Color("#a1887f"))
			# Monitor + keyboard
			var m := Rect2(r.get_center().x - 34, r.position.y + 8, 68, 30)
			draw_rect(m, Color("#263238"))
			draw_rect(m.grow(-3), Color("#4dd0e1", 0.55))
			draw_rect(Rect2(m.get_center().x - 4, m.end.y, 8, 6), Color("#37474f"))
			draw_rect(Rect2(r.get_center().x - 26, r.end.y - 16, 52, 9), Color("#cfd8dc"))
			draw_string(_font, Vector2(r.position.x + 6, r.end.y - 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.8))
			# Chair below the desk (agents sit here)
			draw_circle(Vector2(r.get_center().x, r.end.y + 40), 15, Color("#455a64"))
			draw_circle(Vector2(r.get_center().x, r.end.y + 40), 11, Color("#607d8b"))
		"wall":
			draw_rect(r, Color("#4a4f5c"))
		"coffee":
			draw_rect(shadow, Color(0, 0, 0, 0.18))
			draw_rect(r, Color("#3e2723"))
			draw_rect(Rect2(r.position + Vector2(8, 8), Vector2(r.size.x - 16, 16)), Color("#d32f2f"))
			draw_circle(r.position + Vector2(r.size.x * 0.5, 36), 6, Color("#fafafa"))
			draw_string(_font, r.position + Vector2(0, r.size.y + 14), "Coffee", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#3e2723"))
		"counter":
			draw_rect(shadow, Color(0, 0, 0, 0.15))
			draw_rect(r, Color("#eceff1"))
			draw_rect(Rect2(r.position + Vector2(90, 8), Vector2(50, 22)), Color("#b0bec5"))
		"water":
			draw_rect(shadow, Color(0, 0, 0, 0.18))
			draw_rect(r, Color("#eceff1"))
			draw_circle(r.get_center() + Vector2(0, -6), 14, Color("#4fc3f7", 0.85))
			draw_string(_font, r.position + Vector2(-14, r.size.y + 14), "Water", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#01579b"))
		"sofa":
			draw_rect(shadow, Color(0, 0, 0, 0.18))
			draw_rect(r, Color("#5c6bc0"))
			draw_rect(Rect2(r.position, Vector2(r.size.x, 16)), Color("#3949ab"))
			draw_rect(Rect2(r.position + Vector2(0, 0), Vector2(16, r.size.y)), Color("#3949ab"))
			draw_rect(Rect2(r.end.x - 16, r.position.y, 16, r.size.y), Color("#3949ab"))
		"table":
			draw_rect(shadow, Color(0, 0, 0, 0.2))
			draw_rect(r, Color("#6d4c41"))
			draw_rect(r.grow(-6), Color("#8d6e63"))
			for i in 3:
				draw_rect(Rect2(r.position.x + 40 + i * 90, r.position.y + 30, 40, 28), Color(1, 1, 1, 0.75))
			for seat: Vector2 in [Vector2(640, 486), Vector2(780, 486), Vector2(640, 654), Vector2(780, 654)]:
				draw_circle(seat, 14, Color("#5d4037", 0.6))
		"shelf":
			draw_rect(r, Color("#5d4037"))
			for i in 6:
				var y := r.position.y + 8 + i * 27
				draw_rect(Rect2(r.position.x + 4, y, r.size.x - 8, 18), Color.from_hsv(fmod(i * 0.17, 1.0), 0.45, 0.8))
		"servers":
			draw_rect(shadow, Color(0, 0, 0, 0.2))
			draw_rect(r, Color("#212121"))
			for i in 8:
				var y := r.position.y + 10 + i * 18
				draw_rect(Rect2(r.position.x + 6, y, r.size.x - 12, 10), Color("#424242"))
				draw_circle(Vector2(r.end.x - 12, y + 5), 2.5, Color("#69f0ae") if i % 3 != 1 else Color("#ffab40"))
		"plant":
			draw_circle(r.get_center() + Vector2(3, 4), r.size.x * 0.5, Color(0, 0, 0, 0.18))
			draw_circle(r.get_center(), r.size.x * 0.32, Color("#795548"))
			draw_circle(r.get_center() + Vector2(-6, -6), 11, Color("#43a047"))
			draw_circle(r.get_center() + Vector2(7, -4), 10, Color("#66bb6a"))
			draw_circle(r.get_center() + Vector2(0, 5), 10, Color("#2e7d32"))
