## Server Room knowledge library — list / preview / remove shared .md files.
extends CanvasLayer

signal closed
signal remove_requested(filename: String)
signal refresh_requested

var _files: Array = []
var _root: Control
var _dim: ColorRect
var _panel: PanelContainer
var _list: VBoxContainer
var _status: Label
var _preview: Window


func open_with(files: Array) -> void:
	_files = files.duplicate()
	if _root == null:
		_build()
	_root.visible = true
	_rebuild()


func set_files(files: Array) -> void:
	_files = files.duplicate()
	if _list != null:
		_rebuild()


func _build() -> void:
	layer = 66
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.05, 0.09, 0.65)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			close()
	)
	_root.add_child(_dim)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#121a24")
	style.border_color = Color("#26a69a")
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.5)
	style.shadow_size = 16
	style.shadow_offset = Vector2(0, 6)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)
	_panel.resized.connect(_fit)
	call_deferred("_fit")

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	_panel.add_child(outer)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	outer.add_child(header)
	var title := Label.new()
	title.text = "SERVER ROOM · KNOWLEDGE"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("#80cbc4"))
	header.add_child(title)
	var sub := Label.new()
	sub.text = "  shared .md for every agent"
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color("#78909c"))
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sub)
	var refresh := Button.new()
	refresh.text = "↻"
	refresh.focus_mode = Control.FOCUS_NONE
	refresh.tooltip_text = "Refresh list"
	refresh.pressed.connect(func() -> void: refresh_requested.emit())
	header.add_child(refresh)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color("#90a4ae"))
	outer.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 360)
	outer.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)


func _fit() -> void:
	if _panel == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var w := minf(720.0, vp.x - 48.0)
	var h := minf(520.0, vp.y - 48.0)
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.size = Vector2(w, h)
	_panel.position = (vp - Vector2(w, h)) * 0.5


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	if _files.is_empty():
		_status.text = "No knowledge files yet — drop a .md onto the office window."
		var empty := Label.new()
		empty.text = "knowledge/ is empty"
		empty.add_theme_color_override("font_color", Color("#607d8b"))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(empty)
		return
	_status.text = "%d file%s in knowledge/" % [_files.size(), "" if _files.size() == 1 else "s"]
	for f in _files:
		if not (f is Dictionary):
			continue
		_list.add_child(_row(f))


func _row(f: Dictionary) -> Control:
	var name := str(f.get("name", f.get("filename", "?")))
	var title := str(f.get("title", name))
	var size_b := int(f.get("size", 0))
	var mtime := float(f.get("mtime", f.get("added", 0.0)))
	var row := PanelContainer.new()
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color("#1a2330")
	rs.set_corner_radius_all(8)
	rs.content_margin_left = 12
	rs.content_margin_right = 10
	rs.content_margin_top = 8
	rs.content_margin_bottom = 8
	rs.border_color = Color("#263238")
	rs.set_border_width_all(1)
	row.add_theme_stylebox_override("panel", rs)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	row.add_child(hb)
	var icon := Label.new()
	icon.text = "📄"
	icon.add_theme_font_size_override("font_size", 18)
	hb.add_child(icon)
	var meta := VBoxContainer.new()
	meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(meta)
	var nlab := Label.new()
	nlab.text = title if title != "" else name
	nlab.add_theme_font_size_override("font_size", 14)
	nlab.add_theme_color_override("font_color", Color("#e0f2f1"))
	meta.add_child(nlab)
	var detail := Label.new()
	detail.text = "%s · %s · added %s" % [name, _fmt_size(size_b), _fmt_date(mtime)]
	detail.add_theme_font_size_override("font_size", 11)
	detail.add_theme_color_override("font_color", Color("#78909c"))
	meta.add_child(detail)
	var view_btn := Button.new()
	view_btn.text = "View"
	view_btn.focus_mode = Control.FOCUS_NONE
	view_btn.pressed.connect(func() -> void: _show_preview(f))
	hb.add_child(view_btn)
	var rm_btn := Button.new()
	rm_btn.text = "Remove"
	rm_btn.focus_mode = Control.FOCUS_NONE
	rm_btn.modulate = Color("#ef9a9a")
	var snap := name
	rm_btn.pressed.connect(func() -> void: _confirm_remove(snap, title))
	hb.add_child(rm_btn)
	return row


func _fmt_size(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (n / 1024.0)
	return "%.2f MB" % (n / (1024.0 * 1024.0))


func _fmt_date(ts: float) -> String:
	if ts <= 0.0:
		return "?"
	var d := Time.get_datetime_dict_from_unix_time(int(ts))
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


func _show_preview(f: Dictionary) -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = Window.new()
	_preview.title = str(f.get("name", "preview"))
	_preview.size = Vector2i(640, 520)
	_preview.transient = true
	_preview.exclusive = false
	_preview.close_requested.connect(func() -> void:
		if _preview:
			_preview.queue_free()
			_preview = null
	)
	add_child(_preview)
	var wrap := MarginContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("margin_left", 12)
	wrap.add_theme_constant_override("margin_right", 12)
	wrap.add_theme_constant_override("margin_top", 10)
	wrap.add_theme_constant_override("margin_bottom", 10)
	_preview.add_child(wrap)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = false
	rtl.fit_content = false
	rtl.scroll_active = true
	rtl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var body := str(f.get("content", ""))
	if body == "":
		var path := str(f.get("path", ""))
		if path != "" and FileAccess.file_exists(path):
			var fh := FileAccess.open(path, FileAccess.READ)
			if fh:
				body = fh.get_as_text()
				fh.close()
		if body == "":
			body = "(empty or unreadable — path: %s)" % path
	rtl.text = body
	wrap.add_child(rtl)
	_preview.popup_centered()


func _confirm_remove(filename: String, title: String) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Remove knowledge"
	dlg.dialog_text = "Delete \"%s\" from the Server Room?\nAgents will stop using it." % (title if title != "" else filename)
	dlg.exclusive = false
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		remove_requested.emit(filename)
		dlg.queue_free()
	)
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.close_requested.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered()


func close() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
		_preview = null
	closed.emit()
	queue_free()
