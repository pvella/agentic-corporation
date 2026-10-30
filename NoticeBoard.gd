## Cork notice board on the canteen / hub wall. Pins short event cards;
## click opens a scrollable full list. Does not touch walkmesh or doors.
extends Node2D

signal open_requested

const Iso := preload("res://Iso.gd")
const NoticesScript := preload("res://Notices.gd")

var store: RefCounted = null  ## Notices
var _font: Font
var _box := Rect2(-70, -118, 140, 110)  ## local placard (billboarded)
var _area: Area2D
var _panel: Window = null
var _list: RichTextLabel = null


func setup(anchor_world: Vector2, notices: RefCounted) -> void:
	store = notices
	position = Iso.to_screen(anchor_world) if Iso.enabled else anchor_world
	z_index = 28
	_font = ThemeDB.fallback_font
	if store and store.has_signal("changed") and not store.changed.is_connected(_on_store_changed):
		store.changed.connect(_on_store_changed)
	_ensure_area()
	queue_redraw()


func _ensure_area() -> void:
	if _area and is_instance_valid(_area):
		return
	_area = Area2D.new()
	_area.collision_layer = 8
	_area.collision_mask = 0
	_area.input_pickable = true
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = _box.size
	shape.shape = rect
	shape.position = _box.get_center()
	_area.add_child(shape)
	add_child(_area)
	_area.input_event.connect(_on_area_input)
	_area.mouse_entered.connect(func() -> void: modulate = Color(1.08, 1.08, 1.05, 1.0))
	_area.mouse_exited.connect(func() -> void: modulate = Color.WHITE)


func _on_area_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		open_full_list()
		get_viewport().set_input_as_handled()


func _on_store_changed() -> void:
	queue_redraw()
	if _panel and is_instance_valid(_panel) and _panel.visible:
		_refresh_panel()


func _draw() -> void:
	# Cork board frame
	var shadow := _box.grow(3)
	draw_rect(shadow, Color(0, 0, 0, 0.25))
	draw_rect(_box, Color("#6d4c41"))
	draw_rect(_box.grow(-3), Color("#a1887f"))
	# Header strip
	var header := Rect2(_box.position.x + 4, _box.position.y + 4, _box.size.x - 8, 16)
	draw_rect(header, Color("#5d4037"))
	if _font:
		draw_string(_font, header.position + Vector2(6, 12), "NOTICE BOARD", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#fff8e1"))
	# Pins
	var pins: Array = store.latest(NoticesScript.BOARD_PIN_COUNT) if store else []
	var y := header.end.y + 4.0
	var card_h := 12.0
	var gap := 1.5
	for i in pins.size():
		var e: Dictionary = pins[i]
		var card := Rect2(_box.position.x + 5, y, _box.size.x - 10, card_h)
		var col := Color(str(e.get("color", "#b0bec5")))
		var pending := bool(e.get("pending", false))
		var bg := Color("#efebe9") if not pending else Color("#fff3e0")
		draw_rect(card, bg)
		draw_rect(Rect2(card.position.x, card.position.y, 3, card.size.y), col)
		# pin dot
		draw_circle(Vector2(card.position.x + 8, card.position.y + 3), 1.6, col)
		var tstr: String = ""
		if store and store.has_method("format_time"):
			tstr = str(store.format_time(float(e.get("ts", 0))))
		var icon := str(e.get("icon", "•"))
		var title := str(e.get("title", "")).left(22)
		var line := "%s %s %s" % [tstr, icon, title]
		if _font:
			var ink := Color("#3e2723") if not pending else Color("#e65100")
			draw_string(_font, card.position + Vector2(12, 10), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, ink)
		y += card_h + gap
	if pins.is_empty() and _font:
		draw_string(_font, Vector2(_box.position.x + 10, y + 14), "(no notices yet)", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("#5d4037"))
	# Footer hint
	if _font:
		draw_string(_font, Vector2(_box.position.x + 8, _box.end.y - 6), "click for all · /notices", HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color("#4e342e"))


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
