## Small vault/safe placard in the Server Room. Click opens the vault list (names only).
## No walkmesh / door / hex changes — placed as a SignTag-style overlay like the Notice Board.
extends Node2D

signal open_requested

const SIZE := Vector2(44, 40)

var _area: Area2D
var _hover := false


func setup(anchor_world: Vector2) -> void:
	position = anchor_world
	z_index = 40
	_ensure_area()
	queue_redraw()


func _ensure_area() -> void:
	if _area and is_instance_valid(_area):
		return
	_area = Area2D.new()
	_area.input_pickable = true
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = SIZE
	shape.shape = rect
	shape.position = SIZE * 0.5
	_area.add_child(shape)
	add_child(_area)
	_area.input_event.connect(_on_area_input)
	_area.mouse_entered.connect(func() -> void: _hover = true; queue_redraw())
	_area.mouse_exited.connect(func() -> void: _hover = false; queue_redraw())


func _on_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		open_requested.emit()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, SIZE)
	var body := Color("#455a64") if not _hover else Color("#546e7a")
	draw_rect(r, body)
	draw_rect(r, Color("#263238"), false, 2.0)
	# Door face
	var door := Rect2(6, 8, 32, 26)
	draw_rect(door, Color("#37474f"))
	draw_rect(door, Color("#78909c"), false, 1.0)
	# Dial
	draw_circle(Vector2(22, 20), 6.0, Color("#ffd54f" if _hover else "#cfd8dc"))
	draw_circle(Vector2(22, 20), 2.0, Color("#263238"))
	# Handle
	draw_rect(Rect2(30, 18, 5, 3), Color("#90a4ae"))
	# Label
	var font := ThemeDB.fallback_font
	if font:
		draw_string(font, Vector2(4, SIZE.y + 12), "VAULT", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("#eceff1"))
