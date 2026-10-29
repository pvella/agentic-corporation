## Cartoon hire / fire pageantry for Agent Office.
## Hire: beam of light from above, sparkles, sprite fades in at the desk.
## Fire: randomly pick a playful pixel-art exit (never gory). Variants:
##   medics   — agent topples, paramedics drag them out the door
##   stomp    — giant cartoon foot stomps flat + screen shake, janitor mops
##   anvil    — Acme anvil drops, puff of smoke, desk cleared
##   trapdoor — trapdoor opens, wave goodbye, fall through
##   ufo      — UFO beam-up
##   escort   — security guard walks them out with a box of desk stuff
## Preview: pass variant= name, or cycle with Shift+F / preview keys.
extends Node2D

signal finished(kind: String, agent_id: String)

const FIRE_VARIANTS := ["medics", "stomp", "anvil", "trapdoor", "ufo", "escort"]

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
var _flat_alpha := 0.0
var _mop_x := -40.0
var _anvil_y := -180.0
var _ufo_y := -160.0
var _trap_open := 0.0
var _wave_hand := 0.0
var _escort_box := Vector2.ZERO
var _puff: Array[Dictionary] = []
var _forced_variant := ""

static var _preview_cycle := 0


static func next_preview_variant() -> String:
	var v: String = FIRE_VARIANTS[_preview_cycle % FIRE_VARIANTS.size()]
	_preview_cycle = (_preview_cycle + 1) % FIRE_VARIANTS.size()
	return v


func play_hire(agent: Node, desk_pos: Vector2) -> void:
	kind = "hire"
	agent_id = str(agent.agent_id)
	_agent = agent
	global_position = desk_pos
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
	_carry_from = agent.global_position
	_carry_to = entrance_pos
	global_position = _carry_from
	_forced_variant = forced.strip_edges()
	if _forced_variant != "" and _forced_variant in FIRE_VARIANTS:
		variant = _forced_variant
	else:
		variant = FIRE_VARIANTS[randi() % FIRE_VARIANTS.size()]
	_phase = 0
	_t = 0.0
	_cam = get_viewport().get_camera_2d()
	if _cam:
		_cam_orig = _cam.offset
	match variant:
		"medics":
			_setup_medics()
		"stomp":
			_flat_alpha = 0.0
			_mop_x = -50.0
		"anvil":
			_anvil_y = -200.0
		"trapdoor":
			_trap_open = 0.0
			_wave_hand = 0.0
		"ufo":
			_ufo_y = -180.0
			_beam_alpha = 0.0
		"escort":
			_escort_box = Vector2(18, -8)
			if agent.view:
				agent.view.modulate = Color(1, 1, 1, 1)
	set_process(true)
	queue_redraw()


func _setup_medics() -> void:
	# Soft topple first — rotation handled in process.
	for i in 2:
		var m := Node2D.new()
		m.set_meta("medic", true)
		m.set_meta("side", -1 if i == 0 else 1)
		m.position = Vector2((-30 if i == 0 else 30), 50)
		add_child(m)
		_medics.append(m)


func _process(delta: float) -> void:
	_t += delta
	if kind == "hire":
		_process_hire(delta)
	elif kind == "fire":
		match variant:
			"medics":
				_process_medics(delta)
			"stomp":
				_process_stomp(delta)
			"anvil":
				_process_anvil(delta)
			"trapdoor":
				_process_trapdoor(delta)
			"ufo":
				_process_ufo(delta)
			"escort":
				_process_escort(delta)
			_:
				_process_medics(delta)
	if _shake_amp > 0.0 and _cam:
		_cam.offset = _cam_orig + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake_amp
		_shake_amp = maxf(0.0, _shake_amp - delta * 40.0)
		if _shake_amp <= 0.0:
			_cam.offset = _cam_orig
	for p in _puff:
		p["p"] = p["p"] + p["v"] * delta
		p["life"] -= delta
	queue_redraw()


func _process_hire(delta: float) -> void:
	_beam_alpha = clampf(_t * 2.0, 0.0, 1.0) * clampf(1.4 - _t, 0.0, 1.0)
	for s in _sparkles:
		s["p"] = s["p"] + s["v"] * delta
		s["life"] -= delta
	if _agent and is_instance_valid(_agent) and _agent.view:
		_agent.view.modulate.a = clampf((_t - 0.25) / 0.7, 0.0, 1.0)
	if _t >= 1.6:
		if _agent and is_instance_valid(_agent) and _agent.view:
			_agent.view.modulate.a = 1.0
		finished.emit("hire", agent_id)
		queue_free()


func _finish_fire() -> void:
	if _cam:
		_cam.offset = _cam_orig
	finished.emit("fire", agent_id)
	queue_free()


func _hide_agent() -> void:
	if _agent and is_instance_valid(_agent):
		_agent.visible = false
		if _agent.view:
			_agent.view.visible = false


func _process_medics(_delta: float) -> void:
	# 0: slow topple, 1: medics arrive, 2: drag to door, 3: done
	if _phase == 0:
		if _agent and is_instance_valid(_agent) and _agent.view:
			var u := clampf(_t / 0.9, 0.0, 1.0)
			_agent.view.rotation = lerp_angle(0.0, PI / 2.0, u)
			_agent.view.scale.y = lerpf(1.0, 0.55, u)
		if _t >= 1.0:
			_phase = 1
			_t = 0.0
	elif _phase == 1 and _t >= 0.8:
		_phase = 2
		_t = 0.0
		_hide_agent()
	elif _phase == 2:
		var u := clampf(_t / 2.2, 0.0, 1.0)
		global_position = _carry_from.lerp(_carry_to, u)
		if u >= 1.0:
			_finish_fire()


func _process_stomp(_delta: float) -> void:
	# 0: foot descends, 1: stomp+shake, 2: flat puddle, 3: janitor mop, 4: done
	if _phase == 0 and _t >= 0.55:
		_phase = 1
		_t = 0.0
		_shake_amp = 18.0
		_flat_alpha = 1.0
		_hide_agent()
		_spawn_puff(10)
	elif _phase == 1 and _t >= 0.45:
		_phase = 2
		_t = 0.0
	elif _phase == 2 and _t >= 0.35:
		_phase = 3
		_t = 0.0
		_mop_x = -55.0
	elif _phase == 3:
		_mop_x = lerpf(-55.0, 55.0, clampf(_t / 1.4, 0.0, 1.0))
		_flat_alpha = clampf(1.0 - (_t - 0.4) / 1.0, 0.0, 1.0)
		if _t >= 1.6:
			_finish_fire()


func _process_anvil(_delta: float) -> void:
	if _phase == 0:
		_anvil_y = lerpf(-200.0, -8.0, clampf(_t / 0.55, 0.0, 1.0))
		if _t >= 0.55:
			_phase = 1
			_t = 0.0
			_shake_amp = 14.0
			_hide_agent()
			_spawn_puff(14)
	elif _phase == 1 and _t >= 0.9:
		_finish_fire()


func _process_trapdoor(_delta: float) -> void:
	if _phase == 0:
		_trap_open = clampf(_t / 0.45, 0.0, 1.0)
		_wave_hand = sin(_t * 14.0) * 10.0
		if _agent and is_instance_valid(_agent) and _agent.view:
			_agent.view.position.y = lerpf(0.0, 8.0, _trap_open)
		if _t >= 0.7:
			_phase = 1
			_t = 0.0
			_hide_agent()
	elif _phase == 1:
		_trap_open = clampf(1.0 - _t / 0.5, 0.0, 1.0)
		if _t >= 0.7:
			_finish_fire()


func _process_ufo(_delta: float) -> void:
	if _phase == 0:
		_ufo_y = lerpf(-180.0, -70.0, clampf(_t / 0.7, 0.0, 1.0))
		_beam_alpha = clampf((_t - 0.3) / 0.4, 0.0, 1.0)
		if _t >= 0.9:
			_phase = 1
			_t = 0.0
	elif _phase == 1:
		_beam_alpha = 1.0
		if _agent and is_instance_valid(_agent) and _agent.view:
			_agent.view.modulate.a = clampf(1.0 - _t / 0.7, 0.0, 1.0)
			_agent.view.position.y = -_t * 50.0
			_agent.view.scale = Vector2.ONE * clampf(1.0 - _t / 0.9, 0.15, 1.0)
		if _t >= 0.85:
			_hide_agent()
			_phase = 2
			_t = 0.0
	elif _phase == 2:
		_ufo_y = lerpf(-70.0, -200.0, clampf(_t / 0.55, 0.0, 1.0))
		_beam_alpha = clampf(1.0 - _t / 0.4, 0.0, 1.0)
		if _t >= 0.7:
			_finish_fire()


func _process_escort(_delta: float) -> void:
	# Guard arrives, agent picks up box, both walk to door.
	if _phase == 0 and _t >= 0.6:
		_phase = 1
		_t = 0.0
	elif _phase == 1:
		var u := clampf(_t / 2.4, 0.0, 1.0)
		var pos := _carry_from.lerp(_carry_to, u)
		global_position = pos
		if _agent and is_instance_valid(_agent):
			_agent.global_position = pos + Vector2(-10, 0)
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
			"medics":
				_draw_medics()
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
				_draw_medics()
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


func _draw_medics() -> void:
	draw_rect(Rect2(-22, -6, 44, 10), Color("#eceff1"))
	draw_rect(Rect2(-20, -4, 40, 6), Color("#90a4ae"))
	for m in _medics:
		var side := int(m.get_meta("side"))
		var mp := Vector2(side * 26, 4)
		if _phase >= 1:
			mp.y = 4
		else:
			mp.y = 40 - clampf(_t / 0.5, 0.0, 1.0) * 36.0
		draw_circle(mp + Vector2(0, -10), 5.0, Color("#ef9a9a"))
		draw_rect(Rect2(mp.x - 5, mp.y - 6, 10, 14), Color("#e53935"))
		draw_rect(Rect2(mp.x - 1, mp.y - 2, 2, 6), Color.WHITE)
		draw_rect(Rect2(mp.x - 3, mp.y, 6, 2), Color.WHITE)


func _draw_stomp() -> void:
	# Giant cartoon foot descending / planted.
	var foot_y := -140.0
	if _phase == 0:
		foot_y = lerpf(-160.0, -6.0, clampf(_t / 0.55, 0.0, 1.0))
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
	var y := _ufo_y
	if _beam_alpha > 0.0:
		draw_colored_polygon(PackedVector2Array([
			Vector2(-8, y + 8), Vector2(8, y + 8), Vector2(26, 10), Vector2(-26, 10)
		]), Color(0.4, 1.0, 0.6, _beam_alpha * 0.35))
	draw_circle(Vector2(0, y), 14.0, Color("#b2ff59"))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-28, y + 4), Vector2(28, y + 4), Vector2(18, y + 14), Vector2(-18, y + 14)
	]), Color("#7cb342"))
	for i in 5:
		draw_circle(Vector2(-16 + i * 8, y + 8), 2.0, Color("#ffeb3b"))


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
