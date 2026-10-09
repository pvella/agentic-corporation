## Isometric-view room sign / building label. Stands upright (billboarded) on
## a short post at a projected floor point, drawn above the sorted world so it
## stays legible, and scaled with the UI scale when zoomed out. Clickable signs
## carry an Area2D (layer 8) so picking happens where the sign is drawn.
extends Node2D

signal pressed

var info: Dictionary = {}   ## Office.signs entry, or {"name": ..., "style": "building"/"note"}
var box := Rect2()          ## local rect of the placard
var _font: Font


func setup(s: Dictionary, anchor: Vector2) -> void:
	info = s
	position = anchor
	z_index = 30
	_font = ThemeDB.fallback_font
	var style := str(s.get("style", "info"))
	if style == "info":
		var w := maxf(_text_w(str(s.name), 14), _text_w(str(s.get("sub", "")), 10)) + 30.0
		var h := 26.0 if str(s.get("sub", "")) == "" else 36.0
		box = Rect2(-18, -h - 12, w, h)
	else:
		var size := 18 if style == "building" else 13
		var w := _text_w(str(s.name), size)
		box = Rect2(-w * 0.5 - 8, -size - 10, w + 16, size + 10)
	if bool(s.get("clickable", false)):
		var area := Area2D.new()
		area.input_pickable = true
		area.monitoring = false
		area.collision_layer = 8
		area.collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = box.size
		shape.shape = rect_shape
		shape.position = box.get_center()
		area.add_child(shape)
		area.input_event.connect(func(_vp: Node, ev: InputEvent, _i: int) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				pressed.emit()
				get_viewport().set_input_as_handled())
		add_child(area)
	queue_redraw()


func _text_w(text: String, size: int) -> float:
	if text.is_empty():
		return 0.0
	return ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


func _rr(r: Rect2, radius: float, c: Color) -> void:
	draw_colored_polygon(preload("res://Office.gd").rounded_rect_points(r, radius), c)


func _draw() -> void:
	var style := str(info.get("style", "info"))
	if style == "building":
		draw_string(_font, Vector2(box.position.x + 9, box.end.y - 7), str(info.name).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0, 0, 0, 0.35))
		draw_string(_font, Vector2(box.position.x + 8, box.end.y - 8), str(info.name).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, 0.92))
		return
	if style == "note":
		_rr(box, 6, Color(0.1, 0.12, 0.16, 0.55))
		draw_string(_font, Vector2(box.position.x + 8, box.end.y - 7), str(info.name), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.92))
		return
	var c: Color = info.color
	# Post down to the floor point.
	draw_line(Vector2(0, box.end.y), Vector2(0, -1), Color("#4a4f5a"), 3.0)
	draw_set_transform(Vector2.ZERO, 0, Vector2(1, 0.5))
	draw_circle(Vector2.ZERO, 5.0, Color(0, 0, 0, 0.25))
	draw_set_transform(Vector2.ZERO)
	_rr(Rect2(box.position + Vector2(2, 3), box.size), 9, Color(0, 0, 0, 0.25))
	_rr(box, 9, c.darkened(0.25))
	_rr(box.grow(-2), 8, c.darkened(0.05) if info.get("clickable", false) else c)
	var text_col := Color.WHITE if c.get_luminance() < 0.62 else Color("#1f2430")
	draw_string(_font, box.position + Vector2(12, 18), str(info.name), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, text_col)
	if str(info.get("sub", "")) != "":
		draw_string(_font, box.position + Vector2(12, 31), str(info.sub), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(text_col, 0.8))
	if info.get("clickable", false):
		draw_string(_font, Vector2(box.end.x - 16, box.position.y + 18), "›", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(text_col, 0.8))
