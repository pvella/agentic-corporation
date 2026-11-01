## Bakes the real navigation polygon (same inputs as Main._bake_navigation)
## and checks it is one connected walkmesh with every seat / amenity on it.
## The Python verifier simulates its own grid, so it cannot catch baker
## behaviour such as overlapping floor outlines turning into holes.
##   godot --headless --path . --script res://tests/test_navmesh.gd
extends SceneTree

const AGENT_RADIUS := 11.0
## Waypoints may sit this far off the mesh: Agent._arrive snaps < 10 px.
const MAX_OFF_MESH := 10.0
## Small talk spots only need to be near the mesh (agents stand at the edge).
const MAX_OFF_MESH_CHAT := 20.0

var failures: PackedStringArray = []


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		failures.append(what)


func _initialize() -> void:
	var msg: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://tests/fixtures/office_layout.json"))
	var office: Node2D = load("res://Office.gd").new()
	root.add_child(office)
	office.build(msg.get("office", msg))

	var poly := NavigationPolygon.new()
	poly.agent_radius = AGENT_RADIUS
	var src := NavigationMeshSourceGeometryData2D.new()
	for p: PackedVector2Array in office.get_floor_outlines():
		src.add_traversable_outline(p)
	for o: PackedVector2Array in office.get_obstacle_outlines():
		src.add_obstruction_outline(o)
	NavigationServer2D.bake_from_source_geometry_data(poly, src)
	_check(poly.get_polygon_count() > 0, "bake produced polygons")

	# Connected components: polygons sharing an edge (two vertex indices).
	var verts := poly.get_vertices()
	var n := poly.get_polygon_count()
	var parent: Array[int] = []
	for i in n:
		parent.append(i)
	var find := func(i: int) -> int:
		while parent[i] != i:
			i = parent[i]
		return i
	var edge_owner := {}
	for i in n:
		var pi := poly.get_polygon(i)
		for k in pi.size():
			var a := pi[k]
			var b := pi[(k + 1) % pi.size()]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if edge_owner.has(key):
				parent[find.call(i)] = find.call(edge_owner[key])
			else:
				edge_owner[key] = i
	var roots := {}
	for i in n:
		roots[find.call(i)] = true
	_check(roots.size() == 1, "walkmesh is one connected piece (got %d)" % roots.size())

	# Every waypoint on (or within snap range of) the mesh.
	var polys: Array[PackedVector2Array] = []
	for i in n:
		var pts := PackedVector2Array()
		for vi in poly.get_polygon(i):
			pts.append(verts[vi])
		polys.append(pts)
	var off := 0
	for w: Dictionary in office.waypoints:
		var name := str(w.name)
		var limit := MAX_OFF_MESH_CHAT if name.begins_with("Chat_") or name.contains("_Chat") else MAX_OFF_MESH
		var d := _dist_to_mesh(w.pos, polys)
		if d > limit:
			off += 1
			_check(false, "%s is %.1f px off the walkmesh" % [name, d])
	_check(off == 0, "all %d waypoints reachable" % office.waypoints.size())

	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL (%d)" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _dist_to_mesh(p: Vector2, polys: Array[PackedVector2Array]) -> float:
	var best := INF
	for pts in polys:
		if Geometry2D.is_point_in_polygon(p, pts):
			return 0.0
		for k in pts.size():
			var c := Geometry2D.get_closest_point_to_segment(p, pts[k], pts[(k + 1) % pts.size()])
			best = minf(best, p.distance_to(c))
	return best
