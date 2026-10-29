## Hiring Board — pixel-office recruitment panel.
## Opened by Main (+ Add Agent). Category sidebar, search, role cards,
## job-description sheet, Customise form. Same sheet used for View JD.
extends CanvasLayer

signal hire_requested(role: Dictionary, overrides: Dictionary)
signal closed

const CARD_W := 200
const CARD_H := 118

var _catalog: Array = []
var _categories: Array = []
var _filter_cat := ""
var _filter_q := ""

var _root: Control
var _dim: ColorRect
var _panel: PanelContainer
var _sidebar: VBoxContainer
var _search: LineEdit
var _grid: GridContainer
var _status: Label
var _sheet: Window
var _custom: Window
var _fonts_ready := false
var _heading_font: Font
var _body_font: Font

func setup(catalog_roles: Array, categories: Array = []) -> void:
	_catalog = catalog_roles.duplicate()
	_categories = categories.duplicate()
	if _categories.is_empty():
		var seen := {}
		for r in _catalog:
			var c := str(r.get("category", r.get("department", "Other")))
			if not seen.has(c):
				seen[c] = true
				_categories.append(c)
	_ensure_fonts()
	_build()
	_rebuild_grid()


func open_for_role(role: Dictionary) -> void:
	# Direct JD sheet (e.g. View job description on an existing agent).
	_ensure_fonts()
	if _root == null:
		_build()
		_root.visible = false
	_show_sheet(role, false)


func _ensure_fonts() -> void:
	if _fonts_ready:
		return
	_heading_font = ThemeDB.fallback_font
	_body_font = ThemeDB.fallback_font
	_fonts_ready = true


func _build() -> void:
	layer = 64
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.04, 0.08, 0.62)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			close()
	)
	_root.add_child(_dim)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(920, 560)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#1b2430")
	style.border_color = Color("#3d4f63")
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 18
	style.shadow_offset = Vector2(0, 6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)
	_panel.resized.connect(_fit_panel)
	call_deferred("_fit_panel")

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	_panel.add_child(outer)

	# Header
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	outer.add_child(header)
	var title := Label.new()
	title.text = "HIRING BOARD"
	title.add_theme_font_override("font", _heading_font)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("#ffe082"))
	header.add_child(title)
	var sub := Label.new()
	sub.text = "  ·  pick a role · drag knowledge later · light-beam hire"
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color("#90a4ae"))
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sub)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_search = LineEdit.new()
	_search.placeholder_text = "Search title, department, purpose…"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(t: String) -> void:
		_filter_q = t.strip_edges().to_lower()
		_rebuild_grid()
	)
	outer.add_child(_search)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	outer.add_child(body)

	# Sidebar categories
	var side_wrap := PanelContainer.new()
	side_wrap.custom_minimum_size = Vector2(200, 0)
	var side_style := StyleBoxFlat.new()
	side_style.bg_color = Color("#121820")
	side_style.set_corner_radius_all(8)
	side_style.content_margin_left = 8
	side_style.content_margin_right = 8
	side_style.content_margin_top = 8
	side_style.content_margin_bottom = 8
	side_wrap.add_theme_stylebox_override("panel", side_style)
	body.add_child(side_wrap)
	var side_scroll := ScrollContainer.new()
	side_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side_wrap.add_child(side_scroll)
	_sidebar = VBoxContainer.new()
	_sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sidebar.add_theme_constant_override("separation", 4)
	side_scroll.add_child(_sidebar)
	_rebuild_sidebar()

	# Cards grid
	var grid_wrap := PanelContainer.new()
	grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var gw_style := StyleBoxFlat.new()
	gw_style.bg_color = Color("#141c26")
	gw_style.set_corner_radius_all(8)
	gw_style.content_margin_left = 10
	gw_style.content_margin_right = 10
	gw_style.content_margin_top = 10
	gw_style.content_margin_bottom = 10
	grid_wrap.add_theme_stylebox_override("panel", gw_style)
	body.add_child(grid_wrap)
	var gscroll := ScrollContainer.new()
	gscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_wrap.add_child(gscroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	gscroll.add_child(_grid)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color("#78909c"))
	outer.add_child(_status)

	# Custom hire shortcut
	var foot := HBoxContainer.new()
	outer.add_child(foot)
	var custom_btn := Button.new()
	custom_btn.text = "＋ Customise blank role"
	custom_btn.focus_mode = Control.FOCUS_NONE
	custom_btn.pressed.connect(func() -> void: _open_customise({}))
	foot.add_child(custom_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	var count := Label.new()
	count.text = "%d roles in catalogue" % _catalog.size()
	count.add_theme_color_override("font_color", Color("#90a4ae"))
	foot.add_child(count)


func _fit_panel() -> void:
	if _panel == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var w := minf(960.0, vp.x - 40.0)
	var h := minf(620.0, vp.y - 40.0)
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.size = Vector2(w, h)
	_panel.position = (vp - _panel.size) * 0.5
	var cols := 3
	if w < 780:
		cols = 2
	if w < 560:
		cols = 1
	if _grid:
		_grid.columns = cols


func _rebuild_sidebar() -> void:
	for c in _sidebar.get_children():
		c.queue_free()
	_add_cat_btn("All roles", "")
	for cat in _categories:
		_add_cat_btn(str(cat), str(cat))


func _add_cat_btn(label: String, cat_id: String) -> void:
	var b := Button.new()
	b.text = label
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var active := _filter_cat == cat_id
	b.modulate = Color("#ffe082") if active else Color.WHITE
	b.pressed.connect(func() -> void:
		_filter_cat = cat_id
		_rebuild_sidebar()
		_rebuild_grid()
	)
	_sidebar.add_child(b)


func _rebuild_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()
	var n := 0
	for role in _catalog:
		if not (role is Dictionary):
			continue
		var cat := str(role.get("category", role.get("department", "")))
		if _filter_cat != "" and cat != _filter_cat:
			continue
		if _filter_q != "":
			var blob := ("%s %s %s %s" % [
				role.get("title", ""), cat,
				role.get("summary", ""), role.get("purpose", "")
			]).to_lower()
			if _filter_q not in blob:
				continue
		_grid.add_child(_make_card(role))
		n += 1
	_status.text = "%d shown · filter “%s” · search “%s”" % [n, _filter_cat if _filter_cat else "all", _filter_q]


func _make_card(role: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var col := Color.from_string(str(role.get("color", "#90a4ae")), Color("#90a4ae"))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("#1e2a38")
	normal.border_color = col.darkened(0.25)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(8)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	var hover := normal.duplicate()
	hover.bg_color = Color("#263446")
	hover.border_color = col
	hover.shadow_color = Color(col, 0.35)
	hover.shadow_size = 8
	card.add_theme_stylebox_override("panel", normal)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	var avatar := PanelContainer.new()
	avatar.custom_minimum_size = Vector2(36, 36)
	var avs := StyleBoxFlat.new()
	avs.bg_color = col
	avs.set_corner_radius_all(6)
	avatar.add_theme_stylebox_override("panel", avs)
	top.add_child(avatar)
	var face := Label.new()
	face.text = "♟"
	face.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	face.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	face.add_theme_font_size_override("font_size", 18)
	face.add_theme_color_override("font_color", Color(0, 0, 0, 0.7))
	avatar.add_child(face)

	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(titles)
	var t := Label.new()
	t.text = str(role.get("title", "Role"))
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.add_theme_font_override("font", _heading_font)
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_color", Color("#eceff1"))
	titles.add_child(t)
	var chip := Label.new()
	chip.text = "  " + str(role.get("department", role.get("category", ""))) + "  "
	chip.add_theme_font_size_override("font_size", 10)
	chip.add_theme_color_override("font_color", Color.WHITE)
	var chip_bg := StyleBoxFlat.new()
	chip_bg.bg_color = col.darkened(0.15)
	chip_bg.set_corner_radius_all(6)
	chip_bg.content_margin_left = 4
	chip_bg.content_margin_right = 4
	chip.add_theme_stylebox_override("normal", chip_bg)
	titles.add_child(chip)

	var summary := Label.new()
	summary.text = str(role.get("summary", role.get("purpose", ""))).left(110)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_theme_font_override("font", _body_font)
	summary.add_theme_font_size_override("font_size", 11)
	summary.add_theme_color_override("font_color", Color("#b0bec5"))
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(summary)

	card.mouse_entered.connect(func() -> void:
		card.add_theme_stylebox_override("panel", hover)
	)
	card.mouse_exited.connect(func() -> void:
		card.add_theme_stylebox_override("panel", normal)
	)
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_show_sheet(role, true)
	)
	return card


func _show_sheet(role: Dictionary, from_board: bool) -> void:
	if _sheet != null and is_instance_valid(_sheet):
		_sheet.queue_free()
	_sheet = Window.new()
	_sheet.title = "Job description"
	_sheet.size = Vector2i(640, 520)
	_sheet.unresizable = false
	_sheet.transient = true
	_sheet.exclusive = true
	_sheet.close_requested.connect(func() -> void:
		_sheet.queue_free()
		_sheet = null
	)
	add_child(_sheet)

	var wrap := MarginContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("margin_left", 14)
	wrap.add_theme_constant_override("margin_right", 14)
	wrap.add_theme_constant_override("margin_top", 10)
	wrap.add_theme_constant_override("margin_bottom", 10)
	_sheet.add_child(wrap)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	wrap.add_child(v)

	var col := Color.from_string(str(role.get("color", "#90a4ae")), Color("#90a4ae"))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	var av := PanelContainer.new()
	av.custom_minimum_size = Vector2(56, 56)
	var avs2 := StyleBoxFlat.new()
	avs2.bg_color = col
	avs2.set_corner_radius_all(8)
	av.add_theme_stylebox_override("panel", avs2)
	head.add_child(av)
	var face2 := Label.new()
	face2.text = "♟"
	face2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	face2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	face2.add_theme_font_size_override("font_size", 26)
	av.add_child(face2)
	var ht := VBoxContainer.new()
	ht.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(ht)
	var title := Label.new()
	title.text = str(role.get("title", ""))
	title.add_theme_font_override("font", _heading_font)
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("#ffe082"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ht.add_child(title)
	var badge := Label.new()
	badge.text = str(role.get("department", role.get("category", "")))
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override("font_color", col.lightened(0.25))
	ht.add_child(badge)
	var meta := Label.new()
	meta.text = "Room: %s  ·  Reports to: %s" % [role.get("room", ""), role.get("reports_to", "")]
	meta.add_theme_font_size_override("font_size", 11)
	meta.add_theme_color_override("font_color", Color("#90a4ae"))
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ht.add_child(meta)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_font_override("normal_font", _body_font)
	body.add_theme_font_size_override("normal_font_size", 13)
	body.text = _role_bbcode(role)
	scroll.add_child(body)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	v.add_child(foot)
	var close_b := Button.new()
	close_b.text = "Close"
	close_b.focus_mode = Control.FOCUS_NONE
	close_b.pressed.connect(func() -> void:
		_sheet.queue_free()
		_sheet = null
	)
	foot.add_child(close_b)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	if from_board:
		var custom_b := Button.new()
		custom_b.text = "Customise"
		custom_b.focus_mode = Control.FOCUS_NONE
		custom_b.pressed.connect(func() -> void:
			var snap: Dictionary = role.duplicate(true)
			_sheet.queue_free()
			_sheet = null
			_open_customise(snap)
		)
		foot.add_child(custom_b)
		var hire_b := Button.new()
		hire_b.text = "Hire"
		hire_b.focus_mode = Control.FOCUS_NONE
		var hs := StyleBoxFlat.new()
		hs.bg_color = Color("#43a047")
		hs.set_corner_radius_all(6)
		hs.content_margin_left = 16
		hs.content_margin_right = 16
		hs.content_margin_top = 8
		hs.content_margin_bottom = 8
		hire_b.add_theme_stylebox_override("normal", hs)
		hire_b.add_theme_color_override("font_color", Color.WHITE)
		hire_b.pressed.connect(func() -> void:
			hire_requested.emit(role, {})
			_sheet.queue_free()
			_sheet = null
			close()
		)
		foot.add_child(hire_b)

	_sheet.popup_centered()


func _role_bbcode(role: Dictionary) -> String:
	var chunks: PackedStringArray = []
	var full := str(role.get("full_description", ""))
	if full != "":
		# Prefer verbatim full_description; light markdown→bbcode.
		chunks.append(_md_to_bbcode(full))
		return "\n".join(chunks)
	# Fallback structured
	_add_sec(chunks, "Purpose", str(role.get("purpose", "")))
	var resp: Array = role.get("responsibilities", [])
	if resp is Array and not resp.is_empty():
		var lines: PackedStringArray = []
		for item in resp:
			lines.append("• " + str(item))
		_add_sec(chunks, "Responsibilities", "\n".join(lines))
	_add_sec(chunks, "Tools", str(role.get("tools_text", "")))
	_add_sec(chunks, "Reports to", str(role.get("reports_to", "")))
	_add_sec(chunks, "Outputs and cadence", str(role.get("outputs_and_cadence", "")))
	_add_sec(chunks, "Decision rights", str(role.get("decision_rights", "")))
	return "\n\n".join(chunks)


func _add_sec(chunks: PackedStringArray, title: String, body: String) -> void:
	if body.strip_edges() == "":
		return
	chunks.append("[color=#ffe082][b]%s[/b][/color]\n%s" % [title, body])


func _md_to_bbcode(md: String) -> String:
	var s := md
	s = s.replace("&", "&amp;")
	s = s.replace("[", "[lb]")
	# headings
	s = regsub(s, r'(?m)^###\s+(.+)$', "[color=#ffe082][b][font_size=16]$1[/font_size][/b][/color]")
	s = regsub(s, r'(?m)^##\s+(.+)$', "[color=#ffe082][b][font_size=17]$1[/font_size][/b][/color]")
	# bold labels
	s = regsub(s, r'\*\*([^*]+)\*\*', "[b][color=#90caf9]$1[/color][/b]")
	# bullets
	s = regsub(s, r'(?m)^-\s+', "• ")
	s = s.replace("[lb]", "[lb]")  # keep
	# undo bracket escape for bbcode we inserted — actually we escaped [ to [lb]
	# Restore only our tags by not escaping — redo simpler:
	return _md_to_bbcode2(md)


func _md_to_bbcode2(md: String) -> String:
	var lines := md.split("\n")
	var out: PackedStringArray = []
	for line in lines:
		var l := line
		if l.begins_with("### "):
			out.append("[color=#ffe082][b]%s[/b][/color]" % l.substr(4))
			continue
		if l.begins_with("## "):
			out.append("[color=#ffe082][b]%s[/b][/color]" % l.substr(3))
			continue
		if l.begins_with("- "):
			l = "• " + l.substr(2)
		# bold
		var rebuilt := ""
		var i := 0
		while i < l.length():
			if i + 1 < l.length() and l[i] == "*" and l[i+1] == "*":
				var j := l.find("**", i + 2)
				if j != -1:
					rebuilt += "[b][color=#90caf9]" + l.substr(i + 2, j - (i + 2)) + "[/color][/b]"
					i = j + 2
					continue
			rebuilt += l[i]
			i += 1
		out.append(rebuilt)
	return "\n".join(out)


func regsub(text: String, pattern: String, replacement: String) -> String:
	# unused helper kept for clarity
	return text


func _open_customise(role: Dictionary) -> void:
	if _custom != null and is_instance_valid(_custom):
		_custom.queue_free()
	_custom = Window.new()
	_custom.title = "Customise hire"
	_custom.size = Vector2i(520, 560)
	_custom.transient = true
	_custom.exclusive = true
	_custom.close_requested.connect(func() -> void:
		_custom.queue_free()
		_custom = null
	)
	add_child(_custom)
	var wrap := MarginContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("margin_left", 12)
	wrap.add_theme_constant_override("margin_right", 12)
	wrap.add_theme_constant_override("margin_top", 10)
	wrap.add_theme_constant_override("margin_bottom", 10)
	_custom.add_child(wrap)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	wrap.add_child(v)

	var name_e := LineEdit.new()
	name_e.placeholder_text = "Display name"
	name_e.text = str(role.get("default_name", role.get("title", "")))
	v.add_child(name_e)
	var title_e := LineEdit.new()
	title_e.placeholder_text = "Job title"
	title_e.text = str(role.get("title", ""))
	v.add_child(title_e)
	var dept_e := LineEdit.new()
	dept_e.placeholder_text = "Department / category"
	dept_e.text = str(role.get("department", role.get("category", "")))
	v.add_child(dept_e)
	var room_e := LineEdit.new()
	room_e.placeholder_text = "Room id"
	room_e.text = str(role.get("room", "special_projects"))
	v.add_child(room_e)
	var reports_e := LineEdit.new()
	reports_e.placeholder_text = "Reports to"
	reports_e.text = str(role.get("reports_to", ""))
	v.add_child(reports_e)
	var repos_e := LineEdit.new()
	repos_e.placeholder_text = "Default repo (e.g. .)"
	var repos_val: Array = role.get("repos", ["."])
	repos_e.text = str(repos_val[0]) if repos_val.size() > 0 else "."
	v.add_child(repos_e)
	var purpose_e := TextEdit.new()
	purpose_e.custom_minimum_size = Vector2(0, 90)
	purpose_e.placeholder_text = "Purpose"
	purpose_e.text = str(role.get("purpose", ""))
	v.add_child(purpose_e)
	var desc_e := TextEdit.new()
	desc_e.custom_minimum_size = Vector2(0, 180)
	desc_e.placeholder_text = "Full job description (markdown, kept verbatim)"
	desc_e.text = str(role.get("full_description", ""))
	desc_e.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(desc_e)

	var foot := HBoxContainer.new()
	v.add_child(foot)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void:
		_custom.queue_free()
		_custom = null
	)
	foot.add_child(cancel)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
	var save := Button.new()
	save.text = "Save & Hire"
	var hs := StyleBoxFlat.new()
	hs.bg_color = Color("#43a047")
	hs.set_corner_radius_all(6)
	hs.content_margin_left = 14
	hs.content_margin_right = 14
	hs.content_margin_top = 8
	hs.content_margin_bottom = 8
	save.add_theme_stylebox_override("normal", hs)
	save.add_theme_color_override("font_color", Color.WHITE)
	save.pressed.connect(func() -> void:
		var overrides := {
			"default_name": name_e.text.strip_edges(),
			"title": title_e.text.strip_edges(),
			"department": dept_e.text.strip_edges(),
			"category": dept_e.text.strip_edges(),
			"room": room_e.text.strip_edges(),
			"reports_to": reports_e.text.strip_edges(),
			"purpose": purpose_e.text.strip_edges(),
			"full_description": desc_e.text,
			"repos": [repos_e.text.strip_edges() if repos_e.text.strip_edges() != "" else "."],
		}
		var base: Dictionary = role.duplicate(true) if not role.is_empty() else {
			"id": "custom",
			"responsibilities": [],
			"tools": [],
			"tools_text": "",
			"color": "#90a4ae",
			"summary": purpose_e.text.strip_edges().left(120),
		}
		base.merge(overrides, true)
		hire_requested.emit(base, overrides)
		_custom.queue_free()
		_custom = null
		close()
	)
	foot.add_child(save)
	_custom.popup_centered()


func close() -> void:
	if _sheet != null and is_instance_valid(_sheet):
		_sheet.queue_free()
		_sheet = null
	if _custom != null and is_instance_valid(_custom):
		_custom.queue_free()
		_custom = null
	closed.emit()
	queue_free()
