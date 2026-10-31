extends Node2D
## Decorative mini-safe in the Server Room (non-interactive). The Executive BankSafe is the entry point.

const BODY := Color("#607d8b")
const DOOR := Color("#90a4ae")
const GOLD := Color("#ffd54f")


func setup(anchor: Vector2) -> void:
	position = anchor
	z_index = 18
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(-22, -26, 44, 48), Color(0, 0, 0, 0.25))
	draw_rect(Rect2(-20, -24, 40, 44), BODY)
	draw_rect(Rect2(-16, -18, 32, 32), DOOR)
	draw_circle(Vector2(0, -2), 6, Color("#cfd8dc"))
	draw_circle(Vector2(0, -2), 2, BODY)
	draw_rect(Rect2(8, -10, 4, 14), Color("#eceff1"))
	var f := ThemeDB.fallback_font
	if f:
		draw_string(f, Vector2(-14, 28), "safe", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, GOLD)
