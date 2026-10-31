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
	print("areas=", office.areas.size(), " props=", office.props.size(), " frames=", office.outer_frames.size())
	for a in office.areas:
		print("AREA kind=", a.kind, " name=", a.get("name", ""), " rect=", a.rect)
	var bad: int = 0
	for p in office.props:
		var r: Rect2 = p.rect
		var c: Vector2 = r.get_center()
		var inside: bool = false
		var parent: String = ""
		for a in office.areas:
			if str(a.kind) == "corridor":
				continue
			var ar: Rect2 = a.rect
			if ar.grow(8.0).has_point(c):
				inside = true
				parent = str(a.get("name", a.kind))
				break
		if not inside:
			bad += 1
			print("OUTSIDE prop kind=%s center=%s rect=%s" % [p.kind, str(c), str(r)])
		elif str(p.kind) in ["rug", "yoga_mat", "cushion"]:
			for corner: Vector2 in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
				var ok: bool = false
				for a in office.areas:
					if str(a.kind) == "corridor":
						continue
					if (a.rect as Rect2).grow(4.0).has_point(corner):
						ok = true
						break
				if not ok:
					bad += 1
					print("RUG_CORNER_OUT kind=%s corner=%s parent=%s rect=%s" % [p.kind, str(corner), parent, str(r)])
					break
	print("outside_bad=", bad)
	quit()
