## Isometric (2:1 dimetric, "Habbo" 45 degree) projection shared by the
## renderer. The simulation, navigation and every waypoint stay in the flat
## top-down "world" coordinates built by Office.gd; only drawing goes through
## here:
##
##   screen = SCALE * ((x - y) * K, (x + y) * K / 2 - z)   (z = height above the floor)
##
## SCALE blows the whole drawn world up (rooms, furniture, wall heights) without
## touching the simulation: the layout, navigation mesh, waypoints and agent
## speeds stay in the original "world" units. The top-down view is just
## SCALE * (x, y).
##
## World north (-y) points up-right on screen, world west (-x) up-left, so the
## back walls of a room are its north and west walls. Depth order is screen y
## of the feet, i.e. world x + y, which is exactly what a y-sorted node at the
## projected position gives us.
extends RefCounted

const K := 1.0
## Drawn size of one world unit (both views). People get their own, slightly
## larger factor (PEOPLE_SCALE) so they read well next to the furniture.
const SCALE := 1.4
const PEOPLE_SCALE := 2.4
## The linear part of the projection as a Transform2D (x axis, y axis).
const AXIS_X := Vector2(K, K * 0.5) * SCALE
const AXIS_Y := Vector2(-K, K * 0.5) * SCALE

## True: isometric view. False: the classic top-down view (identity projection).
static var enabled := true


static func to_screen(p: Vector2, z: float = 0.0) -> Vector2:
	if not enabled:
		return p * SCALE
	return Vector2((p.x - p.y) * K, (p.x + p.y) * K * 0.5 - z) * SCALE


static func to_world(s: Vector2) -> Vector2:
	s /= SCALE
	if not enabled:
		return s
	var a := s.x / K          # x - y
	var b := 2.0 * s.y / K    # x + y
	return Vector2((a + b) * 0.5, (b - a) * 0.5)


## Floor-plane transform (world -> screen at height z), with `origin_shift`
## added (e.g. -node.position to draw in a node's local space).
static func floor_xf(z: float = 0.0, origin_shift: Vector2 = Vector2.ZERO) -> Transform2D:
	if not enabled:
		return Transform2D(Vector2.RIGHT * SCALE, Vector2.DOWN * SCALE, origin_shift)
	return Transform2D(AXIS_X, AXIS_Y, origin_shift + Vector2(0, -z) * SCALE)


## Vertical plane at world y = y0 (faces south, i.e. towards the lower left of
## the screen). Local coords: u = world x, v = pixels down from height z_top.
static func south_xf(y0: float, z_top: float, origin_shift: Vector2 = Vector2.ZERO) -> Transform2D:
	return Transform2D(AXIS_X, Vector2(0, SCALE), Vector2(-y0 * K, y0 * K * 0.5 - z_top) * SCALE + origin_shift)


## Vertical plane at world x = x0 (faces east, towards the lower right).
## Local coords: u = world y, v = pixels down from height z_top.
static func east_xf(x0: float, z_top: float, origin_shift: Vector2 = Vector2.ZERO) -> Transform2D:
	return Transform2D(Vector2(-K, K * 0.5) * SCALE, Vector2(0, SCALE), Vector2(x0 * K, x0 * K * 0.5 - z_top) * SCALE + origin_shift)


## Screen-space bounding box of a world rect raised up to height `h`.
static func screen_aabb(r: Rect2, h: float = 0.0) -> Rect2:
	var pts := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	var out := Rect2(to_screen(pts[0]), Vector2.ZERO)
	for p: Vector2 in pts:
		out = out.expand(to_screen(p)).expand(to_screen(p, h))
	return out


## Unit direction in screen space for a world direction (for facing / poses).
static func screen_dir(d: Vector2) -> Vector2:
	if not enabled:
		return d
	var s := Vector2(d.x - d.y, (d.x + d.y) * 0.5)
	return s.normalized() if s.length() > 0.001 else Vector2.DOWN
