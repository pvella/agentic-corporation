extends Node2D
## Chunky bank safe in the Executive room. Click → VAULT_UNLOCK / open panel.
## Door swings open when unlocked. LED: red locked / green unlocked.

signal unlock_requested
signal open_panel_requested
signal lock_requested

const BODY := Color("#546e7a")
const BODY_DARK := Color("#37474f")
const DOOR := Color("#78909c")
const DIAL := Color("#cfd8dc")
const HANDLE := Color("#eceff1")
const GOLD := Color("#ffd54f")
const LED_LOCKED := Color("#ef5350")
const LED_OPEN := Color("#66bb6a")

var _unlocked: bool = false
var _door_open: float = 0.0  # 0 closed → 1 open
var _hover: bool = false
var _pulse: float = 0.0
var _hit := Rect2(-48, -56, 96, 100)


func setup(anchor: Vector2) -> void:
	position = anchor
	z_index = 20
	set_process(true)
	queue_redraw()


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
	_door_open = move_toward(_door_open, target, delta * 2.4)
	queue_redraw()


func _draw() -> void:
	# Shadow
	draw_rect(Rect2(-50, -54, 100, 104), Color(0, 0, 0, 0.28))
	# Body
	draw_rect(Rect2(-48, -56, 96, 100), BODY_DARK)
	draw_rect(Rect2(-44, -52, 88, 92), BODY)
	# Rivets
	for y in [-44, 0, 36]:
		draw_circle(Vector2(-40, y), 2.5, GOLD)
		draw_circle(Vector2(40, y), 2.5, GOLD)
	# Inner vault cavity (visible when door open)
	if _door_open > 0.05:
		var inset := Rect2(-36, -40, 72, 72)
		draw_rect(inset, Color("#263238"))
		# Gold bars hint
		for i in range(3):
			var bx := -24.0 + i * 18.0
			draw_rect(Rect2(bx, -20, 12, 28), Color("#f9a825", 0.55 * _door_open))
	# Door (hinged on left; swings by shrinking width + offset)
	var swing := _door_open * 0.85
	var door_w := 80.0 * (1.0 - swing * 0.72)
	var door_x := -40.0 + swing * 54.0
	var door_rect := Rect2(door_x, -44, door_w, 80)
	draw_rect(door_rect, DOOR.darkened(0.08 if _hover else 0.0))
	draw_rect(door_rect.grow(-3), DOOR.lightened(0.05))
	# Dial
	var dial_c := Vector2(door_x + door_w * 0.42, -8)
	if door_w > 28:
		draw_circle(dial_c, 14, BODY_DARK)
		draw_circle(dial_c, 11, DIAL)
		draw_circle(dial_c, 3, BODY_DARK)
		var ang := _pulse * 0.7
		draw_line(dial_c, dial_c + Vector2(cos(ang), sin(ang)) * 9.0, BODY_DARK, 2.0)
		# Handle
		var hx := door_x + door_w * 0.72
		draw_rect(Rect2(hx - 4, -22, 8, 28), HANDLE)
		draw_circle(Vector2(hx, -22), 5, GOLD)
	# LED
	var led := LED_OPEN if _unlocked else LED_LOCKED
	var glow := 0.55 + 0.35 * sin(_pulse * (3.0 if not _unlocked else 1.5))
	draw_circle(Vector2(0, -48), 5, Color(led.r, led.g, led.b, glow))
	draw_circle(Vector2(0, -48), 2.5, led)
	# Label
	var f := ThemeDB.fallback_font
	if f:
		var label := "OPEN" if _unlocked else "SAFE"
		var fs := 11
		var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(-tw * 0.5, 48), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, GOLD)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var local := to_local((event as InputEventMouseMotion).position)
		# Approximate: use canvas transform — SignTag pattern uses get_global_mouse_position
		pass


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var mouse := get_global_mouse_position()
	var local := to_local(mouse)
	var inside := _hit.has_point(local)
	if event is InputEventMouseMotion:
		_hover = inside
		queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and inside:
		get_viewport().set_input_as_handled()
		if _unlocked:
			open_panel_requested.emit()
		else:
			unlock_requested.emit()
