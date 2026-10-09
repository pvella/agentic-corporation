## Pan / zoom camera for the office.
##   Drag (left button on empty floor, or middle / right button anywhere): pan
##   WASD / arrow keys: pan        Mouse wheel / trackpad pinch: zoom at cursor
##   + / - : zoom                  F or Home: fit the whole office
## Keys are ignored while a text field (the drawer prompt) has focus.
extends Camera2D

signal zoom_changed(zoom_level: float)

@export var min_zoom: float = 0.35
@export var max_zoom: float = 2.4
@export var pan_speed: float = 700.0
@export var top_margin: float = 46.0  ## HUD bar height (screen px)

var world_bounds := Rect2(0, 0, 1280, 800)
var _dragging := false
var _drag_armed := false
var _drag_start := Vector2.ZERO
var _target_zoom := 1.0


func _ready() -> void:
	_target_zoom = zoom.x
	get_viewport().size_changed.connect(_clamp_position)


## Sets the world rectangle the camera may show and zooms to fit it.
func set_bounds(r: Rect2, fit: bool = true) -> void:
	world_bounds = r
	if fit:
		fit_all()


func fit_all() -> void:
	var view := get_viewport_rect().size - Vector2(0, top_margin)
	var z := minf(view.x / world_bounds.size.x, view.y / world_bounds.size.y) * 0.98
	_set_zoom(clampf(z, min_zoom, max_zoom))
	_target_zoom = zoom.x
	position = world_bounds.get_center() - Vector2(0, top_margin * 0.5) / zoom.x
	_clamp_position()


func focus_on(world_pos: Vector2, z: float) -> void:
	_set_zoom(clampf(z, min_zoom, max_zoom))
	_target_zoom = zoom.x
	position = world_pos
	_clamp_position()


func _set_zoom(z: float) -> void:
	zoom = Vector2(z, z)
	zoom_changed.emit(z)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(1.12, mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(1.0 / 1.12, mb.position)
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if mb.pressed:
				_drag_armed = true
				_dragging = mb.button_index != MOUSE_BUTTON_LEFT
				_drag_start = mb.position
			else:
				_drag_armed = false
				_dragging = false
	elif event is InputEventMouseMotion and _drag_armed:
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_drag_start) > 6.0:
			_dragging = true
		if _dragging:
			position -= mm.relative / zoom.x
			_clamp_position()
	elif event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		_zoom_at(g.factor, g.position)
	elif event is InputEventPanGesture:
		position += (event as InputEventPanGesture).delta * 8.0 / zoom.x
		_clamp_position()
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_F, KEY_HOME:
				fit_all()
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				_zoom_at(1.2, get_viewport_rect().size * 0.5)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_zoom_at(1.0 / 1.2, get_viewport_rect().size * 0.5)


func _process(delta: float) -> void:
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1
	if dir != Vector2.ZERO:
		position += dir.normalized() * pan_speed * delta / zoom.x
		_clamp_position()


## Zooms keeping the world point under `screen_pos` fixed.
func _zoom_at(factor: float, screen_pos: Vector2) -> void:
	var c := get_viewport_rect().size * 0.5
	var before := position + (screen_pos - c) / zoom.x
	_set_zoom(clampf(zoom.x * factor, min_zoom, max_zoom))
	position = before - (screen_pos - c) / zoom.x
	_clamp_position()


func _clamp_position() -> void:
	var half := get_viewport_rect().size * 0.5 / zoom.x
	var r := world_bounds
	var top_pad := top_margin / zoom.x
	var min_p := r.position + half - Vector2(0, top_pad)
	var max_p := r.end - half
	position.x = r.get_center().x if min_p.x > max_p.x else clampf(position.x, min_p.x, max_p.x)
	position.y = r.get_center().y - top_pad * 0.5 if min_p.y > max_p.y else clampf(position.y, min_p.y, max_p.y)
