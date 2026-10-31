## Screen-space Notice Board HUD: fixed top-right panel (CanvasLayer/HUD child).
## Pins the latest important events; click opens the full scrollable list.
## Does not touch walkmesh, doors, or the world layout.
extends Control

signal open_requested

const NoticesScript := preload("res://Notices.gd")

const PANEL_W := 360.0
const MARGIN_RIGHT := 12.0
const MARGIN_TOP := 54.0  ## below the 46px TopBar + small gap
const HEADER_H := 28.0
const CARD_H := 30.0
const CARD_GAP := 3.0
const FOOTER_H := 22.0
const PAD := 10.0

var store: RefCounted = null  ## Notices
var _font: Font
var _panel: Window = null
var _list: RichTextLabel = null


func setup(notices: RefCounted) -> void:
	store = notices
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_anchor_top_right()
	if store and store.has_signal("changed") and not store.changed.is_connected(_on_store_changed):
		store.changed.connect(_on_store_changed)
	queue_redraw()
	tooltip_text = "Notice Board — click for all · /notices"


func _anchor_top_right() -> void:
	var pins := NoticesScript.BOARD_PIN_COUNT
	var body_h := float(pins) * (CARD_H + CARD_GAP) - CARD_GAP
	var total_h := PAD + HEADER_H + 6.0 + body_h + FOOTER_H + PAD
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -(PANEL_W + MARGIN_RIGHT)
	offset_top = MARGIN_TOP
	offset_right = -MARGIN_RIGHT
	offset_bottom = MARGIN_TOP + total_h
	custom_minimum_size = Vector2(PANEL_W, total_h)
	size = Vector2(PANEL_W, total_h)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		open_full_list()
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		modulate = Color(1.06, 1.06, 1.04, 1.0)
	elif what == NOTIFICATION_MOUSE_EXIT:
		modulate = Color.WHITE


func _on_store_changed() -> void:
	queue_redraw()
	if _panel and is_instance_valid(_panel) and _panel.visible:
		_refresh_panel()


func _draw() -> void:
	var box := Rect2(Vector2.ZERO, size)
	# Drop shadow
	draw_rect(Rect2(box.position + Vector2(3, 4), box.size), Color(0, 0, 0, 0.28))
	# Cork frame
	draw_rect(box, Color("#5d4037"))
	draw_rect(box.grow(-3), Color("#a1887f"))
	draw_rect(box.grow(-5), Color("#bcaaa4"))
	# Header strip
	var header := Rect2(PAD, PAD, size.x - PAD * 2.0, HEADER_H)
	draw_rect(header, Color("#4e342e"))
	if _font:
		draw_string(_font, header.position + Vector2(10, 20), "NOTICE BOARD", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#fff8e1"))
		draw_string(_font, Vector2(header.end.x - 52, header.position.y + 19), "latest", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#d7ccc8"))
	# Pins
	var pins: Array = store.latest(NoticesScript.BOARD_PIN_COUNT) if store else []
	var y := header.end.y + 6.0
	for i in pins.size():
		var e: Dictionary = pins[i]
		var card := Rect2(PAD, y, size.x - PAD * 2.0, CARD_H)
		var col := Color(str(e.get("color", "#b0bec5")))
		var pending := bool(e.get("pending", false))
		var bg := Color("#efebe9") if not pending else Color("#fff3e0")
		draw_rect(card, bg)
		draw_rect(Rect2(card.position.x, card.position.y, 4, card.size.y), col)
		draw_circle(Vector2(card.position.x + 12, card.position.y + 8), 2.4, col)
		var tstr: String = ""
		if store and store.has_method("format_time"):
			tstr = str(store.format_time(float(e.get("ts", 0))))
		var icon := str(e.get("icon", "•"))
		var title := str(e.get("title", ""))
		# Fit roughly to panel width (~28 chars at 12px in 360w)
		if title.length() > 28:
			title = title.left(27) + "…"
		var line := "%s  %s  %s" % [tstr, icon, title]
		if _font:
			var ink := Color("#3e2723") if not pending else Color("#e65100")
			draw_string(_font, card.position + Vector2(20, 20), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
		y += CARD_H + CARD_GAP
	if pins.is_empty() and _font:
		draw_string(_font, Vector2(PAD + 8, y + 18), "(no notices yet)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#5d4037"))
	# Footer hint
	if _font:
		draw_string(_font, Vector2(PAD + 4, size.y - 10), "click for all  ·  /notices", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#4e342e"))


func open_full_list() -> void:
	open_requested.emit()
	if _panel and is_instance_valid(_panel):
		_refresh_panel()
		_panel.popup_centered()
		return
	var win := Window.new()
	win.title = "Notice Board — important events"
	win.size = Vector2i(520, 480)
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
	scroll.custom_minimum_size = Vector2(480, 360)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.custom_minimum_size = Vector2(460, 20)
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
	win.popup_centered()


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
