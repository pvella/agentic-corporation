## Screen-space Notice Board HUD: compact, draggable panel (HUD child).
## Defaults to bottom-left so it stays clear of the right-side terminal drawer.
## Position is remembered in user://agent_office.cfg. Click / /notices open the full list.
extends Control

signal open_requested

const NoticesScript := preload("res://Notices.gd")
const SETTINGS_PATH := "user://agent_office.cfg"
const SETTINGS_SECTION := "notice_board"

const PANEL_W := 260.0
const PIN_COUNT := 5
const MARGIN := 12.0
const BOTTOM_UI := 30.0  ## leave room for BottomBar counts/hint
const TOP_UI := 48.0  ## leave room for TopBar
const HEADER_H := 24.0
const CARD_H := 22.0
const CARD_GAP := 2.0
const FOOTER_H := 18.0
const PAD := 8.0
const FONT_SIZE := 11
const TITLE_FONT := 12

var store: RefCounted = null  ## Notices
var _font: Font
var _panel: Window = null
var _list: RichTextLabel = null
var _dragging := false
var _drag_grab := Vector2.ZERO
var _pos_loaded := false


func setup(notices: RefCounted) -> void:
	store = notices
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_apply_default_size()
	if not _pos_loaded:
		_load_or_default_position()
		_pos_loaded = true
	if store and store.has_signal("changed") and not store.changed.is_connected(_on_store_changed):
		store.changed.connect(_on_store_changed)
	if not get_viewport().size_changed.is_connected(_on_viewport_resized):
		get_viewport().size_changed.connect(_on_viewport_resized)
	queue_redraw()
	tooltip_text = "Notice Board — drag title to move · click body for all · /notices"


func _apply_default_size() -> void:
	var body_h := float(PIN_COUNT) * (CARD_H + CARD_GAP) - CARD_GAP
	var total_h := PAD + HEADER_H + 4.0 + body_h + FOOTER_H + PAD
	custom_minimum_size = Vector2(PANEL_W, total_h)
	size = Vector2(PANEL_W, total_h)
	# Free-floating; anchors at top-left so position = absolute screen coords.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END


func _default_bottom_left() -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var x := MARGIN
	var y := vp.y - size.y - BOTTOM_UI - MARGIN
	return _clamp_pos(Vector2(x, y))


func _load_or_default_position() -> void:
	var cfg := ConfigFile.new()
	var loaded := false
	if cfg.load(SETTINGS_PATH) == OK and cfg.has_section_key(SETTINGS_SECTION, "x"):
		var x := float(cfg.get_value(SETTINGS_SECTION, "x", -1))
		var y := float(cfg.get_value(SETTINGS_SECTION, "y", -1))
		if x >= 0.0 and y >= 0.0:
			position = _clamp_pos(Vector2(x, y))
			loaded = true
	if not loaded:
		# Bottom-left: clear of the right-side terminal drawer (470px) and above BottomBar.
		position = _default_bottom_left()


func _save_position() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SETTINGS_SECTION, "x", position.x)
	cfg.set_value(SETTINGS_SECTION, "y", position.y)
	cfg.save(SETTINGS_PATH)


func _clamp_pos(p: Vector2) -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var max_x := maxf(MARGIN, vp.x - size.x - MARGIN)
	var max_y := maxf(TOP_UI, vp.y - size.y - BOTTOM_UI - MARGIN)
	return Vector2(clampf(p.x, MARGIN, max_x), clampf(p.y, TOP_UI, max_y))


func _on_viewport_resized() -> void:
	position = _clamp_pos(position)


func _title_rect() -> Rect2:
	return Rect2(PAD, PAD, size.x - PAD * 2.0, HEADER_H)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var local := (event as InputEventMouseButton).position
		if event.pressed:
			if _title_rect().has_point(local):
				_dragging = true
				_drag_grab = get_global_mouse_position() - global_position
				modulate = Color(1.08, 1.08, 1.05, 1.0)
				accept_event()
				return
			# Body click → expand
			open_full_list()
			accept_event()
		else:
			if _dragging:
				_end_drag()
				accept_event()


func _input(event: InputEvent) -> void:
	# Keep dragging even when the cursor leaves the panel.
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		position = _clamp_pos(get_global_mouse_position() - _drag_grab)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_end_drag()
		get_viewport().set_input_as_handled()


func _end_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	modulate = Color.WHITE
	position = _clamp_pos(position)
	_save_position()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER and not _dragging:
		modulate = Color(1.05, 1.05, 1.03, 1.0)
	elif what == NOTIFICATION_MOUSE_EXIT and not _dragging:
		modulate = Color.WHITE


func _on_store_changed() -> void:
	queue_redraw()
	if _panel and is_instance_valid(_panel) and _panel.visible:
		_refresh_panel()


func _draw() -> void:
	var box := Rect2(Vector2.ZERO, size)
	draw_rect(Rect2(box.position + Vector2(2, 3), box.size), Color(0, 0, 0, 0.28))
	draw_rect(box, Color("#5d4037"))
	draw_rect(box.grow(-2), Color("#a1887f"))
	draw_rect(box.grow(-4), Color("#bcaaa4"))
	var header := _title_rect()
	draw_rect(header, Color("#4e342e"))
	# Drag affordance dots on the title bar
	if _font:
		draw_string(_font, header.position + Vector2(8, 16), "NOTICE BOARD", HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FONT, Color("#fff8e1"))
		draw_string(_font, Vector2(header.end.x - 36, header.position.y + 15), "⋮⋮", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#d7ccc8"))
	var pins: Array = store.latest(PIN_COUNT) if store else []
	var y := header.end.y + 4.0
	for i in pins.size():
		var e: Dictionary = pins[i]
		var card := Rect2(PAD, y, size.x - PAD * 2.0, CARD_H)
		var col := Color(str(e.get("color", "#b0bec5")))
		var pending := bool(e.get("pending", false))
		var bg := Color("#efebe9") if not pending else Color("#fff3e0")
		draw_rect(card, bg)
		draw_rect(Rect2(card.position.x, card.position.y, 3, card.size.y), col)
		draw_circle(Vector2(card.position.x + 9, card.position.y + 6), 1.8, col)
		var tstr: String = ""
		if store and store.has_method("format_time"):
			tstr = str(store.format_time(float(e.get("ts", 0))))
		var icon := str(e.get("icon", "•"))
		var title := str(e.get("title", ""))
		if title.length() > 22:
			title = title.left(21) + "…"
		var line := "%s %s %s" % [tstr, icon, title]
		if _font:
			var ink := Color("#3e2723") if not pending else Color("#e65100")
			draw_string(_font, card.position + Vector2(15, 15), line, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ink)
		y += CARD_H + CARD_GAP
	if pins.is_empty() and _font:
		draw_string(_font, Vector2(PAD + 6, y + 14), "(no notices yet)", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color("#5d4037"))
	if _font:
		draw_string(_font, Vector2(PAD + 2, size.y - 8), "drag title · click · /notices", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("#4e342e"))


func open_full_list() -> void:
	open_requested.emit()
	if _panel and is_instance_valid(_panel):
		_refresh_panel()
		_popup_away_from_terminal()
		return
	var win := Window.new()
	win.title = "Notice Board — important events"
	win.size = Vector2i(480, 420)
	win.unresizable = false
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	var vbox := VBoxContainer.new()
	var hint := Label.new()
	hint.text = "Newest first · hire / fire / knowledge / meetings / ask-human / tasks · excludes chatter"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	vbox.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(440, 300)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.custom_minimum_size = Vector2(420, 20)
	scroll.add_child(rtl)
	vbox.add_child(scroll)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func() -> void: win.hide())
	vbox.add_child(close_btn)
	margin.add_child(vbox)
	win.add_child(margin)
	add_child(win)
	_panel = win
	_list = rtl
	win.close_requested.connect(func() -> void: win.hide())
	_refresh_panel()
	_popup_away_from_terminal()


## Prefer left / centre-left so the right-side terminal drawer stays readable.
func _popup_away_from_terminal() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	var vp := get_viewport().get_visible_rect().size
	var win_size := Vector2(_panel.size)
	# Sit on the left half, vertically centred — clear of the 470px right drawer.
	var x := clampf(MARGIN * 2.0, MARGIN, maxf(MARGIN, vp.x * 0.5 - win_size.x * 0.5))
	var y := clampf((vp.y - win_size.y) * 0.5, TOP_UI, maxf(TOP_UI, vp.y - win_size.y - MARGIN))
	_panel.position = Vector2i(int(x), int(y))
	_panel.popup()


func _refresh_panel() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	_list.clear()
	if store == null:
		_list.append_text("[i]No notice store.[/i]")
		return
	var all_events: Array = store.events
	if all_events.is_empty():
		_list.append_text("[i]No important events yet.[/i]")
		return
	for e in all_events:
		if not (e is Dictionary):
			continue
		var col := str(e.get("color", "#b0bec5"))
		var tstr: String = str(store.format_time(float(e.get("ts", 0)))) if store.has_method("format_time") else ""
		var icon := str(e.get("icon", "•"))
		var title := str(e.get("title", ""))
		var detail := str(e.get("detail", ""))
		var pending := bool(e.get("pending", false))
		var mark := " [color=#ff9800][b]OPEN[/b][/color]" if pending else ""
		_list.append_text("[color=%s]%s %s[/color] [b]%s[/b]%s\n" % [col, tstr, icon, title, mark])
		if detail != "":
			_list.append_text("    [color=#90a4ae]%s[/color]\n" % detail)
