## Cartoon hire / fire pageantry for Agent Office.
## Hire: beam of light from above, sparkles, sprite fades in at the desk.
## Fire: playful pixel-art exit (never gory); camera follows the action.
## Variants:
##   ambulance — collapse, ambulance + flashing lights, medics + stretcher via doors (~8–12s)
##   stomp     — giant cartoon foot stomps flat + screen shake, janitor mops
##   anvil     — Acme anvil drops, puff of smoke, desk cleared
##   trapdoor  — trapdoor opens, wave goodbye, fall through
##   ufo       — UFO descends, beam-up (rotate+shrink), zip away + sparkle (~6–8s)
##   escort    — security guard walks them out with a box of desk stuff
## Preview: Shift+F cycles; /fire-preview <variant> or variant= on PREVIEW_HIRE_FIRE.
## Alias: "medics" → "ambulance".
extends Node2D

const Iso := preload("res://Iso.gd")

signal finished(kind: String, agent_id: String)

const FIRE_VARIANTS := ["ambulance", "stomp", "anvil", "trapdoor", "ufo", "escort"]
const FIRE_ALIASES := {"medics": "ambulance"}

var kind := ""           ## "hire" | "fire"
var variant := ""        ## fire variant id
var agent_id := ""
var _agent: Node = null
var _t := 0.0
var _phase := 0
var _medics: Array[Node2D] = []
var _carry_from := Vector2.ZERO
var _carry_to := Vector2.ZERO
var _beam_alpha := 0.0
var _sparkles: Array[Dictionary] = []
var _shake_amp := 0.0
var _cam: Node = null
var _cam_orig := Vector2.ZERO
var _cam_orig_pos := Vector2.ZERO
var _cam_orig_zoom := Vector2.ONE
var _did_cam_focus := false
var _flat_alpha := 0.0
var _mop_x := -40.0
var _anvil_y := -180.0
var _ufo_y := -160.0
var _trap_open := 0.0
var _wave_hand := 0.0
var _escort_box := Vector2.ZERO
var _puff: Array[Dictionary] = []
var _forced_variant := ""
var _from_world := Vector2.ZERO
var _to_world := Vector2.ZERO
# Ambulance sequence state (world space for path; screen for draw).
var _amb_world := Vector2.ZERO
var _amb_arrive := Vector2.ZERO
var _amb_depart := Vector2.ZERO
var _amb_side := 1.0
var _amb_flash := 0.0
var _medic_u := 0.0  # 0 at ambulance → 1 at agent
var _stretcher_loaded := false
var _body_on_stretcher := false
var _siren_bob := 0.0
var _ufo_x := 0.0
var _ufo_zip := 0.0
var _ufo_bob := 0.0
var _agent_float_y := 0.0
var _agent_spin := 0.0
var _agent_shrink := 1.0
var _cam_follow := Vector2.ZERO

static var _preview_cycle := 0


static func next_preview_variant() -> String:
	var v: String = FIRE_VARIANTS[_preview_cycle % FIRE_VARIANTS.size()]
	_preview_cycle = (_preview_cycle + 1) % FIRE_VARIANTS.size()
	return v


func play_hire(agent: Node, desk_pos: Vector2) -> void:
	kind = "hire"
	agent_id = str(agent.agent_id)
	_agent = agent
	# desk_pos is world; FX lives under agents_root (screen / iso space).
	_from_world = desk_pos
	global_position = Iso.to_screen(desk_pos)
	if agent.view:
		agent.view.modulate.a = 0.0
	_beam_alpha = 0.0
	for i in 18:
		_sparkles.append({
			"p": Vector2(randf_range(-22, 22), randf_range(-70, -10)),
			"v": Vector2(randf_range(-12, 12), randf_range(10, 40)),
			"life": randf_range(0.4, 1.1),
			"c": Color(1.0, randf_range(0.85, 1.0), randf_range(0.4, 0.9), 1.0),
		})
	set_process(true)
	queue_redraw()


func play_fire(agent: Node, entrance_pos: Vector2, forced: String = "") -> void:
	kind = "fire"
	agent_id = str(agent.agent_id)
	_agent = agent
	# Keep world coords for body motion; project FX onto agents_root screen space.
	_from_world = agent.global_position
	_to_world = entrance_pos
	_carry_from = Iso.to_screen(_from_world)
	_carry_to = Iso.to_screen(_to_world)
	global_position = _carry_from
	_forced_variant = forced.strip_edges().to_lower()
	if _forced_variant in FIRE_ALIASES:
		_forced_variant = FIRE_ALIASES[_forced_variant]
	if _forced_variant != "" and _forced_variant in FIRE_VARIANTS:
		variant = _forced_variant
	else:
		variant = FIRE_VARIANTS[randi() % FIRE_VARIANTS.size()]
	_phase = 0
	_t = 0.0
	_cam = get_viewport().get_camera_2d()
	if _cam:
		_cam_orig = _cam.offset
		_cam_orig_pos = _cam.position
		_cam_orig_zoom = _cam.zoom
		_did_cam_focus = true
		var focus := Iso.to_screen(_from_world)
		if _cam.has_method("focus_on"):
			var z := clampf(_cam.zoom.x * 1.25, 0.45, 2.2)
			_cam.focus_on(focus, z)
		else:
			_cam.position = focus
	match variant:
		"ambulance":
			_setup_ambulance()
		"stomp":
			_flat_alpha = 0.0
			_mop_x = -50.0
		"anvil":
			_anvil_y = -200.0
		"trapdoor":
			_trap_open = 0.0
			_wave_hand = 0.0
		"ufo":
			_ufo_y = -280.0
			_ufo_x = 0.0
			_ufo_bob = 0.0
			_beam_alpha = 0.0
		"escort":
			_escort_box = Vector2(18, -8)
			if agent.view:
				agent.view.modulate = Color(1, 1, 1, 1)
	set_process(true)
	queue_redraw()


func _setup_ambulance() -> void:
	# Park at building entrance (to_world); approach from off-screen along that edge.
	_amb_arrive = _to_world
	var outward := (_to_world - _from_world)
	if outward.length() < 8.0:
		outward = Vector2(0, 120)
	outward = outward.normalized() * 160.0
	_amb_depart = _to_world + outward
	_amb_world = _amb_depart
	_amb_side = 1.0 if outward.x >= 0.0 else -1.0
	_amb_flash = 0.0
	_medic_u = 0.0
	_stretcher_loaded = false
	_body_on_stretcher = false
	_siren_bob = 0.0
	for i in 2:
		var m := Node2D.new()
		m.set_meta("medic", true)
		m.set_meta("side", -1 if i == 0 else 1)
		add_child(m)
		_medics.append(m)


func _cam_track(world: Vector2) -> void:
	_cam_follow = Iso.to_screen(world)
	global_position = _cam_follow
	if _cam and _cam.has_method("focus_on"):
		var z := clampf(_cam_orig_zoom.x * 1.3, 0.5, 2.4)
		_cam.focus_on(_cam_follow, z)


func _process_ambulance(delta: float) -> void:
	# Phases (~10–11s): 0 collapse 2.2 · 1 drive-in 2.0 · 2 medics walk 2.0 ·
	# 3 load 1.0 · 4 carry back 2.0 · 5 load van 0.8 · 6 drive-off 1.6
	_amb_flash += delta
	_siren_bob += delta * 8.0
	if _phase == 0:
		_cam_track(_from_world)
		if _agent and is_instance_valid(_agent) and _agent.view:
			var u := clampf(_t / 2.2, 0.0, 1.0)
			# Slow collapse to the floor where they stand.
			_agent.view.rotation = lerp_angle(0.0, PI / 2.0, u * u)
			_agent.view.scale.y = lerpf(1.0, 0.42, u)
			_agent.view.position.y = lerpf(0.0, 10.0, u)
			_agent.view.modulate = Color(1, 1, 1, lerpf(1.0, 0.92, u))
		if _t >= 2.2:
			_phase = 1
			_t = 0.0
	elif _phase == 1:
		var u := clampf(_t / 2.0, 0.0, 1.0)
		# Ease-in to the entrance / building edge.
		var ease := 1.0 - pow(1.0 - u, 2.0)
		_amb_world = _amb_depart.lerp(_amb_arrive, ease)
		_cam_track(_amb_world.lerp(_from_world, 0.35))
		if u >= 1.0:
			_amb_world = _amb_arrive
			_phase = 2
			_t = 0.0
			_medic_u = 0.0
	elif _phase == 2:
		# Medics + empty stretcher walk entrance → agent (through door corridor).
		_medic_u = clampf(_t / 2.0, 0.0, 1.0)
		var path_w := _amb_arrive.lerp(_from_world, _medic_u)
		_cam_track(path_w)
		if _medic_u >= 1.0:
			_phase = 3
			_t = 0.0
	elif _phase == 3:
		# Load agent onto stretcher.
		_cam_track(_from_world)
		if _agent and is_instance_valid(_agent) and _agent.view:
			_agent.view.modulate.a = clampf(1.0 - _t / 0.7, 0.0, 1.0)
		if _t >= 1.0:
			_hide_agent()
			_body_on_stretcher = true
			_stretcher_loaded = true
			_phase = 4
			_t = 0.0
			_medic_u = 1.0
	elif _phase == 4:
		# Carry stretcher back to ambulance along same path.
		_medic_u = clampf(1.0 - _t / 2.0, 0.0, 1.0)
		var path_w := _amb_arrive.lerp(_from_world, _medic_u)
		_cam_track(path_w)
		if _t >= 2.0:
			_medic_u = 0.0
			_phase = 5
			_t = 0.0
	elif _phase == 5:
		# Load into ambulance.
		_cam_track(_amb_arrive)
		_body_on_stretcher = _t < 0.55
		if _t >= 0.8:
			_body_on_stretcher = false
			_phase = 6
			_t = 0.0
	elif _phase == 6:
		var u := clampf(_t / 1.6, 0.0, 1.0)
		var ease := u * u
		_amb_world = _amb_arrive.lerp(_amb_depart, ease)
		_cam_track(_amb_world)
		if u >= 1.0:
			_finish_fire()


func _process_stomp(_delta: float) -> void:
	# 0: foot descends, 1: stomp+shake, 2: flat puddle, 3: janitor mop (~7s total)
	if _phase == 0 and _t >= 1.4:
		_phase = 1
		_t = 0.0
		_shake_amp = 18.0
		_flat_alpha = 1.0
		_hide_agent()
		_spawn_puff(10)
	elif _phase == 1 and _t >= 0.7:
		_phase = 2
		_t = 0.0
	elif _phase == 2 and _t >= 0.7:
		_phase = 3
		_t = 0.0
		_mop_x = -55.0
	elif _phase == 3:
		_mop_x = lerpf(-55.0, 55.0, clampf(_t / 3.2, 0.0, 1.0))
		_flat_alpha = clampf(1.0 - (_t - 0.8) / 2.2, 0.0, 1.0)
		if _t >= 3.6:
			_finish_fire()


func _process_anvil(_delta: float) -> void:
	if _phase == 0:
		_anvil_y = lerpf(-200.0, -8.0, clampf(_t / 1.8, 0.0, 1.0))
		if _t >= 1.8:
			_phase = 1
			_t = 0.0
			_shake_amp = 14.0
			_hide_agent()
			_spawn_puff(14)
	elif _phase == 1 and _t >= 4.5:
		_finish_fire()
	elif _phase == 1:
		_anvil_y = -8.0


func _process_trapdoor(_delta: float) -> void:
	if _phase == 0:
		_trap_open = clampf(_t / 1.2, 0.0, 1.0)
		_wave_hand = sin(_t * 10.0) * 10.0
		if _agent and is_instance_valid(_agent) and _agent.view:
			_agent.view.position.y = lerpf(0.0, 8.0, _trap_open)
		if _t >= 3.0:
			_phase = 1
			_t = 0.0
			_hide_agent()
	elif _phase == 1:
		_trap_open = clampf(1.0 - _t / 2.0, 0.0, 1.0)
		if _t >= 3.5:
			_finish_fire()


func _process_ufo(_delta: float) -> void:
	# ~7s: 0 big saucer descends + wide beam 2.2 · 1 agent rises (still readable) 2.6 · 2 zip 1.8
	# Saucer ~4–5× agent width; hover-bobs while parked over the agent.
	_ufo_bob = sin(_t * 3.4 + float(_phase) * 1.7) * 5.5
	_cam_track(_from_world + Vector2(_ufo_x * 0.35, (_ufo_y + _ufo_bob) * 0.12))
	if _phase == 0:
		var u := clampf(_t / 2.2, 0.0, 1.0)
		# Park higher so the big craft and wide cone clear the agent.
		_ufo_y = lerpf(-280.0, -118.0, 1.0 - pow(1.0 - u, 2.0))
		_beam_alpha = clampf((_t - 0.4) / 0.85, 0.0, 1.0)
		if int(_t * 12.0) != int((_t - _delta) * 12.0):
			_sparkles.append({
				"p": Vector2(randf_range(-36, 36), randf_range(-70, 10)),
				"v": Vector2(randf_range(-10, 10), randf_range(-36, -10)),
				"life": randf_range(0.35, 0.85),
				"c": Color(0.55, 1.0, 0.75, 1.0),
			})
		for s in _sparkles:
			s["p"] = s["p"] + s["v"] * _delta
			s["life"] -= _delta
		if _t >= 2.2:
			_phase = 1
			_t = 0.0
			_agent_float_y = 0.0
			_agent_spin = 0.0
			_agent_shrink = 1.0
	elif _phase == 1:
		_beam_alpha = 1.0
		_ufo_y = -118.0  # hold hover altitude; bob adds the float
		var u := clampf(_t / 2.6, 0.0, 1.0)
		# Rise into the craft; stay large until late so the agent reads clearly in the beam.
		_agent_float_y = lerpf(0.0, -108.0, u)
		_agent_spin = u * PI * 1.2
		_agent_shrink = lerpf(1.0, 0.55, clampf(u / 0.75, 0.0, 1.0))
		if u > 0.75:
			_agent_shrink = lerpf(0.55, 0.18, (u - 0.75) / 0.25)
		if _agent and is_instance_valid(_agent) and _agent.view:
			_agent.view.position.y = _agent_float_y
			_agent.view.rotation = _agent_spin
			_agent.view.scale = Vector2.ONE * Iso.PEOPLE_SCALE * _agent_shrink
			_agent.view.modulate.a = clampf(1.0 - (u - 0.82) / 0.18, 0.0, 1.0)
		if int(_t * 14.0) != int((_t - _delta) * 14.0):
			_sparkles.append({
				"p": Vector2(randf_range(-28, 28), _agent_float_y + randf_range(-10, 10)),
				"v": Vector2(randf_range(-12, 12), randf_range(-48, -14)),
				"life": randf_range(0.3, 0.7),
				"c": Color(0.7, 1.0, 0.9, 1.0),
			})
		for s in _sparkles:
			s["p"] = s["p"] + s["v"] * _delta
			s["life"] -= _delta
		if _t >= 2.6:
			_hide_agent()
			_phase = 2
			_t = 0.0
			_ufo_zip = 0.0
			_spawn_puff(16)
			for i in 28:
				_sparkles.append({
					"p": Vector2(randf_range(-40, 40), _ufo_y + randf_range(-16, 16)),
					"v": Vector2(randf_range(-110, 110), randf_range(-80, 30)),
					"life": randf_range(0.4, 1.0),
					"c": Color(1.0, randf_range(0.85, 1.0), randf_range(0.4, 0.9), 1.0),
				})
	elif _phase == 2:
		var u := clampf(_t / 1.8, 0.0, 1.0)
		_ufo_zip = u
		_ufo_x = lerpf(0.0, 260.0 * _amb_side if _amb_side != 0.0 else 260.0, u * u)
		_ufo_y = lerpf(-118.0, -300.0, u)
		_beam_alpha = clampf(1.0 - u * 1.6, 0.0, 1.0)
		for s in _sparkles:
			s["p"] = s["p"] + s["v"] * _delta
			s["life"] -= _delta
		if u >= 1.0:
			_finish_fire()


func _process_escort(_delta: float) -> void:
	# Guard arrives, agent picks up box, both walk to door (~7s).
	if _phase == 0 and _t >= 1.2:
		_phase = 1
		_t = 0.0
	elif _phase == 1:
		var u := clampf(_t / 5.2, 0.0, 1.0)
		var world := _from_world.lerp(_to_world, u)
		global_position = Iso.to_screen(world)
		if _agent and is_instance_valid(_agent):
			_agent.global_position = world + Vector2(-10, 0)
			if _agent.has_method("sync_view"):
				_agent.sync_view()
		if u >= 1.0:
			_hide_agent()
			_finish_fire()


func _spawn_puff(n: int) -> void:
	for i in n:
		_puff.append({
			"p": Vector2(randf_range(-16, 16), randf_range(-6, 6)),
			"v": Vector2(randf_range(-30, 30), randf_range(-50, -10)),
			"life": randf_range(0.35, 0.9),
			"r": randf_range(3.0, 8.0),
		})


func _draw() -> void:
	if kind == "hire":
		_draw_hire()
	elif kind == "fire":
		match variant:
			"ambulance":
				_draw_ambulance()
			"stomp":
				_draw_stomp()
			"anvil":
				_draw_anvil()
			"trapdoor":
				_draw_trapdoor()
			"ufo":
				_draw_ufo()
			"escort":
				_draw_escort()
			_:
				_draw_ambulance()
		for p in _puff:
			if p["life"] <= 0.0:
				continue
			var c := Color(0.85, 0.85, 0.9, clampf(p["life"], 0.0, 1.0) * 0.7)
			draw_circle(p["p"], p["r"], c)


func _draw_hire() -> void:
	var col := Color(1.0, 0.95, 0.55, _beam_alpha * 0.55)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, -120), Vector2(6, -120), Vector2(28, 8), Vector2(-28, 8)
	]), col)
	draw_circle(Vector2(0, -4), 16.0, Color(1, 1, 0.7, _beam_alpha * 0.35))
	for s in _sparkles:
		if s["life"] <= 0.0:
			continue
		var a := clampf(s["life"], 0.0, 1.0)
		var c: Color = s["c"]
		c.a = a
		draw_circle(s["p"], 2.2, c)


func _draw_ambulance() -> void:
	# Everything drawn relative to current global_position (cam-tracked screen point).
	# Convert world props into local offsets via Iso.
	var amb_s := Iso.to_screen(_amb_world) - global_position
	var agent_s := Iso.to_screen(_from_world) - global_position
	var entr_s := Iso.to_screen(_amb_arrive) - global_position

	# Collapsed agent silhouette while still visible in phase 0–2 (view handles rotation).
	if _phase <= 2 and not _body_on_stretcher:
		pass  # agent.view draws the body

	# Ambulance body (big, readable).
	if _phase >= 1:
		var ax := amb_s.x
		var ay := amb_s.y
		# Shadow
		_draw_ellipse_fx(Vector2(ax, ay + 18), Vector2(48, 10), Color(0, 0, 0, 0.25))
		# Chassis
		draw_rect(Rect2(ax - 52, ay - 22, 104, 36), Color("#eceff1"))
		draw_rect(Rect2(ax - 50, ay - 20, 100, 32), Color("#f5f5f5"))
		# Cab
		draw_rect(Rect2(ax + 18, ay - 28, 34, 28), Color("#e3f2fd"))
		draw_rect(Rect2(ax + 22, ay - 24, 26, 14), Color("#90caf9"))
		# Red stripe + cross
		draw_rect(Rect2(ax - 48, ay - 6, 64, 10), Color("#e53935"))
		draw_rect(Rect2(ax - 28, ay - 18, 8, 28), Color("#e53935"))
		draw_rect(Rect2(ax - 36, ay - 8, 24, 8), Color("#e53935"))
		# Wheels
		draw_circle(Vector2(ax - 30, ay + 16), 8.0, Color("#212121"))
		draw_circle(Vector2(ax + 28, ay + 16), 8.0, Color("#212121"))
		draw_circle(Vector2(ax - 30, ay + 16), 3.5, Color("#90a4ae"))
		draw_circle(Vector2(ax + 28, ay + 16), 3.5, Color("#90a4ae"))
		# Flashing red / blue lights
		var flash_on := fmod(_amb_flash, 0.35) < 0.18
		var left_c := Color("#e53935") if flash_on else Color("#1565c0")
		var right_c := Color("#1565c0") if flash_on else Color("#e53935")
		draw_circle(Vector2(ax - 18, ay - 28), 5.5, left_c)
		draw_circle(Vector2(ax + 6, ay - 28), 5.5, right_c)
		draw_circle(Vector2(ax - 18, ay - 28), 2.5, Color(1, 1, 1, 0.85))
		draw_circle(Vector2(ax + 6, ay - 28), 2.5, Color(1, 1, 1, 0.85))
		# Light wash on ground
		draw_circle(Vector2(ax - 18, ay + 8), 16.0, Color(left_c.r, left_c.g, left_c.b, 0.18))
		draw_circle(Vector2(ax + 6, ay + 8), 16.0, Color(right_c.r, right_c.g, right_c.b, 0.18))
		# Optional siren icon (♪) bobbing above
		if _phase >= 1 and _phase <= 6:
			var sy := ay - 48 - sin(_siren_bob) * 3.0
			draw_circle(Vector2(ax - 6, sy), 9.0, Color("#fff59d"))
			draw_string(ThemeDB.fallback_font, Vector2(ax - 11, sy + 4), "♪", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#f57f17"))

	# Medics + stretcher on the path (phases 2–5).
	if _phase >= 2 and _phase <= 5:
		var path_w := _amb_arrive.lerp(_from_world, _medic_u)
		var ps := Iso.to_screen(path_w) - global_position
		# Stretcher
		draw_rect(Rect2(ps.x - 28, ps.y - 4, 56, 12), Color("#cfd8dc"))
		draw_rect(Rect2(ps.x - 26, ps.y - 2, 52, 8), Color("#eceff1"))
		draw_rect(Rect2(ps.x - 24, ps.y + 6, 6, 6), Color("#546e7a"))  # legs
		draw_rect(Rect2(ps.x + 18, ps.y + 6, 6, 6), Color("#546e7a"))
		if _body_on_stretcher:
			# Body bundle on stretcher
			draw_rect(Rect2(ps.x - 16, ps.y - 8, 32, 10), Color("#90a4ae"))
			draw_circle(Vector2(ps.x + 14, ps.y - 6), 5.0, Color("#ffe0b2"))
		# Two medics
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			var mp := ps + Vector2(side * 34.0, 2.0)
			# Walk bob
			var bob := sin(_t * 10.0 + i) * 2.0 if _phase in [2, 4] else 0.0
			mp.y += bob
			draw_circle(mp + Vector2(0, -16), 6.5, Color("#ffccbc"))  # head
			draw_rect(Rect2(mp.x - 7, mp.y - 10, 14, 18), Color("#e53935"))  # coat
			draw_rect(Rect2(mp.x - 2, mp.y - 4, 4, 8), Color.WHITE)  # cross
			draw_rect(Rect2(mp.x - 5, mp.y, 10, 3), Color.WHITE)
			draw_rect(Rect2(mp.x - 6, mp.y + 8, 5, 8), Color("#37474f"))  # legs
			draw_rect(Rect2(mp.x + 1, mp.y + 8, 5, 8), Color("#37474f"))


func _draw_stomp() -> void:
	# Giant cartoon foot descending / planted.
	var foot_y := -140.0
	if _phase == 0:
		foot_y = lerpf(-160.0, -6.0, clampf(_t / 1.4, 0.0, 1.0))
	elif _phase >= 1:
		foot_y = -6.0 if _phase == 1 else -120.0
	if _phase <= 1:
		draw_colored_polygon(PackedVector2Array([
			Vector2(-34, foot_y - 10), Vector2(40, foot_y - 6),
			Vector2(36, foot_y + 14), Vector2(-30, foot_y + 12)
		]), Color("#5d4037"))
		draw_circle(Vector2(28, foot_y + 4), 8.0, Color("#3e2723"))  # big toe
		draw_circle(Vector2(14, foot_y + 2), 5.0, Color("#3e2723"))
		draw_circle(Vector2(2, foot_y + 2), 5.0, Color("#3e2723"))
	if _flat_alpha > 0.0:
		draw_circle(Vector2(0, 6), 18.0, Color(0.4, 0.45, 0.55, _flat_alpha * 0.55))
		draw_circle(Vector2(0, 6), 10.0, Color(0.3, 0.35, 0.45, _flat_alpha * 0.7))
	if _phase >= 3:
		# Janitor + mop + bucket
		var jx := _mop_x
		draw_circle(Vector2(jx, -12), 5.0, Color("#ffe0b2"))
		draw_rect(Rect2(jx - 5, -8, 10, 16), Color("#1565c0"))
		draw_line(Vector2(jx + 6, -4), Vector2(jx + 6, 14), Color("#8d6e63"), 2.0)
		draw_rect(Rect2(jx + 2, 12, 12, 4), Color("#b0bec5"))  # mop head
		draw_rect(Rect2(jx - 22, 8, 12, 10), Color("#90caf9"))  # bucket
		draw_rect(Rect2(jx - 20, 6, 8, 3), Color("#64b5f6"))


func _draw_anvil() -> void:
	var y := _anvil_y
	draw_colored_polygon(PackedVector2Array([
		Vector2(-22, y), Vector2(22, y), Vector2(16, y + 10), Vector2(-16, y + 10)
	]), Color("#455a64"))
	draw_rect(Rect2(-8, y + 10, 16, 14), Color("#37474f"))
	draw_rect(Rect2(-14, y + 22, 28, 6), Color("#263238"))
	draw_string(ThemeDB.fallback_font, Vector2(-18, y + 8), "ACME", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color("#eceff1"))


func _draw_trapdoor() -> void:
	draw_rect(Rect2(-24, 4, 48, 6), Color("#5d4037"))
	# Door swinging open
	var ang := _trap_open * (-PI * 0.7)
	var tip := Vector2(cos(ang), sin(ang)) * 40.0
	draw_line(Vector2(-24, 4), Vector2(-24, 4) + tip, Color("#8d6e63"), 4.0)
	draw_circle(Vector2(12, -18 + _wave_hand * 0.15), 4.0, Color("#ffe0b2"))  # waving hand
	draw_line(Vector2(12, -14), Vector2(12, -6 + _wave_hand * 0.05), Color("#ffe0b2"), 2.5)
	draw_circle(Vector2(-6, -20), 3.0, Color("#fff59d"))  # sparkle


func _draw_ufo() -> void:
	# Craft ~4–5× agent width (~160–180 px saucer), glass dome, rim lights, hover bob,
	# wide beam cone. Agent is drawn separately (AgentView) and stays readable while rising.
	var x := _ufo_x
	var y := _ufo_y + (_ufo_bob if _phase < 2 else 0.0)
	var fade := 1.0
	if _phase == 2:
		fade = clampf(1.0 - _ufo_zip * 1.1, 0.0, 1.0)
	# Wide tractor beam (drawn under the saucer).
	if _beam_alpha > 0.0:
		var a := _beam_alpha * fade
		var top_y := y + 28.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 36, top_y), Vector2(x + 36, top_y),
			Vector2(x + 110, 22), Vector2(x - 110, 22)
		]), Color(0.35, 1.0, 0.65, a * 0.22))
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 22, top_y), Vector2(x + 22, top_y),
			Vector2(x + 72, 18), Vector2(x - 72, 18)
		]), Color(0.65, 1.0, 0.85, a * 0.32))
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 10, top_y), Vector2(x + 10, top_y),
			Vector2(x + 36, 14), Vector2(x - 36, 14)
		]), Color(0.9, 1.0, 0.95, a * 0.4))
		draw_circle(Vector2(x, 12), 48.0, Color(0.55, 1.0, 0.75, a * 0.16))
	# Sparkles / particles
	for s in _sparkles:
		if s["life"] <= 0.0:
			continue
		var c: Color = s["c"]
		c.a = clampf(s["life"], 0.0, 1.0) * fade
		draw_circle(s["p"] + Vector2(x * 0.12, 0), 3.0, c)
	# Shadow under craft
	_draw_ellipse_fx(Vector2(x, y + 22), Vector2(88, 18), Color(0.05, 0.1, 0.05, 0.32 * fade))
	# Lower hull (saucer body) — ~170 px across
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - 86, y + 2), Vector2(x + 86, y + 2),
		Vector2(x + 62, y + 26), Vector2(x - 62, y + 26)
	]), Color(0.42, 0.62, 0.22, fade))
	_draw_ellipse_fx(Vector2(x, y + 4), Vector2(90, 16), Color(0.55, 0.78, 0.3, fade))
	# Mid rim band
	_draw_ellipse_fx(Vector2(x, y + 10), Vector2(78, 10), Color(0.3, 0.45, 0.18, fade * 0.85))
	# Glass dome
	draw_circle(Vector2(x, y - 18), 38.0, Color(0.55, 0.95, 0.75, 0.55 * fade))
	draw_circle(Vector2(x, y - 22), 30.0, Color(0.75, 1.0, 0.9, 0.45 * fade))
	draw_circle(Vector2(x - 10, y - 30), 10.0, Color(1, 1, 1, 0.5 * fade))  # dome highlight
	draw_circle(Vector2(x + 8, y - 14), 6.0, Color(0.4, 0.85, 0.65, 0.35 * fade))
	# Cockpit ring
	draw_arc(Vector2(x, y - 6), 40.0, PI * 1.05, PI * 1.95, 18, Color(0.7, 1.0, 0.4, fade), 3.0, true)
	# Rim lights (pulsing)
	var pulse := 0.65 + 0.35 * sin(_t * 8.0)
	for i in 10:
		var ang := -PI * 0.08 + i * (PI * 1.16 / 9.0)
		var lx := x + cos(ang) * 72.0
		var ly := y + 12.0 + sin(ang) * 8.0
		var lit := Color(1.0, 0.92, 0.25, fade * pulse) if i % 2 == 0 else Color(0.4, 1.0, 0.85, fade * pulse)
		draw_circle(Vector2(lx, ly), 4.8, lit)
		draw_circle(Vector2(lx, ly), 2.2, Color(1, 1, 1, fade * 0.85))
	# Underside hatch glow into the beam
	_draw_ellipse_fx(Vector2(x, y + 24), Vector2(28, 8), Color(0.7, 1.0, 0.85, 0.55 * _beam_alpha * fade))
	# Zip sparkle burst
	if _phase == 2 and _ufo_zip > 0.05:
		for i in 12:
			var ang2 := i * PI * 0.167 + _ufo_zip * 5.0
			var rr := 36.0 + _ufo_zip * 70.0
			draw_circle(Vector2(x, y) + Vector2(cos(ang2), sin(ang2)) * rr, 3.2,
				Color(1, 1, 0.6, fade * 0.9))


func _draw_ellipse_fx(center: Vector2, radii: Vector2, color: Color) -> void:
	var pts := PackedVector2Array()
	var n := 24
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_colored_polygon(pts, color)


func _draw_escort() -> void:
	# Security guard (left) + cardboard box
	var gx := 22.0
	draw_circle(Vector2(gx, -14), 5.5, Color("#ffe0b2"))
	draw_rect(Rect2(gx - 6, -10, 12, 18), Color("#37474f"))
	draw_rect(Rect2(gx - 7, -18, 14, 5), Color("#212121"))  # cap
	draw_circle(Vector2(gx + 1, -15), 1.2, Color("#ffeb3b"))  # badge glint
	# Box of desk stuff
	var bx := _escort_box.x
	var by := _escort_box.y
	draw_rect(Rect2(bx - 10, by, 20, 14), Color("#a1887f"))
	draw_rect(Rect2(bx - 10, by, 20, 3), Color("#8d6e63"))
	draw_rect(Rect2(bx - 3, by - 6, 4, 6), Color("#90caf9"))  # mug
	draw_rect(Rect2(bx + 4, by - 4, 6, 4), Color("#fff59d"))  # sticky notes
