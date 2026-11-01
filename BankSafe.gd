extends Node2D
## Executive-room floor safe — isometric furniture (same _box style as Prop).
## Cabinet-sized, roughly agent height; sits on the floor against the wall.
## Click → VAULT_UNLOCK / open panel. Subtle LED + door swing when unlocked.

signal unlock_requested
signal open_panel_requested
signal lock_requested

const Iso := preload("res://Iso.gd")

const BODY_TOP := Color("#78909c")
const BODY_SOUTH := Color("#607d8b")
const BODY_EAST := Color("#455a64")
const DOOR := Color("#90a4ae")
const DOOR_EDGE := Color("#cfd8dc")
const DIAL := Color("#eceff1")
const HANDLE := Color("#f5f5f5")
const GOLD := Color("#ffd54f")
const CAVITY := Color("#263238")
const LED_LOCKED := Color("#ef5350")
const LED_OPEN := Color("#66bb6a")

## World footprint (cabinet-sized, ~fridge width, shorter depth).
var rect := Rect2()
## Standing height in world units — a bit under a fridge / agent.
const SAFE_H := 56.0

var _unlocked: bool = false
var _door_open: float = 0.0  # 0 closed → 1 open
var _hover: bool = false
var _pulse: float = 0.0
var _hit := Rect2()  # local screen-space AABB for clicks


func setup(world_rect: Rect2) -> void:
	rect = world_rect
	position = Iso.to_screen(iso_anchor())
	z_index = 0  # y-sorted with other props; do not float above agents
	_refresh_hit()
	set_process(true)
	queue_redraw()


## Depth-order point (screen y ≈ world x + y), same convention as Prop.
func iso_anchor() -> Vector2:
	return rect.get_center()


func set_unlocked(v: bool) -> void:
	_unlocked = v
	if not v:
		_door_open = 0.0
	queue_redraw()


func is_unlocked() -> bool:
	return _unlocked


func _process(delta: float) -> void:
	_pulse += delta
	var target := 1.0 if _unlocked else 0.0
	_door_open = move_toward(_door_open, target, delta * 2.0)
	queue_redraw()


func _refresh_hit() -> void:
	# AABB of the projected box, in this node's local space.
	var aabb := Iso.screen_aabb(rect, SAFE_H)
	_hit = Rect2(aabb.position - position, aabb.size).grow(4.0)


# ---- iso drawing helpers (mirrors Prop._box / _floor_shadow) ----------------

func _p(w: Vector2, z: float = 0.0) -> Vector2:
	return Iso.to_screen(w, z) - position


func _poly(pts: Array, c: Color) -> void:
	draw_colored_polygon(PackedVector2Array(pts), c)


func _box(r: Rect2, z0: float, h: float, top: Color, south: Color = Color(0, 0, 0, 0), east: Color = Color(0, 0, 0, 0), edge: bool = true) -> void:
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
		draw_line(_p(d, z1), _p(c, z1), hl, 1.0)
		draw_line(_p(c, z1), _p(b, z1), hl, 1.0)


func _plane_south(y0: float, z_top: float) -> void:
	draw_set_transform_matrix(Iso.south_xf(y0, z_top, -position))


func _plane_top(z: float) -> void:
	draw_set_transform_matrix(Iso.floor_xf(z, -position))


func _plane_reset() -> void:
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _floor_shadow(r: Rect2, alpha: float = 0.16) -> void:
	_plane_top(0.0)
	draw_rect(Rect2(r.position + Vector2(2, 3), r.size), Color(0, 0, 0, alpha))
	_plane_reset()


func _draw() -> void:
	if not Iso.enabled:
		_draw_flat()
		return
	var r := rect
	var h := SAFE_H
	_floor_shadow(r)
	# Slight inset so the body reads as a solid cabinet, not wall-flush.
	_box(r, 0.0, h, BODY_TOP, BODY_SOUTH, BODY_EAST)
	# Soft hover brighten on top face.
	if _hover:
		_plane_top(h)
		draw_rect(Rect2(r.position + Vector2(2, 2), r.size - Vector2(4, 4)), Color(1, 1, 1, 0.08))
		_plane_reset()
	_draw_south_face(r, h)
	_draw_top_accent(r, h)


func _draw_south_face(r: Rect2, h: float) -> void:
	_plane_south(r.end.y, h)
	# Local: x = world x, y = px down from top of box.
	var inset := 3.0
	var door_x0 := r.position.x + inset
	var door_w := r.size.x - inset * 2.0
	var door_h := h - 10.0
	var door_y0 := 5.0

	# Inner cavity (visible as door swings).
	if _door_open > 0.04:
		draw_rect(Rect2(door_x0, door_y0, door_w, door_h), CAVITY)
		for i in 3:
			var bx := door_x0 + 5.0 + i * (door_w / 3.0)
			draw_rect(
				Rect2(bx, door_y0 + door_h * 0.35, door_w / 3.0 - 6.0, door_h * 0.35),
				Color(GOLD.r, GOLD.g, GOLD.b, 0.45 * _door_open)
			)

	# Door panel: hinged on the left, swings by shrinking width + shifting right.
	var swing := _door_open * 0.82
	var panel_w := door_w * (1.0 - swing * 0.78)
	var panel_x := door_x0 + swing * door_w * 0.55
	if panel_w > 4.0:
		var door_col := DOOR.lightened(0.06 if _hover else 0.0)
		draw_rect(Rect2(panel_x, door_y0, panel_w, door_h), door_col.darkened(0.08))
		draw_rect(Rect2(panel_x + 1.5, door_y0 + 1.5, panel_w - 3.0, door_h - 3.0), door_col)
		# Gold rivets along the hinge side.
		for i in 3:
			var ry := door_y0 + 6.0 + i * ((door_h - 12.0) / 2.0)
			draw_circle(Vector2(panel_x + 3.5, ry), 1.4, GOLD)
		if panel_w > 14.0:
			# Dial
			var dial_c := Vector2(panel_x + panel_w * 0.42, door_y0 + door_h * 0.42)
			draw_circle(dial_c, 5.5, BODY_EAST)
			draw_circle(dial_c, 4.2, DIAL)
			draw_circle(dial_c, 1.2, BODY_EAST)
			var ang := _pulse * 0.55
			draw_line(dial_c, dial_c + Vector2(cos(ang), sin(ang)) * 3.4, BODY_EAST, 1.2)
			# Handle
			var hx := panel_x + panel_w * 0.78
			draw_rect(Rect2(hx - 1.5, door_y0 + door_h * 0.28, 3.0, door_h * 0.32), HANDLE)
			draw_circle(Vector2(hx, door_y0 + door_h * 0.28), 2.2, GOLD)

	# Subtle lock LED near the top of the south face (not a giant billboard glow).
	var led := LED_OPEN if _unlocked else LED_LOCKED
	var glow := 0.45 + 0.25 * sin(_pulse * (2.6 if not _unlocked else 1.2))
	var led_pos := Vector2(r.position.x + r.size.x * 0.5, 3.0)
	draw_circle(led_pos, 2.4, Color(led.r, led.g, led.b, glow * 0.55))
	draw_circle(led_pos, 1.3, led)

	# Tiny label on the door lip / top of face.
	var f := ThemeDB.fallback_font
	if f and _door_open < 0.5:
		var label := "OPEN" if _unlocked else "SAFE"
		var fs := 7
		var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(r.position.x + r.size.x * 0.5 - tw * 0.5, h - 3.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(GOLD, 0.85))
	_plane_reset()


func _draw_top_accent(r: Rect2, h: float) -> void:
	_plane_top(h)
	draw_rect(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, 3), Color(1, 1, 1, 0.10))
	# Thin gold trim along the front edge of the lid.
	draw_line(
		Vector2(r.position.x + 2, r.end.y - 2),
		Vector2(r.end.x - 2, r.end.y - 2),
		Color(GOLD, 0.45),
		1.0
	)
	_plane_reset()


func _draw_flat() -> void:
	# Top-down fallback (rarely used): simple cabinet footprint.
	draw_set_transform(-position, 0.0, Vector2.ONE * Iso.SCALE)
	draw_rect(rect, BODY_SOUTH)
	draw_rect(Rect2(rect.position + Vector2(3, 3), rect.size - Vector2(6, 6)), DOOR)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var local := to_local(get_global_mouse_position())
	var inside := _hit.has_point(local)
	if event is InputEventMouseMotion:
		if _hover != inside:
			_hover = inside
			queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and inside:
		get_viewport().set_input_as_handled()
		if _unlocked:
			open_panel_requested.emit()
		else:
			unlock_requested.emit()
