## Cartoon hire / fire pageantry for Agent Office.
## Hire: beam of light from above, sparkles, sprite fades in at the desk.
## Fire: soft collapse at the desk, two medic chibis with a stretcher carry
## the agent out the entrance, then the desk is cleared. Pixel-art friendly,
## never gory.
extends Node2D

signal finished(kind: String, agent_id: String)

var kind := ""           ## "hire" | "fire"
var agent_id := ""
var _agent: Node = null  ## Agent
var _t := 0.0
var _phase := 0
var _medics: Array[Node2D] = []
var _stretcher: Node2D = null
var _carry_from := Vector2.ZERO
var _carry_to := Vector2.ZERO
var _beam_alpha := 0.0
var _sparkles: Array[Dictionary] = []

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


func play_fire(agent: Node, entrance_pos: Vector2) -> void:
	kind = "fire"
	agent_id = str(agent.agent_id)
	_agent = agent
	_carry_from = agent.global_position
	_carry_to = entrance_pos
	global_position = _carry_from
	# Soft "collapse": squash the view.
	if agent.view:
		agent.view.scale.y *= 0.35
		agent.view.scale.x *= 1.15
	# Two medic markers + stretcher (simple Node2D drawings).
	for i in 2:
		var m := Node2D.new()
		m.set_meta("medic", true)
		m.set_meta("side", -1 if i == 0 else 1)
		m.position = Vector2((-28 if i == 0 else 28), 40)
		add_child(m)
		_medics.append(m)
	_stretcher = Node2D.new()
	_stretcher.set_meta("stretcher", true)
	add_child(_stretcher)
	_phase = 0
	_t = 0.0
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	if kind == "hire":
		_process_hire(delta)
	elif kind == "fire":
		_process_fire(delta)
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


func _process_fire(delta: float) -> void:
	# 0: collapse pause, 1: medics arrive, 2: carry to door, 3: done
	if _phase == 0 and _t >= 0.55:
		_phase = 1
		_t = 0.0
	elif _phase == 1 and _t >= 0.7:
		_phase = 2
		_t = 0.0
		if _agent and is_instance_valid(_agent):
			_agent.visible = false
			if _agent.view:
				_agent.view.visible = false
	elif _phase == 2:
		var u := clampf(_t / 2.2, 0.0, 1.0)
		var pos := _carry_from.lerp(_carry_to, u)
		global_position = pos
		if u >= 1.0:
			_phase = 3
			finished.emit("fire", agent_id)
			queue_free()


func _draw() -> void:
	if kind == "hire":
		# Beam from above.
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
			draw_rect(Rect2(s["p"] + Vector2(-1.5, -4), Vector2(3, 3)), c)
	elif kind == "fire":
		# Stretcher + two little medic crosses.
		draw_rect(Rect2(-22, -6, 44, 10), Color("#eceff1"))
		draw_rect(Rect2(-20, -4, 40, 6), Color("#90a4ae"))
		for m in _medics:
			var side := int(m.get_meta("side"))
			var mp := Vector2(side * 26, 4)
			draw_circle(mp + Vector2(0, -10), 5.0, Color("#ef9a9a"))  # head
			draw_rect(Rect2(mp.x - 5, mp.y - 6, 10, 14), Color("#e53935"))  # body
			# Medical cross
			draw_rect(Rect2(mp.x - 1, mp.y - 2, 2, 6), Color.WHITE)
			draw_rect(Rect2(mp.x - 3, mp.y, 6, 2), Color.WHITE)
