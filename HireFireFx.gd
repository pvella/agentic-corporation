## Cartoon hire / fire pageantry for Agent Office.
## Hire: beam of light from above, sparkles, sprite fades in at the desk.
## Fire: playful cartoon exit (never gory); the camera glides once to frame it.
## Variants:
##   ambulance — collapse; ambulance parks outside the room door, medics walk
##               the real route in with a stretcher and carry them out (~11s)
##   stomp     — giant sneaker shadow grows, SLAM, pancake + dizzy stars, poof
##   anvil     — ACME anvil whistles down onto its growing shadow, squash, poof
##   trapdoor  — hatch opens in the floor, a wave goodbye, drop, hatch closes
##   ufo       — saucer descends, beam-up (spin + shrink), zips away
##   escort    — security guard walks them out the room door with a box of desk stuff
## Preview: Shift+F cycles; /fire-preview <variant> or variant= on PREVIEW_HIRE_FIRE.
## Alias: "medics" → "ambulance".
##
## Drawing: this node sits at the render-layer origin, so local coords are
## screen coords (Iso.to_screen of a world point). Figures and props are
## authored in agent-local units and drawn at Iso.PEOPLE_SCALE so they match
## the agents. Floor marks (shadows, dust rings, the hatch) go on a child
## layer that sits under people.
extends Node2D

const Iso := preload("res://Iso.gd")
const OfficeScript := preload("res://Office.gd")

signal finished(kind: String, agent_id: String)

const FIRE_VARIANTS := ["ambulance", "stomp", "anvil", "trapdoor", "ufo", "escort"]
const FIRE_ALIASES := {"medics": "ambulance"}
const OUTLINE := Color("#2b2d42")
const SKIN := Color("#ffd7b5")

var kind := ""           ## "hire" | "fire"
var variant := ""        ## fire variant id
var agent_id := ""
## Set by Main before play_fire: the agent's room door (world) and the unit
## vector pointing out of the room through it.
var exit_door := Vector2.INF
var exit_out := Vector2(0, 1)

var _agent: Node = null
var _t := 0.0             ## time since the animation started
var _floor: Node2D = null
var _cam: Node = null
var _cam_orig_pos := Vector2.ZERO
var _cam_orig_zoom := 1.0
var _shake := 0.0
var _from := Vector2.ZERO  ## agent world position at start
var _parts: Array[Dictionary] = []  ## puffs / sparkles in screen space
var _done := false

# Ambulance
var _van := Vector2.ZERO        ## parked position (world)
var _van_along := Vector2.RIGHT ## driving direction (world)
var _van_pos := Vector2.ZERO
var _route: PackedVector2Array = PackedVector2Array()  ## van → door → agent (world)
var _route_len := 0.0
# Escort
var _trail: Array[Vector2] = []
var _escort_target := Vector2.ZERO

static var _preview_cycle := 0


static func next_preview_variant() -> String:
	var v: String = FIRE_VARIANTS[_preview_cycle % FIRE_VARIANTS.size()]
	_preview_cycle = (_preview_cycle + 1) % FIRE_VARIANTS.size()
	return v


func _ready() -> void:
	position = Vector2.ZERO
	z_index = 30
	_floor = Node2D.new()
	_floor.z_as_relative = false
	_floor.z_index = -15  # above floors / rugs, below people and furniture
	add_child(_floor)
	_floor.draw.connect(_draw_floor_layer)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func play_hire(agent: Node, desk_pos: Vector2) -> void:
	kind = "hire"
	agent_id = str(agent.agent_id)
	_agent = agent
	_from = desk_pos
	if agent.view:
		agent.view.modulate.a = 0.0
	for i in 22:
		_parts.append({
			"p": _s(_from) + Vector2(randf_range(-26, 26), randf_range(-90, -10)) * Iso.PEOPLE_SCALE * 0.6,
			"v": Vector2(randf_range(-14, 14), randf_range(16, 50)),
			"life": randf_range(0.5, 1.3), "r": randf_range(2.0, 4.0),
			"c": Color(1.0, randf_range(0.85, 1.0), randf_range(0.4, 0.9)),
		})
	set_process(true)


func play_fire(agent: Node, entrance_pos: Vector2, forced: String = "") -> void:
	kind = "fire"
	agent_id = str(agent.agent_id)
	_agent = agent
	_from = agent.global_position
	agent.leaving = true
	if exit_door == Vector2.INF:
		exit_door = entrance_pos
	var f := forced.strip_edges().to_lower()
	f = FIRE_ALIASES.get(f, f)
	variant = f if f in FIRE_VARIANTS else FIRE_VARIANTS[randi() % FIRE_VARIANTS.size()]
	if variant != "escort":
		_freeze_agent()
	_cam = get_viewport().get_camera_2d()
	if _cam:
		_cam_orig_pos = _cam.position
		_cam_orig_zoom = _cam.zoom.x
	match variant:
		"ambulance":
			_setup_ambulance()
			_frame([_from, _van])
		"escort":
			_escort_target = exit_door + exit_out * 40.0
			_frame([_from, _escort_target])
		"ufo":
			_frame([_from], 1.0, 420.0)  # room for the saucer overhead
		_:
			_frame([_from], 1.6)
	set_process(true)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _s(world: Vector2, z: float = 0.0) -> Vector2:
	return Iso.to_screen(world, z)


## One smooth camera move that frames all `pts` (world).
func _frame(pts: Array, zoom_mul: float = 1.0, headroom: float = 220.0) -> void:
	if _cam == null:
		return
	var box := Rect2(_s(pts[0]), Vector2.ZERO)
	for p: Vector2 in pts:
		box = box.expand(_s(p))
	box = box.grow_individual(140, headroom, 140, 80)
	var vp := get_viewport().get_visible_rect().size
	var z := minf(vp.x / box.size.x, vp.y / box.size.y)
	z = clampf(z * zoom_mul, 0.5, 2.0)
	if _cam.has_method("focus_on_smooth"):
		_cam.focus_on_smooth(box.get_center(), z, 0.7)
	elif _cam.has_method("focus_on"):
		_cam.focus_on(box.get_center(), z)


func _restore_camera() -> void:
	if _cam == null:
		return
	_cam.offset = Vector2.ZERO
	if _cam.has_method("focus_on_smooth"):
		_cam.focus_on_smooth(_cam_orig_pos, _cam_orig_zoom, 0.8)
	elif _cam.has_method("focus_on"):
		_cam.focus_on(_cam_orig_pos, _cam_orig_zoom)


func _freeze_agent() -> void:
	if _valid():
		_agent.velocity = Vector2.ZERO
		_agent.set_physics_process(false)


func _valid() -> bool:
	return _agent != null and is_instance_valid(_agent)


## Body squash / tilt / offset in screen space (via Agent.fx_offset).
func _pose(scale_xy: Vector2, rot: float = 0.0, offset: Vector2 = Vector2.ZERO, alpha: float = 1.0) -> void:
	if not _valid() or _agent.view == null:
		return
	_agent.view.scale = scale_xy * Iso.PEOPLE_SCALE
	_agent.view.rotation = rot
	_agent.fx_offset = offset
	_agent.view.modulate.a = alpha


func _hide_agent() -> void:
	if _valid():
		_agent.visible = false
		if _agent.view:
			_agent.view.visible = false


func _finish() -> void:
	if _done:
		return
	_done = true
	_hide_agent()
	_restore_camera()
	finished.emit(kind, agent_id)
	queue_free()


func _puff(at: Vector2, n: int, spread: float = 30.0, col: Color = Color(0.92, 0.92, 0.95)) -> void:
	for i in n:
		var a := randf() * TAU
		_parts.append({
			"p": at + Vector2(cos(a), sin(a) * 0.5) * randf_range(0, spread * 0.4),
			"v": Vector2(cos(a), sin(a) * 0.5 - 0.6) * randf_range(spread * 1.2, spread * 2.6),
			"life": randf_range(0.45, 0.9), "r": randf_range(6.0, 13.0), "c": col,
		})


func _stars(at: Vector2, n: int, col: Color = Color("#fff176")) -> void:
	for i in n:
		var a := randf() * TAU
		_parts.append({
			"p": at, "v": Vector2(cos(a), sin(a)) * randf_range(60, 160),
			"life": randf_range(0.4, 0.8), "r": randf_range(2.5, 4.5), "c": col, "star": true,
		})


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_t += delta
	if kind == "hire":
		_process_hire()
	elif kind == "fire":
		match variant:
			"ambulance": _process_ambulance()
			"stomp": _process_stomp()
			"anvil": _process_anvil()
			"trapdoor": _process_trapdoor()
			"ufo": _process_ufo()
			"escort": _process_escort(delta)
	for p in _parts:
		p.p += p.v * delta
		p.v *= 0.92
		p.life -= delta
	_parts.assign(_parts.filter(func(p: Dictionary) -> bool: return p.life > 0.0))
	if _cam:
		if _shake > 0.0:
			_cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake
			_shake = maxf(0.0, _shake - delta * 50.0)
		else:
			_cam.offset = Vector2.ZERO
	queue_redraw()
	_floor.queue_redraw()


func _process_hire() -> void:
	if _valid() and _agent.view:
		_agent.view.modulate.a = clampf((_t - 0.25) / 0.7, 0.0, 1.0)
	if _t >= 1.7:
		if _valid() and _agent.view:
			_agent.view.modulate.a = 1.0
		finished.emit("hire", agent_id)
		queue_free()


# Stomp: 0–1.0 shadow grows / foot hovers · 1.0 slam · 1.0–2.2 planted ·
# 2.2–2.7 lift · 2.7–3.6 pancake + stars · poof · 4.0 done
func _process_stomp() -> void:
	if _t >= 1.0 and not has_meta("hit"):
		set_meta("hit", true)
		_shake = 16.0
		_puff(_s(_from), 16, 50.0)
	if _t >= 1.0:
		_pose(Vector2(1.8, 0.16), 0.0, Vector2(0, 2))
	if _t >= 3.4 and not has_meta("poof"):
		set_meta("poof", true)
		_puff(_s(_from), 14, 34.0)
		_stars(_s(_from) + Vector2(0, -10), 10)
	if _t >= 3.4:
		_pose(Vector2(1.8, 0.16), 0.0, Vector2(0, 2), clampf(1.0 - (_t - 3.4) / 0.3, 0.0, 1.0))
	if _t >= 4.0:
		_finish()


func _stomp_foot_lift() -> float:
	## Height of the sole above the floor in agent-local units.
	if _t < 0.85:
		return lerpf(260.0, 150.0, _t / 0.85)
	if _t < 1.0:
		return lerpf(150.0, 0.0, (_t - 0.85) / 0.15)
	if _t < 2.2:
		return 0.0
	return lerpf(0.0, 320.0, clampf((_t - 2.2) / 0.5, 0.0, 1.0))


# Anvil: 0–1.3 falling (accelerating) · impact squash · 1.3–2.9 dizzy · poof · 3.4 done
func _anvil_lift() -> float:
	var u := clampf(_t / 1.3, 0.0, 1.0)
	return lerpf(340.0, 0.0, u * u)


func _process_anvil() -> void:
	if _t >= 1.3 and not has_meta("hit"):
		set_meta("hit", true)
		_shake = 12.0
		_puff(_s(_from), 14, 44.0)
	if _t >= 1.3:
		var wob := sin((_t - 1.3) * 18.0) * 0.06 * clampf(1.0 - (_t - 1.3) / 0.6, 0.0, 1.0)
		_pose(Vector2(1.5 + wob, 0.22 - wob))
	if _t >= 2.9 and not has_meta("poof"):
		set_meta("poof", true)
		_puff(_s(_from) + Vector2(0, -30), 22, 50.0)
		_stars(_s(_from) + Vector2(0, -40), 12)
	if _t >= 2.9:
		_pose(Vector2(1.5, 0.22), 0.0, Vector2.ZERO, 0.0)
	if _t >= 3.4:
		_finish()


# Trapdoor: 0–0.5 hatch outline · 0.5–1.1 doors open · 1.1–1.9 wave ·
# 1.9–2.3 drop · 2.4–2.9 doors close + puff · 3.2 done
func _hatch_open() -> float:
	if _t < 0.5:
		return 0.0
	if _t < 1.1:
		return (_t - 0.5) / 0.6
	if _t < 2.4:
		return 1.0
	return clampf(1.0 - (_t - 2.4) / 0.5, 0.0, 1.0)


func _process_trapdoor() -> void:
	if _t < 1.9:
		var hop := absf(sin(_t * 7.0)) * 6.0 if _t > 1.1 else 0.0
		_pose(Vector2.ONE, sin(_t * 9.0) * 0.08 if _t > 1.1 else 0.0, Vector2(0, -hop))
	elif _t < 2.3:
		var u := (_t - 1.9) / 0.4
		_pose(Vector2(1.0 - u * 0.5, 1.0 - u * 0.6), 0.0, Vector2(0, u * u * 60.0), 1.0 - u)
	else:
		_hide_agent()
	if _t >= 2.85 and not has_meta("poof"):
		set_meta("poof", true)
		_puff(_s(_from), 10, 30.0)
	if _t >= 3.2:
		_finish()


# UFO: 0–2.0 descend + beam · 2.0–4.4 rise (spin + shrink) · 4.4–6.0 zip away
func _ufo_state() -> Dictionary:
	var hover := -120.0
	var y := hover
	var x := 0.0
	var beam := 0.0
	if _t < 2.0:
		var u := _t / 2.0
		y = lerpf(-420.0, hover, 1.0 - pow(1.0 - u, 3.0))
		beam = clampf((_t - 1.2) / 0.6, 0.0, 1.0)
	elif _t < 4.4:
		beam = 1.0
	else:
		var u := clampf((_t - 4.4) / 1.6, 0.0, 1.0)
		x = 420.0 * u * u
		y = hover - 260.0 * u * u
		beam = clampf(1.0 - u * 3.0, 0.0, 1.0)
	if _t < 4.4:
		y += sin(_t * 3.4) * 5.0
	return {"x": x, "y": y, "beam": beam}


func _process_ufo() -> void:
	if _t >= 2.0 and _t < 4.4:
		var u := (_t - 2.0) / 2.4
		_pose(Vector2.ONE * lerpf(1.0, 0.2, u * u), u * TAU * 1.5, Vector2(0, lerpf(0.0, -200.0, u)), clampf(1.0 - (u - 0.85) / 0.15, 0.0, 1.0))
		if randf() < 0.4:
			_stars(_s(_from) + Vector2(randf_range(-30, 30), lerpf(0.0, -200.0, u)), 1, Color(0.6, 1.0, 0.8))
	elif _t >= 4.4:
		if not has_meta("gone"):
			set_meta("gone", true)
			_hide_agent()
	if _t >= 6.0:
		_finish()


# Ambulance: 0–1.2 collapse · 0.8–2.8 van drives in · 2.8–5.3 medics walk in ·
# 5.3–6.1 load · 6.1–8.6 carry out · 8.6–9.1 into the van · 9.1–10.6 drive off
const AMB_IN := [0.8, 2.8]
const AMB_WALK_IN := [2.8, 5.3]
const AMB_LOAD := [5.3, 6.1]
const AMB_WALK_OUT := [6.1, 8.6]
const AMB_BOARD := [8.6, 9.1]
const AMB_OFF := [9.1, 10.6]


func _setup_ambulance() -> void:
	var out := exit_out.normalized()
	var side := Vector2(-out.y, out.x)
	if side.x + side.y < 0.0:
		side = -side  # park on the side nearer the viewer
	_van = exit_door + out * 110.0 + side * 70.0
	_van_along = side if absf(side.x) > absf(side.y) else Vector2(1, 0)
	_van_pos = _van - _van_along * 520.0
	# Walking route: van tail → just outside the door → through it → agent.
	var pts := PackedVector2Array([_van, exit_door + out * 34.0, exit_door - out * 30.0])
	if _valid():
		var map: RID = _agent.nav_agent.get_navigation_map()
		var path := NavigationServer2D.map_get_path(map, exit_door - out * 30.0, _from, true)
		for i in range(1, path.size()):
			pts.append(path[i])
	pts.append(_from + Vector2(0, 14))
	_route = pts
	_route_len = 0.0
	for i in range(1, pts.size()):
		_route_len += pts[i - 1].distance_to(pts[i])


## Point `u` (0 = van, 1 = agent) along the medics' route, plus its direction.
func _route_at(u: float) -> Array:
	var d := clampf(u, 0.0, 1.0) * _route_len
	for i in range(1, _route.size()):
		var seg := _route[i - 1].distance_to(_route[i])
		if d <= seg or i == _route.size() - 1:
			var dir := (_route[i] - _route[i - 1]).normalized()
			return [_route[i - 1] + dir * minf(d, seg), dir]
		d -= seg
	return [_route[_route.size() - 1], Vector2.RIGHT]


func _span(t: float, r: Array) -> float:
	return clampf((t - float(r[0])) / (float(r[1]) - float(r[0])), 0.0, 1.0)


func _process_ambulance() -> void:
	var c := _span(_t, [0.0, 1.2])
	if _t < AMB_LOAD[0]:
		_pose(Vector2(1.0, lerpf(1.0, 0.95, c)), lerpf(0.0, PI * 0.5, c * c), Vector2(0, c * 10.0))
		if _t >= 1.2 and not has_meta("bonk"):
			set_meta("bonk", true)
			_stars(_s(_from) + Vector2(0, -20), 8)
	elif _t < AMB_LOAD[1]:
		_pose(Vector2.ONE, PI * 0.5, Vector2(0, 10), 1.0 - _span(_t, AMB_LOAD))
	else:
		_hide_agent()
	if _t < AMB_IN[1]:
		var u := _span(_t, AMB_IN)
		_van_pos = (_van - _van_along * 520.0).lerp(_van, 1.0 - pow(1.0 - u, 3.0))
	elif _t >= AMB_OFF[0]:
		var u := _span(_t, AMB_OFF)
		_van_pos = _van.lerp(_van + _van_along * 620.0, u * u)
	else:
		_van_pos = _van
	if _t >= AMB_OFF[1]:
		_finish()


## 0 = at the van, 1 = at the agent; -1 when the medics are not out.
func _medic_u() -> float:
	if _t < AMB_WALK_IN[0] or _t >= AMB_BOARD[1]:
		return -1.0
	if _t < AMB_WALK_IN[1]:
		return _span(_t, AMB_WALK_IN)
	if _t < AMB_LOAD[1]:
		return 1.0
	if _t < AMB_WALK_OUT[1]:
		return 1.0 - _span(_t, AMB_WALK_OUT)
	return 0.0


# Escort: guard appears, agent walks out with a box, both fade past the door.
func _process_escort(delta: float) -> void:
	if not _valid():
		_finish()
		return
	if _t >= 0.6 and not has_meta("walking"):
		set_meta("walking", true)
		_agent.go_to_position(_escort_target)
	_trail.push_front(_agent.global_position)
	if _trail.size() > 40:
		_trail.pop_back()
	if _cam and _t > 0.8:
		_cam.position = _cam.position.lerp(_s(_agent.global_position), clampf(delta * 2.5, 0.0, 1.0))
	var arrived: bool = has_meta("walking") and _agent.global_position.distance_to(_escort_target) < 14.0
	if (arrived or _t > 14.0) and not has_meta("leave_t"):
		set_meta("leave_t", _t)
	if has_meta("leave_t"):
		var u := clampf((_t - float(get_meta("leave_t"))) / 0.7, 0.0, 1.0)
		_agent.view.modulate.a = 1.0 - u
		if u >= 1.0:
			_finish()


func _escort_guard_pos() -> Vector2:
	if _trail.is_empty():
		return _from + Vector2(28, 10)
	var g: Vector2 = _trail[_trail.size() - 1]
	return g + Vector2(16, 12) if g.distance_to(_trail[0]) < 4.0 else g


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
func _draw() -> void:
	if kind == "hire":
		_draw_hire()
	elif kind == "fire":
		match variant:
			"ambulance": _draw_ambulance()
			"stomp": _draw_stomp()
			"anvil": _draw_anvil()
			"trapdoor": _draw_trapdoor_front()
			"ufo": _draw_ufo()
			"escort": _draw_escort()
	draw_set_transform_matrix(Transform2D.IDENTITY)
	for p in _parts:
		var a := clampf(p.life * 1.6, 0.0, 1.0)
		var col: Color = p.c
		if p.get("star", false):
			_star(p.p, p.r * 1.6, Color(col, a))
		else:
			draw_circle(p.p, p.r, Color(col, a * 0.85))


## Floor marks under people: shadows, dust rings, the trapdoor hatch.
func _draw_floor_layer() -> void:
	if kind != "fire":
		return
	var at := _s(_from)
	match variant:
		"stomp":
			var lift := _stomp_foot_lift()
			var k := clampf(1.0 - lift / 320.0, 0.15, 1.0)
			_floor_ellipse(at, Vector2(70, 26) * k, Color(0, 0, 0, 0.35 * k))
			_dust_ring(at, _t - 1.0)
		"anvil":
			var k := clampf(1.0 - _anvil_lift() / 340.0, 0.1, 1.0)
			_floor_ellipse(at, Vector2(56, 22) * k, Color(0, 0, 0, 0.4 * k))
			_dust_ring(at, _t - 1.3)
		"trapdoor":
			_draw_hatch(at)
		"ufo":
			var st := _ufo_state()
			_floor_ellipse(at + Vector2(st.x, 0) * 0.3, Vector2(90, 28), Color(0.2, 1.0, 0.6, 0.18 * st.beam))
		"ambulance":
			if _van_pos.distance_to(_van) < 700.0:
				_floor_ellipse(_s(_van_pos) + Vector2(0, 6), Vector2(120, 34), Color(0, 0, 0, 0.18))
				var flash := fmod(_t, 0.4) < 0.2
				_floor_ellipse(_s(_van_pos), Vector2(170, 60), Color(1, 0.2, 0.2, 0.08) if flash else Color(0.2, 0.4, 1, 0.08))


func _floor_ellipse(c: Vector2, r: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 28:
		var a := TAU * i / 28.0
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	_floor.draw_colored_polygon(pts, col)


func _dust_ring(at: Vector2, since: float) -> void:
	if since < 0.0 or since > 0.6:
		return
	var u := since / 0.6
	var r := Vector2(40, 16) + Vector2(120, 46) * u
	var pts := PackedVector2Array()
	for i in 33:
		var a := TAU * i / 32.0
		pts.append(at + Vector2(cos(a) * r.x, sin(a) * r.y))
	_floor.draw_polyline(pts, Color(1, 1, 1, 0.6 * (1.0 - u)), 6.0 * (1.0 - u) + 1.0, true)


func _ellipse(c: Vector2, r: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var a := TAU * i / 24.0
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	draw_colored_polygon(pts, col)


func _star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + TAU * i / 10.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	draw_colored_polygon(pts, col)


## Draw in agent-local units around screen point `at` (feet).
func _local(at: Vector2, flip: float = 1.0) -> void:
	draw_set_transform(at, 0.0, Vector2(flip, 1.0) * Iso.PEOPLE_SCALE)


func _dizzy(at: Vector2, height: float) -> void:
	_local(at)
	for i in 3:
		var a := _t * 5.0 + TAU * i / 3.0
		_star(Vector2(cos(a) * 18.0, -height + sin(a) * 6.0), 4.5, Color("#fff176"))
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_hire() -> void:
	var at := _s(_from)
	var a := clampf(_t * 2.0, 0.0, 1.0) * clampf(1.6 - _t, 0.0, 1.0)
	_local(at)
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -260), Vector2(8, -260), Vector2(30, 6), Vector2(-30, 6)]), Color(1.0, 0.95, 0.55, a * 0.45))
	draw_colored_polygon(PackedVector2Array([Vector2(-3, -260), Vector2(3, -260), Vector2(14, 4), Vector2(-14, 4)]), Color(1.0, 1.0, 0.85, a * 0.5))
	_ellipse(Vector2(0, 0), Vector2(30, 10), Color(1, 1, 0.7, a * 0.4))
	draw_set_transform_matrix(Transform2D.IDENTITY)


## Chibi helper figure (medic / guard / janitor) in agent-local units.
func _person(feet: Vector2, coat: Color, hat: String, walk: float, face: float, arms_forward: bool = false) -> void:
	_local(feet, -1.0 if face < 0.0 else 1.0)
	_ellipse(Vector2.ZERO, Vector2(15, 6), Color(0, 0, 0, 0.22))
	var sw := sin(walk) * 5.0
	# Legs
	for lx: float in [-5.0, 5.0]:
		var foot := Vector2(lx + (sw if lx < 0.0 else -sw), -1)
		draw_line(Vector2(lx, -14), foot, OUTLINE, 8.0)
		draw_line(Vector2(lx, -14), foot, Color("#37474f"), 5.0)
		draw_circle(foot + Vector2(1.5, 0), 3.5, OUTLINE)
	# Torso
	var torso: PackedVector2Array = OfficeScript.rounded_rect_points(Rect2(-12, -36, 24, 24), 6.0)
	draw_colored_polygon(torso, OUTLINE)
	draw_colored_polygon(OfficeScript.rounded_rect_points(Rect2(-10.5, -34.5, 21, 21), 5.0), coat)
	if hat == "medic":
		draw_rect(Rect2(-2, -30, 4, 12), Color("#e53935"))
		draw_rect(Rect2(-6, -26, 12, 4), Color("#e53935"))
	elif hat == "guard":
		_star(Vector2(5, -28), 3.5, Color("#ffd54f"))
	# Arms
	var hand := Vector2(13, -20) if arms_forward else Vector2(10 - sw * 0.4, -14)
	draw_line(Vector2(7, -31), hand, OUTLINE, 7.0)
	draw_line(Vector2(7, -31), hand, coat.darkened(0.12), 4.5)
	draw_circle(hand, 3.5, SKIN)
	# Head
	draw_circle(Vector2(0, -46), 15.5, OUTLINE)
	draw_circle(Vector2(0, -46), 14.0, SKIN)
	draw_circle(Vector2(4, -47), 2.0, OUTLINE)
	draw_circle(Vector2(10, -47), 2.0, OUTLINE)
	draw_arc(Vector2(7, -42), 3.0, 0.2, PI - 0.2, 6, OUTLINE, 1.5)
	match hat:
		"medic":
			draw_colored_polygon(PackedVector2Array([Vector2(-14, -52), Vector2(14, -52), Vector2(12, -62), Vector2(-12, -62)]), Color.WHITE)
			draw_rect(Rect2(-2, -61, 4, 8), Color("#e53935"))
			draw_rect(Rect2(-5, -58, 10, 3), Color("#e53935"))
		"guard":
			draw_colored_polygon(PackedVector2Array([Vector2(-15, -53), Vector2(18, -53), Vector2(13, -64), Vector2(-13, -64)]), Color("#263238"))
			draw_rect(Rect2(2, -55, 18, 3), Color("#263238"))
		_:
			draw_arc(Vector2(0, -46), 14.0, PI * 1.05, PI * 1.95, 12, Color("#5d4037"), 6.0)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_stomp() -> void:
	var at := _s(_from)
	if _t >= 2.4 and _t < 3.4:
		_dizzy(at, 20.0)
	var lift := _stomp_foot_lift()
	if lift > 300.0:
		return
	_local(at + Vector2(0, -lift * Iso.PEOPLE_SCALE))
	# Big cartoon sneaker, toe to the right: sole, red upper, white toe cap, laces.
	var squash := 1.0 if _t < 1.0 or _t > 1.12 else 0.85
	draw_set_transform(at + Vector2(0, -lift * Iso.PEOPLE_SCALE), 0.0, Vector2(1.0 / squash, squash) * Iso.PEOPLE_SCALE)
	draw_colored_polygon(OfficeScript.rounded_rect_points(Rect2(-60, -14, 118, 16), 7.0), OUTLINE)
	draw_colored_polygon(OfficeScript.rounded_rect_points(Rect2(-58, -12, 114, 12), 6.0), Color("#fafafa"))
	var upper := PackedVector2Array([Vector2(-56, -12), Vector2(-54, -64), Vector2(-26, -70), Vector2(-14, -40), Vector2(30, -34), Vector2(54, -22), Vector2(56, -12)])
	draw_colored_polygon(upper, OUTLINE)
	var inner := PackedVector2Array([Vector2(-53, -13), Vector2(-51, -61), Vector2(-28, -66), Vector2(-16, -37), Vector2(29, -31), Vector2(51, -21), Vector2(53, -13)])
	draw_colored_polygon(inner, Color("#e53935"))
	draw_colored_polygon(PackedVector2Array([Vector2(26, -31), Vector2(51, -21), Vector2(53, -13), Vector2(30, -13)]), Color("#fafafa"))
	for i in 3:
		draw_line(Vector2(-14 + i * 11, -38 + i * 1.5), Vector2(-6 + i * 11, -30 + i * 1.5), Color.WHITE, 3.0)
	draw_line(Vector2(-58, -6), Vector2(56, -6), Color("#bdbdbd"), 2.0)
	# Leg going up off-screen
	draw_colored_polygon(PackedVector2Array([Vector2(-54, -64), Vector2(-26, -70), Vector2(-22, -400), Vector2(-56, -400)]), Color("#1e88e5"))
	draw_set_transform_matrix(Transform2D.IDENTITY)
	# Motion lines while falling
	if _t > 0.85 and _t < 1.0:
		for i in 3:
			var x := at.x + (-40 + i * 40) * Iso.PEOPLE_SCALE
			draw_line(Vector2(x, at.y - 160 * Iso.PEOPLE_SCALE), Vector2(x, at.y - 90 * Iso.PEOPLE_SCALE), Color(1, 1, 1, 0.7), 3.0)
	if _t >= 1.0 and _t < 1.5:
		_local(at)
		_star(Vector2(-70, -30), 14 * (1.5 - _t) * 2.0, Color("#ffeb3b"))
		_star(Vector2(70, -40), 12 * (1.5 - _t) * 2.0, Color("#ffeb3b"))
		draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_anvil() -> void:
	var at := _s(_from)
	var lift := _anvil_lift()
	if _t >= 2.9:
		return
	var hit := _t >= 1.3
	var y := -lift
	if hit:
		y = -12.0  # resting on the squashed agent
		_dizzy(at, 52.0)
	_local(at + Vector2(0, y * Iso.PEOPLE_SCALE))
	# Whistle lines above while falling
	if not hit and _t > 0.3:
		for i in 3:
			draw_line(Vector2(-18 + i * 18, -70), Vector2(-18 + i * 18, -110), Color(1, 1, 1, 0.6), 2.5)
	# Classic anvil: base, waist, face with horn.
	var body := PackedVector2Array([
		Vector2(-26, 0), Vector2(26, 0), Vector2(20, -8), Vector2(12, -10), Vector2(12, -22),
		Vector2(30, -26), Vector2(34, -36), Vector2(-20, -36), Vector2(-44, -32), Vector2(-24, -26), Vector2(-12, -22), Vector2(-12, -10), Vector2(-20, -8),
	])
	var ol := PackedVector2Array()
	for p in body:
		ol.append(p * 1.08 + Vector2(0, 1.4))
	draw_colored_polygon(ol, OUTLINE)
	draw_colored_polygon(body, Color("#546e7a"))
	draw_colored_polygon(PackedVector2Array([Vector2(-20, -36), Vector2(34, -36), Vector2(32, -32), Vector2(-24, -32)]), Color("#90a4ae"))
	draw_line(Vector2(-40, -31), Vector2(-22, -33), Color("#b0bec5"), 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(-11, -12), "ACME", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color("#eceff1"))
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_hatch(at: Vector2) -> void:
	if _t > 3.0:
		return
	var appear := clampf(_t / 0.5, 0.0, 1.0)
	var half := 26.0 * appear
	var w := _from
	var corners := [w + Vector2(-half, -half), w + Vector2(half, -half), w + Vector2(half, half), w + Vector2(-half, half)]
	var frame := PackedVector2Array(corners.map(func(p: Vector2) -> Vector2: return _s(p)))
	_floor.draw_colored_polygon(frame, Color("#4e342e"))
	var inner := PackedVector2Array(corners.map(func(p: Vector2) -> Vector2: return _s(w + (p - w) * 0.84)))
	_floor.draw_colored_polygon(inner, Color("#120d0a"))
	# Two doors hinged on the west and east edges, folding down into the hole.
	var o := _hatch_open()
	var hw := half * 0.84
	for side: float in [-1.0, 1.0]:
		var hinge_x := w.x + side * hw
		var tip_x := hinge_x - side * hw * (1.0 - o)
		var door := PackedVector2Array([
			_s(Vector2(hinge_x, w.y - hw)), _s(Vector2(tip_x, w.y - hw)),
			_s(Vector2(tip_x, w.y + hw)), _s(Vector2(hinge_x, w.y + hw)),
		])
		if absf(tip_x - hinge_x) > 0.5:
			_floor.draw_colored_polygon(door, Color("#8d6e63"))
			_floor.draw_polyline(door, Color("#5d4037"), 1.5)


func _draw_trapdoor_front() -> void:
	var at := _s(_from)
	if _t > 0.6 and _t < 1.9:
		_local(at)
		var bob := sin(_t * 8.0) * 3.0
		draw_colored_polygon(OfficeScript.rounded_rect_points(Rect2(14, -96 + bob, 26, 26), 6.0), Color.WHITE)
		draw_string(ThemeDB.fallback_font, Vector2(22, -77 + bob), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("#e53935"))
		draw_set_transform_matrix(Transform2D.IDENTITY)
	if _t > 1.1 and _t < 1.9:
		_local(at)
		draw_string(ThemeDB.fallback_font, Vector2(-44, -84), "bye!", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
		draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_ufo() -> void:
	var st := _ufo_state()
	var at := _s(_from)
	var c := at + Vector2(st.x, st.y) * Iso.PEOPLE_SCALE
	var k := Iso.PEOPLE_SCALE
	var beam: float = st.beam
	if beam > 0.0:
		var top := c + Vector2(0, 14 * k)
		for layer in 3:
			var wt := (18.0 - layer * 5.0) * k
			var wb := (60.0 - layer * 16.0) * k
			draw_colored_polygon(PackedVector2Array([top + Vector2(-wt, 0), top + Vector2(wt, 0), at + Vector2(wb, 6), at + Vector2(-wb, 6)]),
				Color(0.45 + layer * 0.15, 1.0, 0.75 + layer * 0.08, beam * (0.16 + layer * 0.08)))
	_ellipse(c + Vector2(0, -8 * k), Vector2(20, 18) * k, Color(0.6, 0.95, 0.8, 0.6))
	_ellipse(c + Vector2(-6, -14) * k, Vector2(6, 4) * k, Color(1, 1, 1, 0.6))
	_ellipse(c + Vector2(0, 4) * k, Vector2(54, 15) * k, OUTLINE)
	_ellipse(c + Vector2(0, 2) * k, Vector2(52, 13) * k, Color("#9ccc65"))
	_ellipse(c + Vector2(0, 8) * k, Vector2(34, 7) * k, Color("#558b2f"))
	_ellipse(c, Vector2(52, 7) * k, Color("#c5e1a5"))
	for i in 9:
		var a := PI * 0.08 + i * (PI * 0.84 / 8.0)
		var lit := (int(_t * 8.0) + i) % 2 == 0
		draw_circle(c + Vector2(cos(a) * 44 * k, (4 + sin(a) * 8) * k), 3.0 * k, Color("#fff176") if lit else Color("#80deea"))


func _draw_ambulance() -> void:
	# Medics + stretcher
	var u := _medic_u()
	if u >= 0.0:
		var r := _route_at(u)
		var mid: Vector2 = r[0]
		var dir: Vector2 = r[1]
		var going_in := _t < AMB_LOAD[0]
		var face := Iso.screen_dir(dir if going_in else -dir).x
		var front := mid + dir * 22.0 * (1.0 if going_in else -1.0)
		var back := mid - dir * 22.0 * (1.0 if going_in else -1.0)
		var walk := _t * 9.0 if (_t < AMB_WALK_IN[1] or (_t >= AMB_WALK_OUT[0] and _t < AMB_WALK_OUT[1])) else 0.0
		var first := back if _s(back).y < _s(front).y else front
		var second := front if first == back else back
		_person(_s(first), Color.WHITE, "medic", walk, face, true)
		# Stretcher between the medics' hands.
		var a := _s(first) + Vector2(0, -20 * Iso.PEOPLE_SCALE)
		var b := _s(second) + Vector2(0, -20 * Iso.PEOPLE_SCALE)
		draw_line(a, b, OUTLINE, 9.0)
		draw_line(a, b, Color("#eceff1"), 6.0)
		var loaded := _t >= AMB_LOAD[1] - 0.2 and _t < AMB_BOARD[0] + 0.2
		if loaded:
			var m := (a + b) * 0.5
			draw_line(m - (b - a) * 0.3 + Vector2(0, -5), m + (b - a) * 0.3 + Vector2(0, -5), Color("#90caf9"), 10.0)
			draw_circle(m + (b - a) * 0.36 + Vector2(0, -7), 7.0, SKIN)
		_person(_s(second), Color.WHITE, "medic", walk + PI, face, true)
	# Van (drawn as an isometric box with a cab).
	if _van_pos.distance_to(_van) < 700.0:
		_draw_van(_van_pos)


func _wq(pts: Array, z: Array, col: Color) -> void:
	var out := PackedVector2Array()
	for i in pts.size():
		out.append(_s(pts[i], z[i]))
	draw_colored_polygon(out, col)


func _draw_van(p: Vector2) -> void:
	# Footprint along world x (screen down-right); cab at the +x end.
	var L := 88.0
	var W := 40.0
	var H := 44.0
	var x0 := p.x - L * 0.5
	var x1 := p.x + L * 0.5
	var y0 := p.y - W * 0.5
	var y1 := p.y + W * 0.5
	var cab := x1 - 24.0
	var body := Color("#fafafa")
	# Box (rear part): south face, east face of cab, tops.
	_wq([Vector2(x0, y1), Vector2(cab, y1), Vector2(cab, y1), Vector2(x0, y1)], [4, 4, H, H], body.darkened(0.08))
	_wq([Vector2(x0, y0), Vector2(cab, y0), Vector2(cab, y1), Vector2(x0, y1)], [H, H, H, H], body)
	# Cab: lower, with windshield on the east face.
	var ch := H * 0.72
	_wq([Vector2(cab, y1), Vector2(x1, y1), Vector2(x1, y1), Vector2(cab, y1)], [4, 4, ch, ch], body.darkened(0.1))
	_wq([Vector2(x1, y0), Vector2(x1, y1), Vector2(x1, y1), Vector2(x1, y0)], [4, 4, ch, ch], body.darkened(0.22))
	_wq([Vector2(x1, y0 + 4), Vector2(x1, y1 - 4), Vector2(x1, y1 - 4), Vector2(x1, y0 + 4)], [ch * 0.55, ch * 0.55, ch - 3, ch - 3], Color("#4fc3f7"))
	_wq([Vector2(cab, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(cab, y1)], [ch, ch, ch, ch], body.darkened(0.04))
	_wq([Vector2(cab, y0), Vector2(cab, y1), Vector2(cab, y1), Vector2(cab, y0)], [ch, ch, H, H], body.darkened(0.15))
	# Side window on the cab, red stripe and cross on the box side.
	_wq([Vector2(cab + 4, y1), Vector2(x1 - 4, y1), Vector2(x1 - 4, y1), Vector2(cab + 4, y1)], [ch * 0.55, ch * 0.55, ch - 4, ch - 4], Color("#4fc3f7"))
	_wq([Vector2(x0, y1), Vector2(x1, y1), Vector2(x1, y1), Vector2(x0, y1)], [14, 14, 20, 20], Color("#e53935"))
	var cx := (x0 + cab) * 0.5
	_wq([Vector2(cx - 4, y1), Vector2(cx + 4, y1), Vector2(cx + 4, y1), Vector2(cx - 4, y1)], [22, 22, 40, 40], Color("#e53935"))
	_wq([Vector2(cx - 10, y1), Vector2(cx + 10, y1), Vector2(cx + 10, y1), Vector2(cx - 10, y1)], [28, 28, 34, 34], Color("#e53935"))
	# Wheels
	for wx: float in [x0 + 16.0, x1 - 14.0]:
		var wc := _s(Vector2(wx, y1), 6.0)
		_ellipse(wc, Vector2(9, 9) * Iso.SCALE, OUTLINE)
		_ellipse(wc, Vector2(4, 4) * Iso.SCALE, Color("#90a4ae"))
	# Light bar
	var flash := fmod(_t, 0.4) < 0.2
	var lb := _s(Vector2(cab - 6, p.y), H + 3)
	_ellipse(lb + Vector2(-8, 0), Vector2(6, 4) * Iso.SCALE, Color("#e53935") if flash else Color("#7f1d1d"))
	_ellipse(lb + Vector2(8, 4), Vector2(6, 4) * Iso.SCALE, Color("#1e3a8a") if flash else Color("#2196f3"))


func _draw_escort() -> void:
	if not _valid():
		return
	var alpha := 1.0
	if has_meta("leave_t"):
		alpha = 1.0 - clampf((_t - float(get_meta("leave_t"))) / 0.7, 0.0, 1.0)
	var appear := clampf(_t / 0.5, 0.0, 1.0)
	modulate.a = alpha * appear
	var ap: Vector2 = _s(_agent.global_position) + _agent.fx_offset
	var moving: bool = _agent.velocity.length() > 5.0
	var g := _escort_guard_pos()
	var face := Iso.screen_dir(_agent.global_position - g).x if moving else -1.0
	_person(_s(g), Color("#37474f"), "guard", _t * 9.0 if moving else 0.0, face)
	# Box of desk stuff held in front of the agent.
	_local(ap)
	draw_colored_polygon(OfficeScript.rounded_rect_points(Rect2(-15, -36, 30, 20), 2.0), OUTLINE)
	draw_rect(Rect2(-13.5, -34.5, 27, 17), Color("#bcaaa4"))
	draw_rect(Rect2(-13.5, -34.5, 27, 4), Color("#a1887f"))
	draw_rect(Rect2(-9, -44, 7, 10), Color("#42a5f5"))   # mug
	draw_rect(Rect2(1, -41, 9, 7), Color("#fff176"))     # sticky notes
	draw_circle(Vector2(8, -46), 5.0, Color("#43a047"))  # tiny plant
	draw_set_transform_matrix(Transform2D.IDENTITY)
