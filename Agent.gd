## One autonomous agent in the office: a small chibi office worker.
##
## Movement: NavigationAgent2D path-following with RVO avoidance, a relaxed
## stroll speed, and smooth acceleration/deceleration. Arrival snaps only when
## already within a tiny radius — no free-space tween that could cross walls.
##
## Look: drawn procedurally in _draw (outlined shapes, shaded shirt, hair
## styles, accessories, blinking eyes). Poses: walk cycle, idle breathing,
## seated at the desk from behind with hands on the keyboard (the desk Prop
## draws the monitor), hand-to-chin + thought dots when THINKING, talking
## gestures in COLLAB, sofa, foosball, and glancing at a phone when a log or
## update arrives while away from the desk.
##
## Sprite-sheet hook: assign `sprite_frames` (animations idle / walk / work /
## think / collab, optionally phone / sit) and the procedural body is replaced
## by an AnimatedSprite2D; poses, bubbles, name pill and phone pings still work.
class_name Agent
extends CharacterBody2D

signal clicked(agent: Agent)
signal state_changed(agent: Agent, state: String)
signal log_added(agent: Agent, line: String)
signal arrived(agent: Agent, waypoint: String)

const Office := preload("res://Office.gd")
const Iso := preload("res://Iso.gd")
const STATES: PackedStringArray = ["IDLE", "WORKING", "THINKING", "COLLAB", "ERROR"]
const STATE_COLORS := {
	"IDLE": Color("#9e9e9e"),
	"WORKING": Color("#43a047"),
	"THINKING": Color("#fdd835"),
	"COLLAB": Color("#ab47bc"),
	"ERROR": Color("#e53935"),
}
const MAX_LOG_LINES := 1000
const BUBBLE_SECONDS := 3.0
const BUBBLE_MAX_CHARS := 64
const ACCEL := 240.0         ## px/s² for gentle starts and stops
const SLOW_RADIUS := 56.0    ## start easing off this far from the target
## Amenity seat/pose (yoga, sofa, foosball…) only if we landed this close.
## Stuck arrivals mid-corridor must not strike a tree pose in the hallway.
const SEAT_ARRIVE_MAX := 28.0
const STUCK_NEAR_SEC := 3.0    ## give up quickly when already at the spot
const STUCK_FAR_SEC := 14.0    ## wait longer while still crossing the campus
const STUCK_FAR_DIST := 64.0   ## "still far" threshold for the patience above
const OUTLINE := Color(0.15, 0.13, 0.19)
const HEAD_R := 18.0
## How far the drawing drops when sitting, per seat type.
const SIT_DROP := {"desk": 3.0, "chair": 6.0, "sofa": 9.0, "foosball": 0.0, "yoga": 0.0, "meditate": 10.0, "": 0.0}

const SKINS: Array[Color] = [Color("#ffdbbf"), Color("#f1c27d"), Color("#e0ac69"), Color("#c68642"), Color("#8d5524"), Color("#ffe0d0")]
const HAIRS: Array[Color] = [Color("#3b2a20"), Color("#6d4c41"), Color("#b5651d"), Color("#e6c07b"), Color("#1c1c1c"), Color("#9e9e9e"), Color("#a83f2e"), Color("#5e3a8c")]
const HAIR_STYLES: PackedStringArray = ["short", "spiky", "bob", "ponytail", "bun", "curly", "sidepart", "long", "buzz"]
const ACCESSORIES: PackedStringArray = ["glasses", "headphones", "beard", "cap", "bow", "beanie", "glasses", "headphones", "cap"]
const PANTS: Array[Color] = [Color("#37474f"), Color("#3e4a7a"), Color("#5d4037"), Color("#263238"), Color("#4e5b31")]
## Hand-picked looks for the legacy agents (others are derived from agent_id).
const PRESET_LOOKS := {
	"coder_agent": {"skin": 0, "hair": 0, "style": "spiky", "acc": "headphones", "pants": 0},
	"qa_agent": {"skin": 2, "hair": 6, "style": "ponytail", "acc": "glasses", "pants": 1},
	"architect_agent": {"skin": 1, "hair": 5, "style": "sidepart", "acc": "beard", "pants": 2},
}

@export var agent_id: String = "agent"
@export var display_name: String = "Agent"
@export var body_color: Color = Color("#4fc3f7")
@export var move_speed: float = 88.0
@export var desk: String = ""
## Optional sprite sheet. When set, the procedural drawing is disabled.
@export var sprite_frames: SpriteFrames

var role: String = ""
## Job description dict.
var job: Dictionary = {}
## Pending DM / human-reply notes for next prompt.
var pending_notes: Array = []
var room_id: String = ""
var state: String = "IDLE"
var last_text: String = ""
## Unread dashboard messages waiting in this (real) bot's inbox: envelope badge.
var unread: int = 0
## True while a human reply dialog is outstanding (raised-hand pose).
var awaiting_input: bool = false
var current_waypoint: String = ""
var log_lines: PackedStringArray = []
## name -> Marker2D (meta: facing, seat), injected by Main.
var waypoints: Dictionary = {}

var _look: Dictionary = {}
var _anim_time := 0.0
var _walk_phase := 0.0
var _walk_amount := 0.0   # 0 standing .. 1 full stroll (smoothed)
var _dir := Vector2.DOWN  # smoothed movement direction
var _vel := Vector2.ZERO
var _nav_active := false
var _settling := false
var _stuck_time := 0.0
var _stuck_retries := 0
var _last_pos := Vector2.ZERO
var _target_pos := Vector2.ZERO
var _pose_facing := "down"
var _seat := ""
var _sit := 0.0            # 0 standing .. 1 seated (animated)
var _phone_until := 0.0
var _ping_until := 0.0
var _bubble_tween: Tween
var _bubble_is_thought := false
var _kill_mode_active: bool = false
var _kill_hover: bool = false
const KILL_HOVER_TINT := Color(1.0, 0.35, 0.35, 1.0)
var _hovered := false
var _selected := false
var _ui_scale := 1.0
## Main sets false at overview zoom so only status icons show; hover/select force on.
var _name_forced := false
var _overview_lod := false
var _blink_seed := 0.0

@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var click_area: Area2D = $ClickArea
@onready var name_label: Label = $NameLabel
@onready var bubble: PanelContainer = $SpeechBubble
@onready var bubble_label: Label = $SpeechBubble/Label


func _ready() -> void:
	nav_agent.max_speed = move_speed
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	click_area.input_event.connect(_on_click_area_input_event)
	click_area.mouse_entered.connect(func() -> void:
		_hovered = true
		_refresh_name_visibility()
		if _kill_mode_active:
			_set_kill_hover(true)
	)
	click_area.mouse_exited.connect(func() -> void:
		_hovered = false
		_refresh_name_visibility()
		if _kill_mode_active:
			_set_kill_hover(false)
	)
	bubble.visible = false
	bubble.modulate.a = 0.0
	_anim_time = randf() * 10.0
	_apply_identity()
	if sprite_frames:
		sprite.sprite_frames = sprite_frames
		sprite.visible = true
		sprite.play("idle")


## Called by Main after instancing. `style_index` spreads looks across agents.
func setup(id: String, nice_name: String, colour: Color, desk_name: String, waypoint_map: Dictionary, style_index: int = -1) -> void:
	agent_id = id
	display_name = nice_name
	body_color = colour
	desk = desk_name
	waypoints = waypoint_map
	name = id.validate_node_name()
	_look = _make_look(id, style_index)
	if is_node_ready():
		_apply_identity()


func _make_look(id: String, index: int) -> Dictionary:
	var h := absi(id.hash())
	var i := index if index >= 0 else h % 97
	var p: Dictionary = PRESET_LOOKS.get(id, {
		"skin": (h / 7) % SKINS.size(),
		"hair": (i * 3 + h) % HAIRS.size(),
		"style": HAIR_STYLES[(i * 5 + h / 3) % HAIR_STYLES.size()],
		"acc": ACCESSORIES[(i * 7 + h / 11) % ACCESSORIES.size()],
		"pants": (i + h / 13) % PANTS.size(),
	})
	_blink_seed = float(h % 1000) / 250.0
	return {
		"skin": SKINS[int(p.skin)], "hair": HAIRS[int(p.hair)], "style": str(p.style), "acc": str(p.acc),
		"pants": PANTS[int(p.pants)], "accent": Color.from_hsv(fmod(float(h % 360) / 360.0 + 0.5, 1.0), 0.55, 0.85),
	}


func _apply_identity() -> void:
	if _look.is_empty():
		_look = _make_look(agent_id, -1)
	name_label.text = display_name
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(body_color.darkened(0.35), 0.92)
	sb.border_color = body_color.lightened(0.25)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 1
	sb.content_margin_bottom = 2
	name_label.add_theme_stylebox_override("normal", sb)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	_layout_name()
	_refresh_name_visibility()
	queue_redraw()


## Moves the name pill, speech bubble and click area onto the render node.
func attach_view(v: Node2D) -> void:
	view = v
	for n: Node in [name_label, bubble, click_area, sprite]:
		n.reparent(v, false)


func _layout_name() -> void:
	name_label.reset_size()
	name_label.size = name_label.get_combined_minimum_size()
	name_label.pivot_offset = Vector2(name_label.size.x * 0.5, 0)
	name_label.position = Vector2(-name_label.size.x * 0.5, 7)
	name_label.scale = Vector2.ONE * _ui_scale


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Walks (or, with `instant`, teleports) to the Marker2D `marker_name`, plus an
## optional offset so several agents can share one spot. Re-sending the spot
## the agent is already standing on is a no-op (no re-pathing, no jitter).
func go_to_waypoint(marker_name: String, offset: Vector2 = Vector2.ZERO, instant: bool = false) -> void:
	var marker: Node2D = waypoints.get(marker_name)
	if marker == null:
		push_warning("Agent %s: unknown waypoint '%s'" % [agent_id, marker_name])
		return
	var target := marker.global_position + offset
	if marker_name == current_waypoint and global_position.distance_to(target) < 4.0 and not _nav_active:
		return
	current_waypoint = marker_name
	_pose_facing = str(marker.get_meta("facing", "down"))
	var seat := str(marker.get_meta("seat", ""))
	if offset.length() > 1.0 and seat in ["desk", "chair", "sofa", "meditate"]:
		seat = ""  # overflow spot next to a seat: stand
	if instant:
		global_position = target
		_target_pos = target
		_nav_active = false
		_seat = seat
		_sit = 1.0 if seat != "" else 0.0
		return
	_seat = ""  # stand up first
	_target_pos = target
	_pending_seat = seat
	go_to_position(target)


var _pending_seat := ""


func go_to_position(world_pos: Vector2) -> void:
	_target_pos = world_pos
	nav_agent.target_position = world_pos
	_nav_active = true
	_settling = false
	_stuck_time = 0.0
	_stuck_retries = 0


## Pops a speech (or thought) bubble above the head; auto-hides after 3s.
func show_bubble(text: String, is_thought: bool = false) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	last_text = text
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
	bubble.scale = Vector2.ONE * 0.6 * _ui_scale
	_bubble_tween = create_tween()
	_bubble_tween.set_parallel(true)
	_bubble_tween.tween_property(bubble, "modulate:a", 1.0, 0.18)
	_bubble_tween.tween_property(bubble, "scale", Vector2.ONE * _ui_scale, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_bubble_tween.chain().tween_interval(BUBBLE_SECONDS)
	_bubble_tween.chain().tween_property(bubble, "modulate:a", 0.0, 0.3)
	_bubble_tween.chain().tween_callback(func() -> void: bubble.visible = false)


## IDLE | WORKING | THINKING | COLLAB | ERROR. Unknown states fall back to IDLE.
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


func add_log(line: String) -> void:
	log_lines.append(line)
	if log_lines.size() > MAX_LOG_LINES:
		log_lines = log_lines.slice(log_lines.size() - MAX_LOG_LINES)
	if is_away_from_desk():
		glance_phone(3.5)
	log_added.emit(self, line)


func set_logs(lines: Array) -> void:
	log_lines = PackedStringArray()
	for l in lines:
		log_lines.append(str(l))


## Pulls out the phone for `seconds` (with a little ping on the first glance,
## unless it's just idle scrolling: ping = false).
func glance_phone(seconds: float = 3.5, ping: bool = true) -> void:
	if ping and _phone_until < _anim_time:
		_ping_until = _anim_time + 1.4
	_phone_until = maxf(_phone_until, _anim_time + seconds)


func is_phone_out() -> bool:
	return _anim_time < _phone_until


func set_selected(value: bool) -> void:
	_selected = value
	_refresh_name_visibility()
	if view:
		view.queue_redraw()


func is_at_destination() -> bool:
	return not _nav_active and not _settling


func is_seated_at_desk() -> bool:
	return current_waypoint == desk and _seat == "desk" and _sit > 0.6 and is_at_destination()


## True while the agent is sat at a canteen seat eating (harness text "Eating …").
func is_eating() -> bool:
	if _seat != "chair" or _sit < 0.5 or not is_at_destination():
		return false
	if current_waypoint.begins_with("Canteen_Seat"):
		return true
	return last_text.to_lower().begins_with("eating")


func is_away_from_desk() -> bool:
	return not (current_waypoint == desk and is_at_destination())


## Counter-scales the name pill and bubbles so they stay readable when zoomed out.
func set_ui_scale(s: float) -> void:
	_ui_scale = s
	name_label.scale = Vector2.ONE * s
	if bubble.visible and not (_bubble_tween and _bubble_tween.is_running()):
		bubble.scale = Vector2.ONE * s


## Overview LOD: hide name pills (status rings/icons remain). Hover/select override.
func set_overview_lod(active: bool) -> void:
	_overview_lod = active
	_refresh_name_visibility()


func _refresh_name_visibility() -> void:
	if not is_instance_valid(name_label):
		return
	var show := _selected or _hovered or _name_forced or not _overview_lod
	name_label.visible = show


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not _nav_active:
		return
	if NavigationServer2D.map_get_iteration_id(nav_agent.get_navigation_map()) == 0:
		return
	if nav_agent.is_navigation_finished():
		_arrive()
		return
	var next := nav_agent.get_next_path_position()
	var remaining := global_position.distance_to(_target_pos)
	var speed := move_speed * clampf(remaining / SLOW_RADIUS, 0.35, 1.0)
	var desired := global_position.direction_to(next) * speed
	_vel = _vel.move_toward(desired, ACCEL * delta)
	if nav_agent.avoidance_enabled:
		nav_agent.velocity = _vel  # result arrives via velocity_computed
	else:
		_on_velocity_computed(_vel)

	# Stuck detection (e.g. boxed in at a busy spot). Be patient while still
	# far from the amenity so a jam in a spoke corridor doesn't end the walk
	# early — that used to leave agents doing yoga in the hallway.
	if global_position.distance_to(_last_pos) < 3.0 * delta:
		_stuck_time += delta
		var far := remaining > STUCK_FAR_DIST
		var limit := STUCK_FAR_SEC if far else STUCK_NEAR_SEC
		if _stuck_time > limit:
			if far and _stuck_retries < 2:
				_stuck_retries += 1
				_stuck_time = 0.0
				nav_agent.target_position = _target_pos  # nudge a fresh path
			else:
				_arrive()
	else:
		_stuck_time = 0.0
	_last_pos = global_position


func _on_velocity_computed(safe_velocity: Vector2) -> void:
	if not _nav_active:
		return
	velocity = safe_velocity
	move_and_slide()


func _arrive() -> void:
	if not _nav_active:
		return
	_nav_active = false
	velocity = Vector2.ZERO
	_vel = Vector2.ZERO
	nav_agent.velocity = Vector2.ZERO
	# Never tween/teleport across free space — that ignored nav and walked
	# through walls. Snap only when already within a tiny radius of the seat.
	var gap := global_position.distance_to(_target_pos)
	if gap > 0.5 and gap < 10.0:
		global_position = _target_pos
		gap = 0.0
	# Amenity poses only at the real spot. A stuck/partial arrival in a spoke
	# corridor or team room must not yoga / meditate / sit foosball there.
	if gap > SEAT_ARRIVE_MAX:
		_pending_seat = ""
	_finish_settle()


func _finish_settle() -> void:
	_settling = false
	_seat = _pending_seat
	_play_anim()
	arrived.emit(self, current_waypoint)


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_anim_time += delta
	var spd := velocity.length() if _nav_active else 0.0
	if _settling:
		spd = 20.0
	_walk_amount = move_toward(_walk_amount, clampf(spd / move_speed, 0.0, 1.0), delta * 4.0)
	_walk_phase += spd * delta * 0.11
	if spd > 5.0:
		_dir = _dir.lerp(velocity.normalized() if velocity.length() > 1.0 else _dir, clampf(delta * 6.0, 0.0, 1.0))
	var sit_target := 1.0 if (_seat != "" and is_at_destination()) else 0.0
	_sit = move_toward(_sit, sit_target, delta * 3.0)
	if sprite.visible:
		sprite.flip_h = _side() < -0.3
		sprite.position.y = -32 + SIT_DROP.get(_seat, 0.0) * _sit
		_play_anim()
	_position_bubble()
	sync_view()


## Puts the render node at the projected feet and redraws it.
func sync_view() -> void:
	if view:
		view.position = Iso.to_screen(global_position)
		view.queue_redraw()


const FACING_DIRS := {"up": Vector2(0, -1), "down": Vector2(0, 1), "left": Vector2(-1, 0), "right": Vector2(1, 0)}


## Back view when walking away from the viewer or sitting facing away (desk,
## far side of tables). In the isometric view "away" is up the screen, so
## north and west facings show the back.
func _is_back() -> bool:
	if _walk_amount > 0.25:
		return Iso.screen_dir(_dir).y < (-0.2 if Iso.enabled else -0.55)
	if Iso.enabled:
		return Iso.screen_dir(FACING_DIRS.get(_pose_facing, Vector2.DOWN)).y < 0.0
	return _pose_facing == "up"


## -1 (looking left) .. 1 (looking right).
func _side() -> float:
	if _walk_amount > 0.25:
		return clampf(Iso.screen_dir(_dir).x * 1.4, -1.0, 1.0)
	if Iso.enabled:
		return 0.6 * signf(Iso.screen_dir(FACING_DIRS.get(_pose_facing, Vector2.DOWN)).x)
	match _pose_facing:
		"left": return -1.0
		"right": return 1.0
	return 0.0


## Hook for sprite-based animation. Procedural mode just redraws.
func _play_anim() -> void:
	if not sprite.visible or sprite.sprite_frames == null:
		return
	var anim := "idle"
	if _walk_amount > 0.25:
		anim = "walk"
	elif is_phone_out() and sprite.sprite_frames.has_animation("phone"):
		anim = "phone"
	else:
		match state:
			"WORKING": anim = "work" if _seat == "desk" else "idle"
			"THINKING": anim = "think"
			"COLLAB": anim = "collab"
	if sprite.sprite_frames.has_animation(anim) and sprite.animation != anim:
		sprite.play(anim)


func _head_top() -> float:
	return -50.0 - HEAD_R + SIT_DROP.get(_seat, 0.0) * _sit


func _position_bubble() -> void:
	if not bubble.visible:
		return
	var s := bubble.size
	bubble.pivot_offset = Vector2(s.x * 0.5, s.y)
	bubble.position = Vector2(-s.x * 0.5, _head_top() - 22.0 - s.y)


func _draw() -> void:
	pass  # the AgentView in the sorted render layer draws us (see paint())


## Draws the character into `canvas` (its AgentView) at the canvas origin = feet.
func paint(canvas: CanvasItem) -> void:
	_c = canvas
	_paint()


func _paint() -> void:
	var state_col: Color = STATE_COLORS.get(state, Color.GRAY)
	# Soft shadow + state ring at the feet.
	_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.42))
	_c.draw_circle(Vector2.ZERO, 16.0, Color(0, 0, 0, 0.22))
	_c.draw_circle(Vector2.ZERO, 11.0, Color(0, 0, 0, 0.12))
	_c.draw_arc(Vector2.ZERO, 22.0, 0.0, TAU, 48, Color(state_col, 0.95), 3.0, true)
	if _selected:
		# Clear selection: bright outline + filled floor ring.
		_c.draw_circle(Vector2.ZERO, 28.0, Color(1, 1, 1, 0.18))
		_c.draw_arc(Vector2.ZERO, 28.0, 0.0, TAU, 48, Color(1, 1, 1, 0.98), 3.2, true)
		_c.draw_arc(Vector2.ZERO, 32.0, 0.0, TAU, 48, Color(body_color, 0.85), 2.0, true)
	elif _hovered:
		_c.draw_arc(Vector2.ZERO, 26.0, 0.0, TAU, 40, Color(1, 1, 1, 0.55), 2.0, true)
	_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var drop: float = SIT_DROP.get(_seat, 0.0) * _sit
	if not sprite.visible:
		_c.draw_set_transform(Vector2(0, drop), 0.0, Vector2.ONE)
		if _is_back():
			_draw_back()
		else:
			_draw_front()
		_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_overlays(drop)
	if bubble.visible:
		_draw_bubble_tail()


# ---- drawing helpers ---------------------------------------------------------
func _cap(a: Vector2, b: Vector2, w: float, c: Color) -> void:
	_c.draw_line(a, b, c, w)
	_c.draw_circle(a, w * 0.5, c)
	_c.draw_circle(b, w * 0.5, c)


func _cap_ol(a: Vector2, b: Vector2, w: float, c: Color) -> void:
	_cap(a, b, w + 3.0, OUTLINE)
	_cap(a, b, w, c)


func _circ_ol(p: Vector2, r: float, c: Color) -> void:
	_c.draw_circle(p, r + 1.5, OUTLINE)
	_c.draw_circle(p, r, c)


func _rrect(r: Rect2, radius: float, c: Color) -> void:
	_c.draw_colored_polygon(Office.rounded_rect_points(r, radius, 3), c)


func _oval(p: Vector2, rx: float, ry: float, c: Color) -> void:
	_c.draw_set_transform(p + _xf_origin, 0.0, Vector2(rx, ry))
	_c.draw_circle(Vector2.ZERO, 1.0, c)
	_c.draw_set_transform(_xf_origin, 0.0, Vector2.ONE)


var _xf_origin := Vector2.ZERO
## The CanvasItem currently being drawn into (the AgentView during its _draw).
var _c: CanvasItem = self
## The node that draws this agent and carries its name pill, bubble and click
## area: positioned at the projected feet in the y-sorted render layer.
var view: Node2D = null


func _arm(shoulder: Vector2, elbow: Vector2, hand: Vector2) -> void:
	var sleeve := body_color.darkened(0.12)
	_cap(shoulder, elbow, 9.0, OUTLINE)
	_cap(elbow, hand, 8.0, OUTLINE)
	_cap(shoulder, elbow, 6.0, sleeve)
	_cap(elbow, hand, 5.0, _look.skin.darkened(0.03) if elbow.distance_to(hand) > 4 else sleeve)
	_circ_ol(hand, 3.0, _look.skin)


## Pose-dependent bob and leg phase.
func _bob() -> float:
	var walk := _walk_amount
	return -absf(sin(_walk_phase)) * 2.2 * walk + sin(_anim_time * 2.0) * 0.6 * (1.0 - walk)


# ---- front view ---------------------------------------------------------------
func _draw_front() -> void:
	_xf_origin = Vector2(0, SIT_DROP.get(_seat, 0.0) * _sit)
	var t := _anim_time
	var bob := _bob()
	var side := _side()
	var seated := _sit > 0.5 and _seat in ["chair", "sofa", "desk", "meditate"]
	var phone := is_phone_out()
	var skin: Color = _look.skin
	var H := Vector2(side * 1.5, -50.0 + bob)
	if phone:
		H.y += 1.0  # looking down at the phone

	# Legs.
	var hip_y := -13.0 + bob
	if seated:
		_cap_ol(Vector2(-5, hip_y), Vector2(-6, hip_y + 6), 7.0, _look.pants)
		_cap_ol(Vector2(5, hip_y), Vector2(6, hip_y + 6), 7.0, _look.pants)
		_oval(Vector2(-6, hip_y + 9), 4.5, 3.0, OUTLINE)
		_oval(Vector2(6, hip_y + 9), 4.5, 3.0, OUTLINE)
	else:
		var lift_l := maxf(0.0, sin(_walk_phase)) * 3.5 * _walk_amount
		var lift_r := maxf(0.0, -sin(_walk_phase)) * 3.5 * _walk_amount
		var swing := sin(_walk_phase) * 2.0 * _walk_amount * (1.0 if absf(side) > 0.4 else 0.0)
		var fl := Vector2(-5 + swing, -2.5 - lift_l)
		var fr := Vector2(5 - swing, -2.5 - lift_r)
		_cap_ol(Vector2(-5, hip_y), fl, 7.0, _look.pants)
		_cap_ol(Vector2(5, hip_y), fr, 7.0, _look.pants)
		_oval(fl + Vector2(-0.5 + side, 1.5), 4.8, 3.0, OUTLINE)
		_oval(fr + Vector2(0.5 + side, 1.5), 4.8, 3.0, OUTLINE)
		_oval(fl + Vector2(-0.5 + side, 1.0), 3.6, 2.0, Color("#5d4037"))
		_oval(fr + Vector2(0.5 + side, 1.0), 3.6, 2.0, Color("#5d4037"))

	# Torso (outlined, with highlight and shade).
	var breathe := sin(t * 2.0) * 0.5
	var torso := Rect2(-11, -31 + bob - breathe, 22, 20 + breathe)
	_rrect(torso.grow(1.5), 7.5, OUTLINE)
	_rrect(torso, 6, body_color)
	_rrect(Rect2(torso.position.x + 2, torso.position.y + 3, 5, torso.size.y - 7), 2.5, body_color.lightened(0.28))
	_rrect(Rect2(torso.end.x - 6, torso.position.y + 3, 4, torso.size.y - 6), 2.0, body_color.darkened(0.18))
	_c.draw_rect(Rect2(torso.position.x + 1, torso.end.y - 4, torso.size.x - 2, 3), _look.pants.darkened(0.1))
	_c.draw_colored_polygon(PackedVector2Array([Vector2(-3.5, torso.position.y), Vector2(3.5, torso.position.y), Vector2(0, torso.position.y + 4.5)]), skin)
	_c.draw_line(Vector2(-4.5, torso.position.y + 0.5), Vector2(0, torso.position.y + 5), body_color.lightened(0.45), 1.2)
	_c.draw_line(Vector2(4.5, torso.position.y + 0.5), Vector2(0, torso.position.y + 5), body_color.lightened(0.45), 1.2)
	# Lanyard badge.
	_c.draw_line(Vector2(-2, torso.position.y + 4), Vector2(3, torso.position.y + 10), Color(_look.accent, 0.9), 1.0)
	_c.draw_rect(Rect2(2, torso.position.y + 9, 4, 5), Color(1, 1, 1, 0.9))

	# Hair behind the head (long styles).
	_hair_back_layer(H, false)
	# Ears + head.
	_circ_ol(H + Vector2(-HEAD_R + 0.5 - side, 2), 3.2, skin)
	_circ_ol(H + Vector2(HEAD_R - 0.5 - side, 2), 3.2, skin)
	_circ_ol(H, HEAD_R, skin)
	_c.draw_circle(H + Vector2(0, 5), HEAD_R * 0.75, Color(skin.darkened(0.05), 0.35))
	# Face.
	_draw_face(H, side, phone)
	# Hair + accessories.
	_hair_front(H, side)
	_accessory_front(H, side)

	# Arms (in front of the torso).
	var sh := -28.0 + bob
	var L := Vector2(-11, sh)
	var R := Vector2(11, sh)
	if _seat == "yoga" and _sit > 0.5:
		_draw_yoga_pose(H, L, R, sh, side, t, false)
	elif _seat == "meditate" and _sit > 0.5:
		_draw_meditate_pose(H, L, R, sh, side, t, false)
	elif _seat == "foosball" and _sit > 0.5:
		var w := sin(t * 14.0) * 2.0
		var d := 1.0 if side >= 0.0 else -1.0
		_arm(L, Vector2(-6 + d * 6, sh + 6), Vector2(d * 18, -21 + w))
		_arm(R, Vector2(6 + d * 6, sh + 6), Vector2(d * 22, -20 - w))
	elif phone:
		_arm(L, Vector2(-14, sh + 8), Vector2(-12, sh + 15))
		_arm(R, Vector2(13, sh + 9), Vector2(5, sh + 3))
		_draw_phone(Vector2(4, sh - 3), false)
	elif awaiting_input:
		# Raised hand — needs a human reply.
		_arm(L, Vector2(-12, sh + 9), Vector2(-8, sh + 14))
		_arm(R, Vector2(12, sh), Vector2(10, H.y - 8))
		_c.draw_circle(Vector2(10, H.y - 10), 4.0, _look.skin)
	elif state == "THINKING":
		_arm(L, Vector2(-12, sh + 9), Vector2(1, sh + 9))
		_arm(R, Vector2(13, sh + 8), Vector2(6, H.y + 10))
	elif state == "COLLAB":
		var g := sin(t * 5.0)
		_arm(L, Vector2(-14, sh + 8), Vector2(-13, sh + 15))
		_arm(R, Vector2(15, sh + 4), Vector2(17 + g * 2.0, sh - 4 + g * 5.0))
	elif seated:
		_arm(L, Vector2(-13, sh + 9), Vector2(-6, sh + 15))
		_arm(R, Vector2(13, sh + 9), Vector2(6, sh + 15))
	else:
		var sw := sin(_walk_phase) * 3.5 * _walk_amount
		_arm(L, Vector2(-13.5, sh + 7 - sw * 0.5), Vector2(-13 - absf(side) * 1.0, sh + 14 - sw))
		_arm(R, Vector2(13.5, sh + 7 + sw * 0.5), Vector2(13 + absf(side) * 1.0, sh + 14 + sw))
	if is_eating():
		_draw_food_plate(false)
	_xf_origin = Vector2.ZERO


func _draw_face(H: Vector2, side: float, phone: bool) -> void:
	var t := _anim_time
	var look := Vector2(side * 2.5, 2.0 if phone else 0.0)
	var blink := fmod(t + _blink_seed, 3.7) < 0.13
	var eye_col := Color("#2b2233")
	for ex: float in [-5.0, 5.0]:
		var e := H + Vector2(ex, 1) + look
		if blink:
			_c.draw_line(e + Vector2(-2.2, 0), e + Vector2(2.2, 0), eye_col, 1.6)
		else:
			_oval(e, 2.2, 3.0, eye_col)
			_c.draw_circle(e + Vector2(-0.7, -1.2), 0.9, Color.WHITE)
		# Eyebrows (raised while thinking).
		var by := -5.0 - (1.5 if state == "THINKING" else 0.0)
		_c.draw_line(e + Vector2(-2.5, by), e + Vector2(2.5, by - (0.6 if ex > 0 else -0.6) * (1.0 if state == "THINKING" else 0.0)), Color(_look.hair.darkened(0.2), 0.9), 1.4)
	# Cheeks.
	_c.draw_circle(H + Vector2(-8.5 + look.x, 6), 2.4, Color(1.0, 0.45, 0.45, 0.28))
	_c.draw_circle(H + Vector2(8.5 + look.x, 6), 2.4, Color(1.0, 0.45, 0.45, 0.28))
	# Mouth.
	var m := H + Vector2(look.x, 7.5 + look.y * 0.5)
	var talking := (state == "COLLAB" or (bubble.visible and not _bubble_is_thought)) and fmod(t, 0.36) < 0.2
	var mouth_col := Color("#7a2e35")
	if talking:
		_oval(m + Vector2(0, 0.5), 2.6, 2.0, mouth_col)
		_c.draw_circle(m + Vector2(0, 1.4), 1.2, Color("#e57373"))
	elif state == "THINKING":
		_c.draw_line(m + Vector2(-1.5, 0.5), m + Vector2(2.5, -0.3), mouth_col, 1.5)
	else:
		_c.draw_arc(m + Vector2(0, -2.2), 3.0, 0.2 * PI, 0.8 * PI, 8, mouth_col, 1.5)


func _hair_back_layer(H: Vector2, _back: bool) -> void:
	var c: Color = _look.hair
	match str(_look.style):
		"long":
			_rrect(Rect2(H.x - HEAD_R - 2.5, H.y - 4, HEAD_R * 2 + 5, 24).grow(1.5), 6, OUTLINE)
			_rrect(Rect2(H.x - HEAD_R - 2.5, H.y - 4, HEAD_R * 2 + 5, 24), 6, c)
		"ponytail":
			var sway := sin(_anim_time * 3.0 + _walk_phase) * 1.5
			_circ_ol(H + Vector2(HEAD_R + 2 + sway, 1), 5.0, c)
			_circ_ol(H + Vector2(HEAD_R + 3 + sway, 8), 3.5, c)


func _hair_front(H: Vector2, side: float) -> void:
	var c: Color = _look.hair
	var hl := c.lightened(0.25)
	var style := str(_look.style)
	if _look.acc in ["cap", "beanie"]:
		return  # headwear replaces the hair cap
	# Cap of hair over the top of the head with a fringe.
	# The arc ends exactly at fringe height so the outline never self-intersects.
	var pts := PackedVector2Array()
	var steps := 14
	var fringe_y := H.y - (8.0 if style == "buzz" else 3.0)
	var rr := HEAD_R + 1.2
	var half := asin(clampf((H.y - fringe_y) / rr, 0.0, 0.9))
	for i in steps + 1:
		var a := PI + half + (PI - 2.0 * half) * i / steps
		pts.append(H + Vector2(cos(a), sin(a)) * rr)
	var x_end := rr * cos(half) * 0.9
	var n := 6
	for i in range(1, n):
		var x := H.x + x_end - (2.0 * x_end) * i / n + side * 1.0
		var y := fringe_y - (3.5 if i % 2 == 1 and style not in ["buzz", "sidepart"] else 0.0)
		if style == "sidepart":
			y = fringe_y - 5.0 + 5.0 * i / n
		pts.append(Vector2(x, y))
	match style:
		"spiky":
			for k in 5:
				var a := PI * (1.1 + 0.2 * k)
				var base := H + Vector2(cos(a), sin(a)) * (HEAD_R - 1)
				var tip := H + Vector2(cos(a), sin(a)) * (HEAD_R + 7)
				var perp := Vector2(-sin(a), cos(a)) * 4.0
				_c.draw_colored_polygon(PackedVector2Array([base - perp * 1.4, tip, base + perp * 1.4]), OUTLINE)
				_c.draw_colored_polygon(PackedVector2Array([base - perp, tip + (base - tip).normalized() * 1.5, base + perp]), c)
		"curly":
			for k in 7:
				var a := PI * (1.0 + k / 6.0)
				_circ_ol(H + Vector2(cos(a), sin(a)) * (HEAD_R + 1), 4.5, c)
		"bun":
			_circ_ol(H + Vector2(0, -HEAD_R - 3), 6.0, c)
	_c.draw_polyline(pts + PackedVector2Array([pts[0]]), OUTLINE, 2.5, true)
	_c.draw_colored_polygon(pts, c)
	if style in ["bob", "long"]:
		for sx: float in [-1.0, 1.0]:
			var r := Rect2(H.x + sx * (HEAD_R - 1.5) - 3.5, H.y - 4, 7, 15 if style == "bob" else 20)
			_rrect(r.grow(1.3), 4, OUTLINE)
			_rrect(r, 3.5, c)
	if style == "curly":
		for k in 5:
			var a := PI * (1.1 + k / 5.0)
			_c.draw_circle(H + Vector2(cos(a), sin(a)) * (HEAD_R - 1), 4.0, c)
	# Shine.
	_c.draw_arc(H + Vector2(-3, -5), HEAD_R - 4, PI * 1.15, PI * 1.45, 6, Color(hl, 0.8), 2.0)


func _accessory_front(H: Vector2, side: float) -> void:
	var acc := str(_look.acc)
	var a: Color = _look.accent
	match acc:
		"glasses":
			for ex: float in [-5.0, 5.0]:
				_c.draw_arc(H + Vector2(ex + side * 2.5, 1), 4.3, 0, TAU, 16, Color("#263238"), 1.5)
			_c.draw_line(H + Vector2(-0.8 + side * 2.5, 0), H + Vector2(0.8 + side * 2.5, 0), Color("#263238"), 1.5)
		"headphones":
			_c.draw_arc(H, HEAD_R + 3.0, PI * 1.05, PI * 1.95, 16, OUTLINE, 5.0)
			_c.draw_arc(H, HEAD_R + 3.0, PI * 1.05, PI * 1.95, 16, Color("#455a64"), 3.0)
			_circ_ol(H + Vector2(-HEAD_R - 1, 1), 4.5, a)
			_circ_ol(H + Vector2(HEAD_R + 1, 1), 4.5, a)
		"beard":
			var pts := PackedVector2Array()
			for i in 11:
				var ang := 0.1 * PI + 0.8 * PI * i / 10.0
				pts.append(H + Vector2(cos(ang) * (HEAD_R - 0.5), sin(ang) * (HEAD_R - 0.5)))
			for i in 5:
				var x := H.x - 7.0 + 14.0 * i / 4.0
				pts.append(Vector2(x, H.y + 5.0 + (1.0 if i % 2 == 0 else 0.0)))
			_c.draw_colored_polygon(pts, _look.hair)
			_c.draw_line(H + Vector2(-2.5 + side * 2, 8), H + Vector2(2.5 + side * 2, 8), Color("#7a2e35"), 1.5)
		"cap", "beanie":
			var pts := PackedVector2Array()
			for i in 15:
				var ang := PI + 0.2 + (PI - 0.4) * i / 14.0
				pts.append(H + Vector2(cos(ang), sin(ang)) * (HEAD_R + 2.0))
			_c.draw_polyline(pts + PackedVector2Array([pts[0]]), OUTLINE, 2.5, true)
			_c.draw_colored_polygon(pts, a)
			if acc == "cap":
				_oval(H + Vector2(side * 4.0, -3), HEAD_R * 0.8, 3.0, a.darkened(0.3))
			else:
				_c.draw_rect(Rect2(H.x - HEAD_R - 2, H.y - 6, HEAD_R * 2 + 4, 4), a.darkened(0.2))
				_circ_ol(H + Vector2(0, -HEAD_R - 3), 3.0, a.lightened(0.3))
		"bow":
			var b := H + Vector2(HEAD_R - 3, -HEAD_R + 3)
			_c.draw_colored_polygon(PackedVector2Array([b, b + Vector2(-6, -4), b + Vector2(-6, 4)]), a)
			_c.draw_colored_polygon(PackedVector2Array([b, b + Vector2(6, -4), b + Vector2(6, 4)]), a)
			_c.draw_circle(b, 2.0, a.darkened(0.25))


# ---- back view ----------------------------------------------------------------
func _draw_back() -> void:
	_xf_origin = Vector2(0, SIT_DROP.get(_seat, 0.0) * _sit)
	var t := _anim_time
	var bob := _bob()
	var at_desk := _seat in ["desk", "foosball"] and _sit > 0.5
	var seated := _sit > 0.5 and _seat not in ["foosball", "yoga"]
	var skin: Color = _look.skin
	var H := Vector2(0, -50.0 + bob)
	var sh := -28.0 + bob

	if not seated:
		var lift_l := maxf(0.0, sin(_walk_phase)) * 3.5 * _walk_amount
		var lift_r := maxf(0.0, -sin(_walk_phase)) * 3.5 * _walk_amount
		_cap_ol(Vector2(-5, -13 + bob), Vector2(-5, -2.5 - lift_l), 7.0, _look.pants)
		_cap_ol(Vector2(5, -13 + bob), Vector2(5, -2.5 - lift_r), 7.0, _look.pants)
		_oval(Vector2(-5, -1 - lift_l), 4.5, 2.6, OUTLINE)
		_oval(Vector2(5, -1 - lift_r), 4.5, 2.6, OUTLINE)

	# Arms that reach forward go *behind* the body: draw them first.
	var typing := at_desk and (state == "WORKING" or _seat == "foosball")
	var tap_l := sin(t * 18.0) * 1.6 if typing else 0.0
	var tap_r := sin(t * 18.0 + 2.0) * 1.6 if typing else 0.0
	if at_desk:
		if awaiting_input:
			_arm(Vector2(-11, sh), Vector2(-16, sh + 2), Vector2(-12, sh + 8))
			_arm(Vector2(11, sh), Vector2(14, sh - 12), Vector2(8, H.y - 6))
		elif state == "THINKING":
			_arm(Vector2(-11, sh), Vector2(-17, sh - 2), Vector2(-15, sh - 6))
		else:
			_arm(Vector2(-11, sh), Vector2(-17, sh - 1), Vector2(-15, sh - 5 + tap_l))
			_arm(Vector2(11, sh), Vector2(17, sh - 1), Vector2(15, sh - 5 + tap_r))

	# Torso from behind.
	var torso := Rect2(-11, -31 + bob, 22, 20)
	_rrect(torso.grow(1.5), 7.5, OUTLINE)
	_rrect(torso, 6, body_color)
	_rrect(Rect2(torso.end.x - 7, torso.position.y + 3, 5, torso.size.y - 7), 2.5, body_color.lightened(0.22))
	_rrect(Rect2(torso.position.x + 2, torso.position.y + 3, 4, torso.size.y - 6), 2.0, body_color.darkened(0.18))
	_c.draw_line(Vector2(0, torso.position.y + 4), Vector2(0, torso.end.y - 4), body_color.darkened(0.12), 1.0)
	_c.draw_rect(Rect2(torso.position.x + 1, torso.end.y - 4, torso.size.x - 2, 3), _look.pants.darkened(0.1))
	# Neck.
	_c.draw_rect(Rect2(-3.5, torso.position.y - 4, 7, 5), skin.darkened(0.08))

	# Head from behind: ears, then hair covering most of it.
	_circ_ol(H + Vector2(-HEAD_R + 0.5, 2), 3.2, skin)
	_circ_ol(H + Vector2(HEAD_R - 0.5, 2), 3.2, skin)
	_circ_ol(H, HEAD_R, skin)
	var c: Color = _look.hair
	var style := str(_look.style)
	if _look.acc in ["cap", "beanie"]:
		_c.draw_circle(H, HEAD_R - 0.5, c)  # short hair under the hat
		var pts := PackedVector2Array()
		for i in 15:
			var ang := PI + PI * i / 14.0
			pts.append(H + Vector2(cos(ang), sin(ang)) * (HEAD_R + 2.0))
		_c.draw_colored_polygon(pts, _look.accent)
	else:
		# Hair covers the head except a gap at the nape (bigger for a buzz cut).
		var gap := PI * (1.0 if style == "buzz" else 0.45)
		var pts := PackedVector2Array()
		for i in 21:
			var ang := PI * 0.5 + gap * 0.5 + (TAU - gap) * i / 20.0
			pts.append(H + Vector2(cos(ang), sin(ang)) * (HEAD_R + 1.0))
		_c.draw_colored_polygon(pts, c.darkened(0.1) if style == "buzz" else c)
		match style:
			"long":
				_rrect(Rect2(H.x - HEAD_R, H.y, HEAD_R * 2, 20).grow(1.2), 6, OUTLINE)
				_rrect(Rect2(H.x - HEAD_R, H.y, HEAD_R * 2, 20), 6, c)
			"bob":
				_rrect(Rect2(H.x - HEAD_R - 1, H.y, HEAD_R * 2 + 2, 10), 4, c)
			"ponytail":
				var sway := sin(t * 3.0 + _walk_phase) * 1.5
				_circ_ol(H + Vector2(sway, HEAD_R - 2), 5.0, c)
				_circ_ol(H + Vector2(sway * 1.3, HEAD_R + 5), 3.5, c)
				_c.draw_circle(H + Vector2(sway, HEAD_R - 6), 2.0, _look.accent)
			"bun":
				_circ_ol(H + Vector2(0, -HEAD_R - 2), 6.0, c)
			"spiky":
				for k in 5:
					var ang := PI * (1.1 + 0.2 * k)
					var base := H + Vector2(cos(ang), sin(ang)) * (HEAD_R - 1)
					var tip := H + Vector2(cos(ang), sin(ang)) * (HEAD_R + 6)
					var perp := Vector2(-sin(ang), cos(ang)) * 4.0
					_c.draw_colored_polygon(PackedVector2Array([base - perp, tip, base + perp]), c)
			"curly":
				for k in 9:
					var ang := PI * (0.9 + k * 1.2 / 8.0)
					_c.draw_circle(H + Vector2(cos(ang), sin(ang)) * (HEAD_R), 4.5, c)
		_c.draw_arc(H + Vector2(3, -4), HEAD_R - 4, PI * 1.55, PI * 1.85, 6, Color(c.lightened(0.25), 0.8), 2.0)
	if _look.acc == "headphones":
		_c.draw_arc(H, HEAD_R + 3.0, PI * 1.05, PI * 1.95, 16, Color("#455a64"), 3.0)
		_circ_ol(H + Vector2(-HEAD_R - 1, 1), 4.5, _look.accent)
		_circ_ol(H + Vector2(HEAD_R + 1, 1), 4.5, _look.accent)
	elif _look.acc == "glasses":
		_c.draw_line(H + Vector2(-HEAD_R, 0), H + Vector2(-HEAD_R + 4, 1), Color("#263238"), 1.4)
		_c.draw_line(H + Vector2(HEAD_R, 0), H + Vector2(HEAD_R - 4, 1), Color("#263238"), 1.4)

	# Arms visible at the sides.
	if at_desk:
		if state == "THINKING":
			_arm(Vector2(11, sh), Vector2(15, sh - 10), Vector2(8, H.y - 6))  # scratching head
	elif is_phone_out():
		_arm(Vector2(-11, sh), Vector2(-14, sh + 8), Vector2(-7, sh + 2))
		_arm(Vector2(11, sh), Vector2(14, sh + 8), Vector2(7, sh + 2))
		_c.draw_circle(Vector2(0, sh - 2), 10.0, Color(0.55, 0.85, 1.0, 0.18))  # screen glow
	elif _seat == "yoga" and _sit > 0.5:
		_draw_yoga_pose(H, Vector2(-11, sh), Vector2(11, sh), sh, 0.0, t, true)
	elif _seat == "meditate" and _sit > 0.5:
		_draw_meditate_pose(H, Vector2(-11, sh), Vector2(11, sh), sh, 0.0, t, true)
	elif state == "COLLAB" and seated:
		var g := sin(t * 5.0)
		_arm(Vector2(-11, sh), Vector2(-15, sh + 6), Vector2(-12, sh + 12))
		_arm(Vector2(11, sh), Vector2(17, sh - 2), Vector2(18 + g * 2.0, sh - 8 + g * 4.0))
	else:
		var sw := sin(_walk_phase) * 3.5 * _walk_amount
		_arm(Vector2(-11, sh), Vector2(-13.5, sh + 7 + sw * 0.5), Vector2(-13, sh + 14 + sw))
		_arm(Vector2(11, sh), Vector2(13.5, sh + 7 - sw * 0.5), Vector2(13, sh + 14 - sw))
	if is_eating():
		_draw_food_plate(true)
	_xf_origin = Vector2.ZERO


## Plate of food in front of a diner at the canteen.
func _draw_food_plate(from_back: bool) -> void:
	var food_cols := [Color("#ef6c00"), Color("#66bb6a"), Color("#8d6e63"), Color("#ff7043"), Color("#42a5f5"), Color("#fdd835")]
	var idx: int = absi(hash(agent_id + last_text)) % food_cols.size()
	var col: Color = food_cols[idx]
	# Offset toward the table based on facing.
	var off := Vector2(0, 10)
	match _pose_facing:
		"right":
			off = Vector2(14, 6)
		"left":
			off = Vector2(-14, 6)
		"up":
			off = Vector2(0, -8) if from_back else Vector2(0, 10)
		"down":
			off = Vector2(0, 10)
	# Tray
	_c.draw_rect(Rect2(off.x - 9, off.y - 5, 18, 12), Color("#eceff1"))
	_c.draw_rect(Rect2(off.x - 9, off.y - 5, 18, 12), Color("#b0bec5"), false, 1.0)
	# Plate
	_oval(off + Vector2(-1, 0), 6.5, 4.2, Color("#fafafa"))
	_oval(off + Vector2(-1, 0), 4.2, 2.8, col)
	# Garnish
	_c.draw_circle(off + Vector2(-3, -1), 1.4, Color(1, 1, 1, 0.7))
	_c.draw_circle(off + Vector2(2, 1), 1.2, col.darkened(0.25))
	# Cup
	_c.draw_rect(Rect2(off.x + 5, off.y - 4, 4, 6), Color("#fff8e1"))
	_c.draw_rect(Rect2(off.x + 5, off.y - 4, 4, 6), Color("#bcaaa4"), false, 1.0)



## Yoga pose cycle: tree (~0-2.5s), downward dog (~2.5-5s), stretch (~5-7.5s).
func _yoga_phase() -> int:
	return int(fmod(_anim_time, 7.5) / 2.5)


func _draw_yoga_pose(H: Vector2, L: Vector2, R: Vector2, sh: float, side: float, t: float, _back: bool) -> void:
	var phase := _yoga_phase()
	match phase:
		0:  # tree — one foot on calf, arms up
			_arm(L, Vector2(-8, sh - 2), Vector2(-4, H.y - 6))
			_arm(R, Vector2(8, sh - 2), Vector2(4, H.y - 6))
			# Hands together above head
			_c.draw_circle(Vector2(0, H.y - 10), 3.0, _look.skin)
		1:  # downward dog — lean forward, arms reach down/out
			_arm(L, Vector2(-14, sh + 4), Vector2(-16, sh + 16))
			_arm(R, Vector2(14, sh + 4), Vector2(16, sh + 16))
		_:  # stretch — arms wide overhead
			var wiggle := sin(t * 2.0) * 2.0
			_arm(L, Vector2(-12, sh - 4), Vector2(-18 + wiggle, H.y - 4))
			_arm(R, Vector2(12, sh - 4), Vector2(18 - wiggle, H.y - 4))


func _draw_meditate_pose(H: Vector2, L: Vector2, R: Vector2, sh: float, side: float, t: float, _back: bool) -> void:
	# Hands resting on knees / mudra near lap
	_arm(L, Vector2(-12, sh + 8), Vector2(-8, sh + 16))
	_arm(R, Vector2(12, sh + 8), Vector2(8, sh + 16))
	# Floating zen particle / om bubble
	var bob := sin(t * 2.2) * 4.0
	var zen := Vector2(0, H.y - 18 + bob)
	var a := 0.55 + 0.35 * sin(t * 3.0)
	_c.draw_circle(zen, 7.0, Color(0.75, 0.55, 0.95, a * 0.35))
	_c.draw_circle(zen, 4.5, Color(0.95, 0.85, 1.0, a * 0.7))
	_c.draw_string(ThemeDB.fallback_font, zen + Vector2(-5, 3), "om", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.45, 0.2, 0.55, a))
	# Soft orbiting dots
	for i in 3:
		var ang := t * 1.4 + i * TAU / 3.0
		var p := zen + Vector2(cos(ang), sin(ang)) * 12.0
		_c.draw_circle(p, 1.6, Color(0.7, 0.9, 1.0, a * 0.8))


func _draw_phone(p: Vector2, _back: bool) -> void:
	var glow := 0.55 + 0.2 * sin(_anim_time * 6.0)
	_c.draw_circle(p + Vector2(0, 2), 9.0, Color(0.55, 0.85, 1.0, 0.18))
	_rrect(Rect2(p.x - 3.5, p.y - 2, 7, 10).grow(1.0), 2, OUTLINE)
	_rrect(Rect2(p.x - 3.5, p.y - 2, 7, 10), 1.5, Color("#263238"))
	_c.draw_rect(Rect2(p.x - 2.5, p.y - 1, 5, 7.5), Color(0.6, 0.88, 1.0, glow))
	_c.draw_line(Vector2(p.x - 1.5, p.y + 1), Vector2(p.x + 1.5, p.y + 1), Color(1, 1, 1, 0.8), 0.8)
	_c.draw_line(Vector2(p.x - 1.5, p.y + 3), Vector2(p.x + 0.5, p.y + 3), Color(1, 1, 1, 0.8), 0.8)


## Things above the head: thought dots, phone ping.
func _draw_overlays(drop: float) -> void:
	var t := _anim_time
	var top := Vector2(14, _head_top() - 4)
	if state == "THINKING" and not bubble.visible:
		_c.draw_circle(top + Vector2(-6, 10), 2.0, Color(1, 1, 1, 0.85))
		_c.draw_circle(top + Vector2(-2, 5), 3.0, Color(1, 1, 1, 0.9))
		_rrect(Rect2(top.x - 2, top.y - 12, 26, 13), 6.5, Color(1, 1, 1, 0.95))
		for i in 3:
			var a := 0.3 + 0.7 * clampf(sin(t * 5.0 - i * 0.9), 0.0, 1.0)
			_c.draw_circle(top + Vector2(4 + i * 7, -5.5), 2.0, Color(0.25, 0.25, 0.3, a))
	if unread > 0:
		# Envelope: messages waiting for this bot to check in.
		var bob := sin(t * 2.5) * 1.5
		var e := Vector2(-24, _head_top() - 8 + bob)
		_c.draw_set_transform(e, 0.0, Vector2.ONE * _ui_scale)
		_rrect(Rect2(-10, -7, 20, 14), 2.5, OUTLINE)
		_rrect(Rect2(-9, -6, 18, 12), 2, Color("#fff8e1"))
		_c.draw_polyline(PackedVector2Array([Vector2(-8.5, -5.5), Vector2(0, 1), Vector2(8.5, -5.5)]), Color("#8d6e63"), 1.4)
		if unread > 1:
			_c.draw_circle(Vector2(9, -7), 6.0, Color("#e53935"))
			_c.draw_string(ThemeDB.fallback_font, Vector2(5.5 if unread < 10 else 3.0, -3.0), str(mini(unread, 99)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE)
		_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if state == "ERROR":
		# Unmistakable warning triangle + bang (colour + shape + pulse).
		var p := Vector2(18, _head_top() - 12)
		var pulse := 1.0 + 0.14 * sin(t * 7.0)
		_c.draw_set_transform(p, 0.0, Vector2.ONE * pulse * maxf(_ui_scale, 1.0))
		var tri := PackedVector2Array([Vector2(0, -12), Vector2(12, 10), Vector2(-12, 10)])
		_c.draw_colored_polygon(tri, OUTLINE)
		_c.draw_colored_polygon(PackedVector2Array([Vector2(0, -9), Vector2(9.5, 8), Vector2(-9.5, 8)]), Color("#ffc107"))
		_c.draw_colored_polygon(PackedVector2Array([Vector2(0, -6), Vector2(6.5, 6), Vector2(-6.5, 6)]), STATE_COLORS["ERROR"])
		_c.draw_rect(Rect2(-1.5, -3.5, 3.0, 6.0), Color.WHITE)
		_c.draw_circle(Vector2(0, 5.0), 1.6, Color.WHITE)
		_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if awaiting_input and state != "ERROR":
		var p2 := Vector2(18, _head_top() - 8)
		var bob2 := sin(t * 4.0) * 2.0
		_c.draw_set_transform(p2 + Vector2(0, bob2), 0.0, Vector2.ONE * maxf(_ui_scale, 1.0))
		_c.draw_circle(Vector2.ZERO, 9.0, OUTLINE)
		_c.draw_circle(Vector2.ZERO, 7.5, Color("#ffb74d"))
		_c.draw_string(ThemeDB.fallback_font, Vector2(-3.5, 4.0), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#3e2723"))
		_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if t < _ping_until:
		var k := clampf((_ping_until - t) / 1.4, 0.0, 1.0)
		var p := Vector2(-20, _head_top() - 2 - (1.0 - k) * 6.0)
		var pulse := 1.0 + 0.12 * sin(t * 12.0)
		_c.draw_set_transform(p, 0.0, Vector2.ONE * pulse * _ui_scale)
		_rrect(Rect2(-9, -7, 18, 13), 5, Color(OUTLINE, k))
		_rrect(Rect2(-8, -6, 16, 11), 4, Color(1.0, 0.85, 0.3, k))
		_c.draw_colored_polygon(PackedVector2Array([Vector2(1, 4), Vector2(5, 4), Vector2(4, 8)]), Color(1.0, 0.85, 0.3, k))
		for i in 3:
			_c.draw_circle(Vector2(-4 + i * 4, -0.5), 1.2, Color(0.2, 0.2, 0.2, k))
		_c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_bubble_tail() -> void:
	var a := bubble.modulate.a
	var base := bubble.position + Vector2(bubble.size.x * 0.5, bubble.size.y)
	if _bubble_is_thought:
		_c.draw_circle(base + Vector2(-4, 8), 4.0, Color(0.93, 0.96, 1.0, a))
		_c.draw_circle(base + Vector2(-7, 15), 2.5, Color(0.93, 0.96, 1.0, a))
	else:
		_c.draw_colored_polygon(PackedVector2Array([base + Vector2(-6, -1), base + Vector2(6, -1), base + Vector2(0, 9)]), Color(1, 1, 1, a))


func _style_bubble(is_thought: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	if is_thought:
		sb.bg_color = Color(0.93, 0.96, 1.0)
		sb.set_corner_radius_all(14)
		sb.border_color = Color("#90caf9")
		sb.set_border_width_all(2)
		bubble_label.add_theme_color_override("font_color", Color("#455a64"))
	else:
		sb.bg_color = Color.WHITE
		sb.set_corner_radius_all(7)
		sb.border_color = body_color.darkened(0.2)
		sb.set_border_width_all(2)
		bubble_label.add_theme_color_override("font_color", Color("#212121"))
	sb.shadow_color = Color(0, 0, 0, 0.22)
	sb.shadow_size = 3
	bubble.add_theme_stylebox_override("panel", sb)


func _layout_bubble() -> void:
	bubble.reset_size()
	bubble.size = bubble.get_combined_minimum_size()
	_position_bubble()


func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(self)
		get_viewport().set_input_as_handled()

func set_kill_mode_active(on: bool) -> void:
	_kill_mode_active = on
	if not on:
		_set_kill_hover(false)


func _set_kill_hover(on: bool) -> void:
	_kill_hover = on
	# Tint the whole agent (sprite + body) red while the kill cursor hovers.
	var tint := KILL_HOVER_TINT if on else Color.WHITE
	modulate = tint



