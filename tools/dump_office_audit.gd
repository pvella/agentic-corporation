extends SceneTree

func _init() -> void:
	var OfficeScript = load("res://Office.gd")
	var office = OfficeScript.new()
	var cfg: Variant = office.LEGACY_LAYOUT
	if FileAccess.file_exists("res://office.json"):
		var f: FileAccess = FileAccess.open("res://office.json", FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			cfg = parsed
	office.build(cfg)
	print("AUDIT areas=", office.areas.size(), " props=", office.props.size(), " waypoints=", office.waypoints.size())
	var expected: Array = []
	if typeof(cfg) == TYPE_DICTIONARY:
		for r in cfg.get("rooms", []):
			for m in r.get("members", []):
				expected.append(str(m.get("agent_id")))
	print("expected_agents=", expected.size())
	for aid in expected:
		print("EXPECT ", aid)
	var desk_names: Dictionary = {}
	for w in office.waypoints:
		var n: String = str(w.name)
		if n.begins_with("Desk_"):
			desk_names[n] = w
			print("DESK ", n, " pos=", w.pos, " seat=", w.get("seat", ""))
	print("desk_count=", desk_names.size())
	for aid_v in expected:
		var aid: String = str(aid_v)
		var dn: String = "Desk_" + aid
		if not desk_names.has(dn):
			print("MISSING_DESK ", aid)
			continue
		var pos: Vector2 = desk_names[dn].pos
		var in_room := false
		var room_name: String = ""
		for a in office.areas:
			var kind: String = str(a.kind)
			if kind == "corridor":
				continue
			if (a.rect as Rect2).has_point(pos):
				in_room = true
				room_name = str(a.get("name", kind))
				break
		print("DESK_LOC ", aid, " pos=", pos, " in_room=", in_room, " room=", room_name)
		if not in_room:
			print("DESK_OUTSIDE_ROOM ", aid)
		for o in office.obstacles:
			if (o as Rect2).grow(-2.0).has_point(pos):
				print("DESK_IN_OBSTACLE ", aid, " obs=", o)
	var outside := 0
	for p in office.props:
		var kind: String = str(p.kind)
		var r: Rect2 = p.rect
		var c: Vector2 = r.get_center()
		var inside := false
		var parent: String = ""
		for a in office.areas:
			if str(a.kind) == "corridor":
				continue
			if (a.rect as Rect2).grow(8.0).has_point(c):
				inside = true
				parent = str(a.get("name", a.kind))
				break
		# also corridors
		if not inside:
			for a in office.areas:
				if str(a.kind) == "corridor" and (a.rect as Rect2).grow(4.0).has_point(c):
					inside = true
					parent = "corridor"
					break
		if not inside:
			outside += 1
			print("OUTSIDE_PROP kind=", kind, " center=", c, " rect=", r)
		if kind in ["rug", "yoga_mat", "cushion"]:
			print("FLOOR_PROP kind=", kind, " rect=", r, " sort_y=", p.get("sort_y", "default"), " parent=", parent)
		if kind == "lamp":
			print("LAMP center=", c, " rect=", r, " parent=", parent, " inside=", inside)
	print("outside_props=", outside)
	for w in office.waypoints:
		var n: String = str(w.name)
		if n.begins_with("Yoga") or n.begins_with("Meditation") or n.begins_with("Foosball") or n.begins_with("Canteen") or n.begins_with("Coffee") or n.begins_with("Sofa") or n.begins_with("Water") or n.begins_with("Vending"):
			var pos: Vector2 = w.pos
			var zone: String = "?"
			for a in office.areas:
				if str(a.kind) in ["break", "canteen", "rec"]:
					if (a.rect as Rect2).grow(6.0).has_point(pos):
						zone = str(a.kind)
						break
			print("AMENITY ", n, " pos=", pos, " seat=", w.get("seat", ""), " zone=", zone)
	quit()
