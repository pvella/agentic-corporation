extends Window
## Office Vault management UI. Values are NEVER shown or copyable.

signal add_secret(name: String, description: String, value: String)
signal set_agents(name: String, agents: Variant)  # Array or "all"
signal remove_secret(name: String)
signal lock_now
signal activity

var _roster: Array = []  # agent_id strings
var _secrets: Array = []
var _scroll: ScrollContainer
var _list: VBoxContainer
var _name_edit: LineEdit
var _desc_edit: LineEdit
var _val_edit: LineEdit
var _status: Label
var _idle_timer: Timer


func _ready() -> void:
	title = "Office Vault"
	size = Vector2i(780, 520)
	unresizable = false
	close_requested.connect(_on_close)
	_build()
	_idle_timer = Timer.new()
	_idle_timer.wait_time = 120.0
	_idle_timer.one_shot = true
	_idle_timer.timeout.connect(func() -> void: lock_now.emit())
	add_child(_idle_timer)
	_idle_timer.start()


func _on_close() -> void:
	lock_now.emit()
	queue_free()


func _bump_idle() -> void:
	activity.emit()
	if _idle_timer:
		_idle_timer.start()


func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for s in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(s, 10)
	margin.add_child(root)
	add_child(margin)

	var hdr := HBoxContainer.new()
	var title_l := Label.new()
	title_l.text = "Secrets (values stay in the OS keychain — never shown)"
	title_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(title_l)
	var lock_btn := Button.new()
	lock_btn.text = "Lock now"
	lock_btn.pressed.connect(func() -> void:
		_bump_idle()
		lock_now.emit()
	)
	hdr.add_child(lock_btn)
	root.add_child(hdr)

	_status = Label.new()
	_status.text = ""
	root.add_child(_status)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(0, 280)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	root.add_child(_scroll)

	var add_box := VBoxContainer.new()
	var add_lbl := Label.new()
	add_lbl.text = "Add secret"
	add_box.add_child(add_lbl)
	var row := HBoxContainer.new()
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "NAME (env var)"
	_name_edit.custom_minimum_size = Vector2(140, 0)
	_desc_edit = LineEdit.new()
	_desc_edit.placeholder_text = "Description"
	_desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_val_edit = LineEdit.new()
	_val_edit.placeholder_text = "Value (masked)"
	_val_edit.secret = true
	_val_edit.secret_character = "•"
	_val_edit.custom_minimum_size = Vector2(160, 0)
	# Block copy of value
	_val_edit.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventKey and ev.pressed:
			if ev.keycode == KEY_C and ev.ctrl_pressed:
				_val_edit.accept_event()
	)
	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.pressed.connect(_on_add)
	row.add_child(_name_edit)
	row.add_child(_desc_edit)
	row.add_child(_val_edit)
	row.add_child(add_btn)
	add_box.add_child(row)
	root.add_child(add_box)


func configure(secrets: Array, roster: Array, locked: bool = false) -> void:
	_secrets = secrets
	_roster = roster
	if locked:
		_status.text = "Locked — names only. Unlock the safe to manage access."
	else:
		_status.text = "%d secret(s) · click agent boxes to grant/revoke · Lock after 2 min idle" % secrets.size()
	_rebuild_list(locked)
	# Reset idle only — never emit `activity` here: activity → VAULT_LIST →
	# VAULT_META → configure() was an infinite refresh loop.
	if _idle_timer:
		_idle_timer.start()


func _rebuild_list(locked: bool) -> void:
	for c in _list.get_children():
		c.queue_free()
	# Header
	var head := HBoxContainer.new()
	for t in ["Name", "Description", "Allowed agents", "Created", "Last used", ""]:
		var l := Label.new()
		l.text = t
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL if t in ["Description", "Allowed agents"] else Control.SIZE_FILL
		if t == "Name":
			l.custom_minimum_size = Vector2(110, 0)
		if t in ["Created", "Last used"]:
			l.custom_minimum_size = Vector2(90, 0)
		head.add_child(l)
	_list.add_child(head)

	if _secrets.is_empty():
		var empty := Label.new()
		empty.text = "No secrets yet. Add one below."
		empty.modulate = Color(1, 1, 1, 0.7)
		_list.add_child(empty)
		return
	for s in _secrets:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		_list.add_child(_row_for(s, locked))


func _fmt_ts(ts: float) -> String:
	if ts <= 0.0:
		return "—"
	var t := int(ts)
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


func _row_for(s: Dictionary, locked: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var sname := str(s.get("name", ""))

	var n := Label.new()
	n.text = sname
	n.custom_minimum_size = Vector2(110, 0)
	row.add_child(n)

	var d := Label.new()
	d.text = str(s.get("description", ""))
	d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(140, 0)
	row.add_child(d)

	var agents_box := HBoxContainer.new()
	agents_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agents_box.add_theme_constant_override("separation", 2)
	if locked:
		var only := Label.new()
		only.text = "(unlock to edit ACL)"
		agents_box.add_child(only)
	else:
		var agents = s.get("agents", [])
		var is_all := str(agents) == "all"
		var all_cb := CheckBox.new()
		all_cb.text = "all"
		all_cb.button_pressed = is_all
		all_cb.toggled.connect(func(on: bool) -> void:
			_bump_idle()
			if on:
				set_agents.emit(sname, "all")
			else:
				set_agents.emit(sname, [])
		)
		agents_box.add_child(all_cb)
		var wrap: Container
		if ClassDB.class_exists("HFlowContainer"):
			wrap = HFlowContainer.new()
		else:
			wrap = HBoxContainer.new()
		wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for aid in _roster:
			var id := str(aid)
			var cb := CheckBox.new()
			cb.text = id
			cb.disabled = is_all
			cb.button_pressed = is_all or (agents is Array and id in agents)
			cb.toggled.connect(func(on: bool) -> void:
				_bump_idle()
				var cur = s.get("agents", [])
				var lst: Array = []
				if str(cur) == "all":
					for a in _roster:
						lst.append(str(a))
				elif cur is Array:
					for a in cur:
						lst.append(str(a))
				if on and id not in lst:
					lst.append(id)
				elif not on:
					lst = lst.filter(func(x): return str(x) != id)
				set_agents.emit(sname, lst)
			)
			wrap.add_child(cb)
		agents_box.add_child(wrap)
	row.add_child(agents_box)

	var created := Label.new()
	created.text = _fmt_ts(float(s.get("created_at", 0))) if not locked else "—"
	created.custom_minimum_size = Vector2(90, 0)
	row.add_child(created)

	var used := Label.new()
	used.text = _fmt_ts(float(s.get("last_used_at", 0))) if not locked else "—"
	used.custom_minimum_size = Vector2(90, 0)
	row.add_child(used)

	var rm := Button.new()
	rm.text = "Remove"
	rm.disabled = locked
	rm.pressed.connect(func() -> void:
		_bump_idle()
		_confirm_remove(sname)
	)
	row.add_child(rm)
	return row


func _confirm_remove(sname: String) -> void:
	var win := Window.new()
	win.title = "Confirm removal"
	win.size = Vector2i(420, 140)
	var v := VBoxContainer.new()
	var lab := Label.new()
	lab.text = "Delete secret '%s' from the keychain? This cannot be undone." % sname
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(lab)
	var row := HBoxContainer.new()
	var yes := Button.new()
	yes.text = "Delete permanently"
	yes.pressed.connect(func() -> void:
		remove_secret.emit(sname)
		win.queue_free()
	)
	var no := Button.new()
	no.text = "Cancel"
	no.pressed.connect(func() -> void: win.queue_free())
	row.add_child(yes)
	row.add_child(no)
	v.add_child(row)
	win.add_child(v)
	add_child(win)
	win.close_requested.connect(func() -> void: win.queue_free())
	win.popup_centered()


func _on_add() -> void:
	_bump_idle()
	var n := _name_edit.text.strip_edges()
	var d := _desc_edit.text.strip_edges()
	var v := _val_edit.text
	_val_edit.text = ""
	if n == "" or v == "":
		_status.text = "Name and value required"
		return
	add_secret.emit(n, d, v)
	_name_edit.text = ""
	_desc_edit.text = ""
