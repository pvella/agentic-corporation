## Slide-out terminal inspector for one agent.
##
## Shows the agent's log buffer (ANSI colours converted to BBCode), live-updates
## while open, and lets the user dispatch a prompt back to the agent.
extends CanvasLayer

signal prompt_submitted(agent_id: String, prompt: String)
signal closed

const Ansi := preload("res://ansi.gd")
const SLIDE_TIME := 0.28
const MAX_RENDERED_LINES := 600

@export var panel_width: float = 470.0

var agent: Agent = null
var _slide := 0.0  # 0 = hidden (off-screen right), 1 = fully open
var _tween: Tween
var _showing_placeholder := false

@onready var panel: PanelContainer = $Panel
@onready var state_dot: Panel = $Panel/Margin/VBox/Header/StateDot
@onready var name_label: Label = $Panel/Margin/VBox/Header/NameLabel
@onready var state_label: Label = $Panel/Margin/VBox/Header/StateLabel
@onready var close_button: Button = $Panel/Margin/VBox/Header/CloseButton
@onready var log_view: RichTextLabel = $Panel/Margin/VBox/Log
@onready var prompt_input: LineEdit = $Panel/Margin/VBox/Footer/PromptInput
@onready var send_button: Button = $Panel/Margin/VBox/Footer/SendButton


func _ready() -> void:
	close_button.pressed.connect(close)
	send_button.pressed.connect(_submit)
	prompt_input.text_submitted.connect(func(_t: String) -> void: _submit())
	# Monospace font for the terminal body.
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["DejaVu Sans Mono", "Menlo", "Consolas", "Liberation Mono", "monospace"])
	log_view.add_theme_font_override("normal_font", mono)
	var mono_bold := SystemFont.new()
	mono_bold.font_names = mono.font_names
	mono_bold.font_weight = 700
	log_view.add_theme_font_override("bold_font", mono_bold)
	var mono_italic := SystemFont.new()
	mono_italic.font_names = mono.font_names
	mono_italic.font_italic = true
	log_view.add_theme_font_override("italics_font", mono_italic)
	_set_slide(0.0)
	panel.visible = false


func is_open() -> bool:
	return agent != null


## Opens (or switches) the drawer to `a` and renders its log history.
func open_for(a: Agent) -> void:
	if agent and agent != a and is_instance_valid(agent):
		_disconnect_agent(agent)
	agent = a
	_disconnect_agent(a)  # avoid double connections when re-opening the same agent
	agent.log_added.connect(_on_agent_log_added)
	agent.state_changed.connect(_on_agent_state_changed)
	name_label.text = "%s  (%s)" % [a.display_name, a.agent_id]
	name_label.add_theme_color_override("font_color", a.body_color.lightened(0.4))
	_update_state(a.state)
	_render_all()
	panel.visible = true
	_animate_to(1.0)
	prompt_input.placeholder_text = "Prompt for %s, e.g. Fix bug in auth.py" % a.display_name
	prompt_input.grab_focus.call_deferred()


func close() -> void:
	if agent and is_instance_valid(agent):
		_disconnect_agent(agent)
	agent = null
	prompt_input.release_focus()
	_animate_to(0.0)
	closed.emit()


## Adds a local, non-agent line (e.g. connection errors, ACKs).
func append_system(text: String, colour: String = "#7f848e") -> void:
	if agent == null:
		return
	if _showing_placeholder:
		log_view.clear()
		_showing_placeholder = false
	log_view.append_text("[color=%s][i]%s[/i][/color]\n" % [colour, Ansi.escape_bbcode(text)])


func _unhandled_input(event: InputEvent) -> void:
	if agent and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _disconnect_agent(a: Agent) -> void:
	if a.log_added.is_connected(_on_agent_log_added):
		a.log_added.disconnect(_on_agent_log_added)
	if a.state_changed.is_connected(_on_agent_state_changed):
		a.state_changed.disconnect(_on_agent_state_changed)


func _render_all() -> void:
	log_view.clear()
	var lines := agent.log_lines
	var start := maxi(0, lines.size() - MAX_RENDERED_LINES)
	if start > 0:
		log_view.append_text("[color=#5c6370]... %d earlier lines hidden ...[/color]\n" % start)
	for i in range(start, lines.size()):
		log_view.append_text(Ansi.to_bbcode(lines[i]) + "\n")
	_showing_placeholder = lines.is_empty()
	if _showing_placeholder:
		log_view.append_text("[color=#5c6370][i]No output yet. Send a prompt below.[/i][/color]\n")


func _on_agent_log_added(_a: Agent, line: String) -> void:
	if _showing_placeholder:
		_render_all()  # drops the "No output yet" placeholder, includes `line`
		return
	log_view.append_text(Ansi.to_bbcode(line) + "\n")
	# Keep the RichTextLabel from growing without bound while open.
	if log_view.get_paragraph_count() > MAX_RENDERED_LINES * 2:
		_render_all()


func _on_agent_state_changed(_a: Agent, new_state: String) -> void:
	_update_state(new_state)


func _update_state(s: String) -> void:
	state_label.text = s
	var sb := StyleBoxFlat.new()
	sb.bg_color = Agent.STATE_COLORS.get(s, Color.GRAY)
	sb.set_corner_radius_all(7)
	state_dot.add_theme_stylebox_override("panel", sb)


func _submit() -> void:
	if agent == null:
		return
	var text := prompt_input.text.strip_edges()
	if text.is_empty():
		return
	prompt_input.clear()
	if _showing_placeholder:
		log_view.clear()
		_showing_placeholder = false
	log_view.append_text("[color=#61afef][b]you>[/b][/color] %s\n" % Ansi.escape_bbcode(text))
	prompt_submitted.emit(agent.agent_id, text)


func _animate_to(target: float) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_slide, _slide, target, SLIDE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if target == 0.0:
		_tween.tween_callback(func() -> void: panel.visible = false)


## Positions the panel: anchored to the right edge, shifted off-screen by (1 - t) * width.
func _set_slide(t: float) -> void:
	_slide = t
	panel.offset_left = -panel_width * t
	panel.offset_right = panel_width * (1.0 - t)


## Re-renders the open agent (after a SNAPSHOT replaced its log history).
func refresh() -> void:
	if agent and is_instance_valid(agent):
		_update_state(agent.state)
		_render_all()
