## A single autonomous agent in the office.
##
## Movement: NavigationAgent2D path-following with RVO avoidance
## (velocity -> velocity_computed -> move_and_slide).
## Visuals: a procedurally drawn cartoon character (_draw) with walk bob, leg
## swing, typing arms, thinking dots and talking animation. Assign
## `sprite_frames` to use a real AnimatedSprite2D instead (animations named
## idle / walk / work / think / collab).
class_name Agent
extends CharacterBody2D

signal clicked(agent: Agent)
signal state_changed(agent: Agent, state: String)
signal log_added(agent: Agent, line: String)
signal arrived(agent: Agent, waypoint: String)

const STATES: PackedStringArray = ["IDLE", "WORKING", "THINKING", "COLLAB"]
const STATE_COLORS := {
	"IDLE": Color("#9e9e9e"),
	"WORKING": Color("#43a047"),
	"THINKING": Color("#fdd835"),
	"COLLAB": Color("#ab47bc"),
}
const MAX_LOG_LINES := 1000
const BUBBLE_SECONDS := 3.0
const BUBBLE_MAX_CHARS := 64

@export var agent_id: String = "agent"
@export var display_name: String = "Agent"
@export var body_color: Color = Color("#4fc3f7")
@export var move_speed: float = 140.0
@export var desk: String = ""
## Optional sprite sheet. When set, the procedural drawing is disabled.
@export var sprite_frames: SpriteFrames

var state: String = "IDLE"
var current_waypoint: String = ""
var log_lines: PackedStringArray = []
## name -> Marker2D, injected by Main.
var waypoints: Dictionary = {}

var _anim_time := 0.0
var _walking := false
var _facing := 1.0
var _target_offset := Vector2.ZERO
var _nav_active := false
var _stuck_time := 0.0
var _last_pos := Vector2.ZERO
var _bubble_tween: Tween
var _bubble_is_thought := false
var _hovered := false
var _selected := false

@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var click_area: Area2D = $ClickArea
@onready var name_label: Label = $NameLabel
@onready var bubble: PanelContainer = $SpeechBubble
@onready var bubble_label: Label = $SpeechBubble/Label


func _ready() -> void:
	nav_agent.max_speed = move_speed
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	nav_agent.navigation_finished.connect(_on_navigation_finished)
	click_area.input_event.connect(_on_click_area_input_event)
	click_area.mouse_entered.connect(func() -> void: _hovered = true)
	click_area.mouse_exited.connect(func() -> void: _hovered = false)
	bubble.visible = false
	bubble.modulate.a = 0.0
	_anim_time = randf() * 10.0
	_apply_identity()
	if sprite_frames:
		sprite.sprite_frames = sprite_frames
		sprite.visible = true
		sprite.play("idle")


## Called by Main after instancing (or again when a SNAPSHOT updates it).
func setup(id: String, nice_name: String, colour: Color, desk_name: String, waypoint_map: Dictionary) -> void:
	agent_id = id
	display_name = nice_name
	body_color = colour
	desk = desk_name
	waypoints = waypoint_map
	name = id.validate_node_name()
	if is_node_ready():
		_apply_identity()


func _apply_identity() -> void:
	name_label.text = display_name
	name_label.add_theme_color_override("font_color", body_color.lightened(0.6))
	queue_redraw()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Walks to the Marker2D called `marker_name` (plus an optional offset so
## several agents can share one spot). Unknown names are ignored with a warning.
func go_to_waypoint(marker_name: String, offset: Vector2 = Vector2.ZERO) -> void:
	var marker: Node2D = waypoints.get(marker_name)
	if marker == null:
		push_warning("Agent %s: unknown waypoint '%s'" % [agent_id, marker_name])
		return
	current_waypoint = marker_name
	_target_offset = offset
	go_to_position(marker.global_position + offset)


func go_to_position(world_pos: Vector2) -> void:
	nav_agent.target_position = world_pos
	_nav_active = true
	_stuck_time = 0.0


## Pops a speech (or thought) bubble above the head; auto-hides after 3s.
func show_bubble(text: String, is_thought: bool = false) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	if text.length() > BUBBLE_MAX_CHARS:
		text = text.substr(0, BUBBLE_MAX_CHARS - 1) + "…"
	_bubble_is_thought = is_thought
	bubble_label.text = text
	_style_bubble(is_thought)
	bubble.visible = true
	_layout_bubble()
	_layout_bubble.call_deferred()

	if _bubble_tween and _bubble_tween.is_valid():
		_bubble_tween.kill()
	bubble.scale = Vector2(0.6, 0.6)
	_bubble_tween = create_tween()
	_bubble_tween.set_parallel(true)
	_bubble_tween.tween_property(bubble, "modulate:a", 1.0, 0.18)
	_bubble_tween.tween_property(bubble, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_bubble_tween.chain().tween_interval(BUBBLE_SECONDS)
	_bubble_tween.chain().tween_property(bubble, "modulate:a", 0.0, 0.3)
	_bubble_tween.chain().tween_callback(func() -> void: bubble.visible = false)


## IDLE | WORKING | THINKING | COLLAB. Unknown states fall back to IDLE.
func set_state(state_name: String) -> void:
	state_name = state_name.to_upper()
	if state_name == "COLLABORATE":
		state_name = "COLLAB"
	if not STATES.has(state_name):
		push_warning("Agent %s: unknown state '%s'" % [agent_id, state_name])
		state_name = "IDLE"
	if state_name == state:
		return
	state = state_name
	_play_anim()
	state_changed.emit(self, state)
	queue_redraw()


func add_log(line: String) -> void:
	log_lines.append(line)
	if log_lines.size() > MAX_LOG_LINES:
		log_lines = log_lines.slice(log_lines.size() - MAX_LOG_LINES)
	log_added.emit(self, line)


func set_logs(lines: Array) -> void:
	log_lines = PackedStringArray()
	for l in lines:
		log_lines.append(str(l))


func set_selected(value: bool) -> void:
	_selected = value
	queue_redraw()


func is_at_destination() -> bool:
	return not _nav_active


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not _nav_active:
		_walking = false
		return
	# Wait until the navigation map has synced at least once.
	if NavigationServer2D.map_get_iteration_id(nav_agent.get_navigation_map()) == 0:
		return
	if nav_agent.is_navigation_finished():
		_finish_navigation()
		return
	var next := nav_agent.get_next_path_position()
	var desired := global_position.direction_to(next) * move_speed
	if nav_agent.avoidance_enabled:
		nav_agent.velocity = desired  # result arrives via velocity_computed
	else:
		_on_velocity_computed(desired)

	# Simple stuck detection (e.g. boxed in by other agents at a busy spot).
	if global_position.distance_to(_last_pos) < 0.5 * delta * move_speed * 0.1:
		_stuck_time += delta
		if _stuck_time > 2.5:
			_finish_navigation()
	else:
		_stuck_time = 0.0
	_last_pos = global_position


func _on_velocity_computed(safe_velocity: Vector2) -> void:
	if not _nav_active:
		return
	velocity = safe_velocity
	move_and_slide()
	_walking = velocity.length() > 8.0
	if absf(velocity.x) > 4.0:
		_facing = signf(velocity.x)


func _on_navigation_finished() -> void:
	_finish_navigation()


func _finish_navigation() -> void:
	if not _nav_active:
		return
	_nav_active = false
	_walking = false
	velocity = Vector2.ZERO
	nav_agent.velocity = Vector2.ZERO
	_play_anim()
	arrived.emit(self, current_waypoint)


# ---------------------------------------------------------------------------
# Animation / drawing
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_anim_time += delta
	if sprite.visible:
		sprite.flip_h = _facing < 0.0
		_play_anim()
	queue_redraw()


## Hook for sprite-based animation. Procedural mode just redraws.
func _play_anim() -> void:
	if not sprite.visible or sprite.sprite_frames == null:
		return
	var anim := "idle"
	if _walking:
		anim = "walk"
	else:
		match state:
			"WORKING": anim = "work"
			"THINKING": anim = "think"
			"COLLAB": anim = "collab"
	if sprite.sprite_frames.has_animation(anim) and sprite.animation != anim:
		sprite.play(anim)


func _draw() -> void:
	var state_col: Color = STATE_COLORS.get(state, Color.GRAY)
	# Selection / hover ring + state ring at the feet.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, 17.0, Color(0, 0, 0, 0.25))
	draw_arc(Vector2.ZERO, 19.0, 0.0, TAU, 32, state_col, 3.0, true)
	if _selected or _hovered:
		draw_arc(Vector2.ZERO, 24.0, 0.0, TAU, 32, Color(1, 1, 1, 0.9 if _selected else 0.5), 2.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if not sprite.visible:
		_draw_character()
	_draw_state_props()
	if bubble.visible:
		_draw_bubble_tail()


func _draw_character() -> void:
	var t := _anim_time
	var bob := 0.0
	var leg := 0.0
	if _walking:
		bob = -absf(sin(t * 12.0)) * 3.0
		leg = sin(t * 12.0) * 4.0
	elif state == "WORKING" and not _nav_active:
		bob = sin(t * 20.0) * 0.6
	else:
		bob = sin(t * 2.2) * 1.2  # breathing

	var body_dark := body_color.darkened(0.35)
	var skin := Color("#ffd7b5")
	# Legs
	draw_rect(Rect2(-8 + leg, -16, 6, 16), Color("#37474f"))
	draw_rect(Rect2(2 - leg, -16, 6, 16), Color("#37474f"))
	# Torso
	var torso := Rect2(-12, -40 + bob, 24, 26)
	draw_rect(torso, body_color)
	draw_rect(Rect2(torso.position.x, torso.end.y - 5, torso.size.x, 5), body_dark)
	# Arms
	var arm_y := -36.0 + bob
	if state == "WORKING" and not _nav_active and not _walking:
		# Typing: arms forward, alternating taps on a little laptop.
		var tap_l := sin(t * 22.0) * 2.0
		var tap_r := sin(t * 22.0 + PI) * 2.0
		draw_rect(Rect2(-16, -22, 32, 4), Color("#90a4ae"))  # laptop base
		draw_rect(Rect2(-12, -34, 24, 12), Color("#263238"))  # screen back
		draw_rect(Rect2(-10, -32, 20, 8), Color("#4dd0e1", 0.5 + 0.3 * sin(t * 6.0)))
		draw_rect(Rect2(-17, arm_y + 8 + tap_l, 6, 12), body_dark)
		draw_rect(Rect2(11, arm_y + 8 + tap_r, 6, 12), body_dark)
	elif state == "COLLAB":
		var wave := sin(t * 6.0) * 6.0
		draw_rect(Rect2(-17, arm_y, 6, 18), body_dark)
		draw_set_transform(Vector2(14, arm_y + 2), deg_to_rad(-30.0 + wave), Vector2.ONE)
		draw_rect(Rect2(-3, -16, 6, 18), body_dark)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	elif state == "THINKING":
		draw_rect(Rect2(-17, arm_y, 6, 18), body_dark)
		draw_rect(Rect2(6, arm_y - 8, 6, 14), body_dark)  # hand to chin
	else:
		var swing := sin(t * 12.0) * 3.0 if _walking else 0.0
		draw_rect(Rect2(-17, arm_y + swing, 6, 18), body_dark)
		draw_rect(Rect2(11, arm_y - swing, 6, 18), body_dark)
	# Head
	var head := Vector2(0, -52 + bob)
	if state == "THINKING":
		head.x += sin(t * 1.5) * 1.5
	draw_circle(head, 12.0, skin)
	draw_arc(head, 12.0, PI, TAU, 16, body_dark, 6.0)  # hair
	# Eyes (look in walking direction, blink every few seconds)
	var blink := fmod(t + float(agent_id.hash() % 7), 4.0) < 0.12
	var eye_dx := 3.0 * _facing if _walking else 0.0
	for ex: float in [-4.5, 4.5]:
		if blink:
			draw_line(head + Vector2(ex + eye_dx - 2, 0), head + Vector2(ex + eye_dx + 2, 0), Color("#212121"), 1.5)
		else:
			draw_circle(head + Vector2(ex + eye_dx, 0), 1.8, Color("#212121"))
	# Mouth
	if state == "COLLAB" and fmod(t, 0.5) < 0.25:
		draw_circle(head + Vector2(0, 6), 2.5, Color("#6d2c2c"))
	else:
		draw_line(head + Vector2(-3, 6), head + Vector2(3, 6), Color("#6d2c2c"), 1.5)
	# Coffee cup when idling at the coffee machine.
	if state == "IDLE" and not _nav_active and current_waypoint == "Coffee_Machine":
		draw_rect(Rect2(12, -30 + bob, 8, 9), Color("#fafafa"))
		draw_arc(Vector2(21, -26 + bob), 3.0, -PI / 2, PI / 2, 8, Color("#fafafa"), 1.5)


func _draw_state_props() -> void:
	var t := _anim_time
	var top := Vector2(16, -70)
	match state:
		"THINKING":
			# Animated "..." in a small cloud.
			draw_circle(top + Vector2(10, 0), 13.0, Color(1, 1, 1, 0.9))
			for i in 3:
				var a := 0.35 + 0.65 * clampf(sin(t * 5.0 - i * 0.8), 0.0, 1.0)
				draw_circle(top + Vector2(2 + i * 8, 0), 2.6, Color(0.2, 0.2, 0.2, a))
		"WORKING":
			if not _nav_active:
				# Floating code glyphs while typing.
				var y := fmod(t * 20.0, 20.0)
				draw_string(ThemeDB.fallback_font, top + Vector2(0, 4 - y), "</>", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
					Color(0.3, 0.9, 0.5, 1.0 - y / 20.0))
		"COLLAB":
			# Mini chat icon that pulses while talking.
			var pulse := 1.0 + 0.12 * sin(t * 8.0)
			draw_set_transform(top + Vector2(8, -4), 0.0, Vector2(pulse, pulse))
			draw_rect(Rect2(-9, -7, 18, 12), Color("#e1bee7"))
			draw_colored_polygon(PackedVector2Array([Vector2(-5, 5), Vector2(1, 5), Vector2(-6, 10)]), Color("#e1bee7"))
			for i in 3:
				draw_circle(Vector2(-5 + i * 5, -1), 1.4, Color("#6a1b9a"))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_bubble_tail() -> void:
	var a := bubble.modulate.a
	var base := bubble.position + Vector2(bubble.size.x * 0.5, bubble.size.y)
	if _bubble_is_thought:
		draw_circle(base + Vector2(-6, 7), 4.5, Color(0.93, 0.96, 1.0, a))
		draw_circle(base + Vector2(-10, 15), 3.0, Color(0.93, 0.96, 1.0, a))
	else:
		draw_colored_polygon(PackedVector2Array([base + Vector2(-7, -1), base + Vector2(7, -1), base + Vector2(0, 9)]),
			Color(1, 1, 1, a))


func _style_bubble(is_thought: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	if is_thought:
		sb.bg_color = Color(0.93, 0.96, 1.0)
		sb.set_corner_radius_all(16)
		sb.border_color = Color("#90caf9")
		sb.set_border_width_all(2)
		bubble_label.add_theme_color_override("font_color", Color("#455a64"))
	else:
		sb.bg_color = Color.WHITE
		sb.set_corner_radius_all(6)
		sb.border_color = body_color.darkened(0.2)
		sb.set_border_width_all(2)
		bubble_label.add_theme_color_override("font_color", Color("#212121"))
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = 3
	bubble.add_theme_stylebox_override("panel", sb)


func _layout_bubble() -> void:
	bubble.reset_size()
	bubble.size = bubble.get_combined_minimum_size()
	bubble.position = Vector2(-bubble.size.x * 0.5, -78.0 - bubble.size.y)
	bubble.pivot_offset = Vector2(bubble.size.x * 0.5, bubble.size.y)


func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(self)
		get_viewport().set_input_as_handled()
