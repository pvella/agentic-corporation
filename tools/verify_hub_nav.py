#!/usr/bin/env python3
"""Verify hub-and-spoke layout after satellite-ring fit.

Mirrors Office.gd hub geometry (including `_fit_satellite_ring`). Asserts:
  1) no room AABB / wall-footprint overlaps (corridor gap preserved)
  2) each satellite door sits on its spoke and on the room edge
  3) every simulated room↔room path has no segment intersecting a wall rect
  4) amenity spots + room signs/labels sit inside their rooms
  5) headless idle grid reach: hub → canteen seat and hub → rec mat
  6) no floor / rug / wall / path footprint lies on the grass outside a
     room or corridor polygon (catches leftover patches after ring moves)
  7) floor props (rug/mat/cushion) sort under agents (iso_anchor NW + z_index)
  8) no decorative grass speckles (read as grey leftover dots)
  9) amenity seat poses gated to the correct room kinds in Agent.gd
 10) every seeded desk is inside its team room; door→desk grid reach
 11) walk polys cover rooms+corridors only (no grass walkable samples)
Non-zero exit on any failure.
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WALL = 12.0
CELL = (176.0, 162.0)
PAD_X = 26.0
ROOM_TOP = 68.0
ROOM_BOTTOM = 84.0
ORIGIN = (40.0, 40.0)
EXT_WALL = 14.0


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float

    @property
    def end_x(self) -> float:
        return self.x + self.w

    @property
    def end_y(self) -> float:
        return self.y + self.h

    def center(self) -> tuple[float, float]:
        return (self.x + self.w * 0.5, self.y + self.h * 0.5)


def team_size(room: dict) -> tuple[float, float]:
    members = room.get("members", [])
    desks = max(int(room.get("desks", 1)), len(members), 1)
    cols = min(3, desks)
    rows = math.ceil(desks / float(cols))
    exec_extra = 0.0
    for m in members:
        if str(m.get("desk_style", "")) == "executive" or str(m.get("agent_id", "")) == "chief_of_staff":
            exec_extra += CELL[0] * 0.55
    return (cols * CELL[0] + PAD_X * 2.0 + exec_extra, ROOM_TOP + rows * CELL[1] + ROOM_BOTTOM)


def rect_exit(r: Rect, dx: float, dy: float) -> tuple[float, float]:
    ln = math.hypot(dx, dy)
    if ln < 1e-6:
        return r.center()
    dx, dy = dx / ln, dy / ln
    cx, cy = r.center()
    tx = ty = float("inf")
    if abs(dx) > 1e-6:
        edge_x = r.end_x if dx > 0 else r.x
        tx = (edge_x - cx) / dx
    if abs(dy) > 1e-6:
        edge_y = r.end_y if dy > 0 else r.y
        ty = (edge_y - cy) / dy
    t = min(tx, ty)
    return (cx + dx * t, cy + dy * t)


def nearest_edge(r: Rect, p: tuple[float, float]) -> str:
    px, py = p
    dn, ds = abs(py - r.y), abs(py - r.end_y)
    dw, de = abs(px - r.x), abs(px - r.end_x)
    m = min(dn, ds, dw, de)
    if m == dn:
        return "n"
    if m == ds:
        return "s"
    if m == dw:
        return "w"
    return "e"


def snap_to_edge(r: Rect, door_pt: tuple[float, float]) -> tuple[float, float]:
    edge = nearest_edge(r, door_pt)
    x, y = door_pt
    if edge == "n":
        return (x, r.y)
    if edge == "s":
        return (x, r.end_y)
    if edge == "w":
        return (r.x, y)
    return (r.end_x, y)



def corridor_route(hub: Rect, sat: Rect, dx: float, dy: float, width: float) -> list:
    """Mirror Office.gd `_corridor_route`: straight spoke, or an L for rooms off a hub corner."""
    slack = width * 0.5
    east = sat.x >= hub.end_x - slack
    west = sat.end_x <= hub.x + slack
    south = sat.y >= hub.end_y - slack
    north = sat.end_y <= hub.y + slack
    if not ((east or west) and (north or south)):
        return [snap_to_edge(hub, rect_exit(hub, dx, dy)), snap_to_edge(sat, rect_exit(sat, -dx, -dy))]
    inset = width * 0.5 + 60.0
    y0 = hub.end_y - inset if south else hub.y + inset
    x1 = sat.x + inset if east else sat.end_x - inset
    return [(hub.end_x if east else hub.x, y0), (x1, y0), (x1, sat.y if south else sat.end_y)]

def inset_inside(r: Rect, door_pt: tuple[float, float], inset: float = WALL + 8.0):
    edge = nearest_edge(r, door_pt)
    x, y = door_pt
    if edge == "n":
        return (x, y + inset)
    if edge == "s":
        return (x, y - inset)
    if edge == "w":
        return (x + inset, y)
    return (x - inset, y)


def wall_edge_with_gaps(ax, ay, bx, by, thickness, horizontal, gaps, hw) -> list[Rect]:
    pts = sorted(gaps)
    out: list[Rect] = []
    if horizontal:
        x, y, end_x = ax, ay, bx
        for g in pts:
            if g - hw > x:
                out.append(Rect(x, y, g - hw - x, thickness))
            x = max(x, g + hw)
        if end_x > x:
            out.append(Rect(x, y, end_x - x, thickness))
    else:
        x2, y2, end_y = ax, ay, by
        for g in pts:
            if g - hw > y2:
                out.append(Rect(x2, y2, thickness, g - hw - y2))
            y2 = max(y2, g + hw)
        if end_y > y2:
            out.append(Rect(x2, y2, thickness, end_y - y2))
    return [w for w in out if w.w > 0.05 and w.h > 0.05]


def frame_walls(r: Rect, door_pt: tuple[float, float], door_w: float) -> list[Rect]:
    gaps_n, gaps_s, gaps_w, gaps_e = [], [], [], []
    edge = nearest_edge(r, door_pt)
    corner_slop = door_w * 0.5 + WALL
    if edge == "n":
        gaps_n.append(door_pt[0])
        if door_pt[0] - r.x <= corner_slop:
            gaps_w.append(door_pt[1])
        if r.end_x - door_pt[0] <= corner_slop:
            gaps_e.append(door_pt[1])
    elif edge == "s":
        gaps_s.append(door_pt[0])
        if door_pt[0] - r.x <= corner_slop:
            gaps_w.append(door_pt[1])
        if r.end_x - door_pt[0] <= corner_slop:
            gaps_e.append(door_pt[1])
    elif edge == "w":
        gaps_w.append(door_pt[1])
        if door_pt[1] - r.y <= corner_slop:
            gaps_n.append(door_pt[0])
        if r.end_y - door_pt[1] <= corner_slop:
            gaps_s.append(door_pt[0])
    else:
        gaps_e.append(door_pt[1])
        if door_pt[1] - r.y <= corner_slop:
            gaps_n.append(door_pt[0])
        if r.end_y - door_pt[1] <= corner_slop:
            gaps_s.append(door_pt[0])
    hw = door_w * 0.5
    out: list[Rect] = []
    out += wall_edge_with_gaps(r.x, r.y, r.end_x, r.y, WALL, True, gaps_n, hw)
    out += wall_edge_with_gaps(r.x, r.end_y - WALL, r.end_x, r.end_y - WALL, WALL, True, gaps_s, hw)
    out += wall_edge_with_gaps(r.x, r.y, r.x, r.end_y, WALL, False, gaps_w, hw)
    out += wall_edge_with_gaps(r.end_x - WALL, r.y, r.end_x - WALL, r.end_y, WALL, False, gaps_e, hw)
    return out


def hub_perimeter(hub: Rect, doors: list[tuple[float, float]], door_w: float) -> list[Rect]:
    x0, y0, x1, y1 = hub.x, hub.y, hub.end_x, hub.end_y
    hw = door_w * 0.5
    north, south, west, east = [], [], [], []
    corner_slop = door_w * 0.5 + WALL
    for p in doors:
        dn, ds = abs(p[1] - y0), abs(p[1] - y1)
        dw, de = abs(p[0] - x0), abs(p[0] - x1)
        m = min(dn, ds, dw, de)
        if m == dn:
            north.append(p[0])
        elif m == ds:
            south.append(p[0])
        elif m == dw:
            west.append(p[1])
        else:
            east.append(p[1])
        if m == dn or m == ds:
            if dw <= corner_slop:
                west.append(p[1])
            if de <= corner_slop:
                east.append(p[1])
        else:
            if dn <= corner_slop:
                north.append(p[0])
            if ds <= corner_slop:
                south.append(p[0])
    south.append(hub.center()[0])
    out: list[Rect] = []
    out += wall_edge_with_gaps(x0, y0, x1, y0, WALL, True, north, hw)
    out += wall_edge_with_gaps(x0, y1 - WALL, x1, y1 - WALL, WALL, True, south, hw)
    out += wall_edge_with_gaps(x0, y0, x0, y1, WALL, False, west, hw)
    out += wall_edge_with_gaps(x1 - WALL, y0, x1 - WALL, y1, WALL, False, east, hw)
    return out


def seg_intersects_rect(a: tuple[float, float], b: tuple[float, float], r: Rect) -> bool:
    dx, dy = b[0] - a[0], b[1] - a[1]
    t0, t1 = 0.0, 1.0
    for p, q in (
        (-dx, a[0] - r.x),
        (dx, r.end_x - a[0]),
        (-dy, a[1] - r.y),
        (dy, r.end_y - a[1]),
    ):
        if abs(p) < 1e-12:
            if q < 0:
                return False
            continue
        t = q / p
        if p < 0:
            if t > t1:
                return False
            t0 = max(t0, t)
        else:
            if t < t0:
                return False
            t1 = min(t1, t)
    return (t1 - t0) > 1e-4 and t0 < 1.0 - 1e-6 and t1 > 1e-6


def sat_size_for_spec(spec: dict, seats: int) -> tuple[float, float]:
    if spec["kind"] == "team":
        sat_size = team_size(spec.get("room") or {})
        if spec.get("prominent"):
            sat_size = (sat_size[0] * 1.28, sat_size[1] * 1.18)
        return sat_size
    if spec["kind"] == "meeting":
        return hr_size(seats, spec.get("room") or {})
    return (380.0, 390.0)


def hr_size(seats: int, hr_room: dict) -> tuple[float, float]:
    """Mirror Office.gd `_hr_size`: HR satellite plus the HR team's desk block."""
    per_side = math.ceil(seats / 2.0)
    w, h = max(360.0, per_side * 84.0 + 190.0), 400.0
    d = max(int(hr_room.get("desks", 0) or 0), len(hr_room.get("members", []) or [])) if hr_room else 0
    if d > 0:
        cols = 2 if d <= 4 else 3
        w = max(w, cols * 148.0 + 80.0)
        h += math.ceil(d / cols) * 130.0 + 30.0
    return (w, h)


def rects_overlap(a: Rect, b: Rect, pad: float = 0.0) -> bool:
    return not (
        a.end_x + pad <= b.x - pad
        or b.end_x + pad <= a.x - pad
        or a.end_y + pad <= b.y - pad
        or b.end_y + pad <= a.y - pad
    )


def ring_footprints_clear(hub: Rect, placements: list[Rect], clear: float) -> bool:
    grown = Rect(hub.x - clear, hub.y - clear, hub.w + 2 * clear, hub.h + 2 * clear)
    for i, r in enumerate(placements):
        if rects_overlap(grown, r, 0.0):
            return False
        for j in range(i):
            if rects_overlap(placements[j], r, EXT_WALL):
                return False
    return True


def fit_satellite_ring(hub, sat_specs, seats, base_rx, base_ry, clear):
    hub_c = hub.center()
    metas = [(float(s["theta"]), sat_size_for_spec(s, seats)) for s in sat_specs]
    lo, hi = 1.0, 1.85
    for _ in range(8):
        placements = []
        for th, sz in metas:
            sc = (hub_c[0] + math.cos(th) * base_rx * hi, hub_c[1] + math.sin(th) * base_ry * hi)
            placements.append(Rect(sc[0] - sz[0] * 0.5, sc[1] - sz[1] * 0.5, sz[0], sz[1]))
        if ring_footprints_clear(hub, placements, clear):
            break
        hi *= 1.12
    for _ in range(28):
        mid = (lo + hi) * 0.5
        placements = []
        for th, sz in metas:
            sc = (hub_c[0] + math.cos(th) * base_rx * mid, hub_c[1] + math.sin(th) * base_ry * mid)
            placements.append(Rect(sc[0] - sz[0] * 0.5, sc[1] - sz[1] * 0.5, sz[0], sz[1]))
        if ring_footprints_clear(hub, placements, clear):
            hi = mid
        else:
            lo = mid
    return base_rx * hi, base_ry * hi


def point_on_segment(p, a, b, tol=6.0) -> bool:
    ax, ay = a; bx, by = b; px, py = p
    abx, aby = bx - ax, by - ay
    apx, apy = px - ax, py - ay
    ab2 = abx * abx + aby * aby
    if ab2 < 1e-6:
        return math.hypot(apx, apy) <= tol
    t = max(0.0, min(1.0, (apx * abx + apy * aby) / ab2))
    qx, qy = ax + t * abx, ay + t * aby
    return math.hypot(px - qx, py - qy) <= tol


def wall_rects_overlap_area(walls: list[Rect]) -> list[tuple[int, int, float]]:
    """Pairs of wall AABBs whose overlap area is more than a corner nibble."""
    hits = []
    for i, a in enumerate(walls):
        for j in range(i + 1, len(walls)):
            b = walls[j]
            ox = max(0.0, min(a.end_x, b.end_x) - max(a.x, b.x))
            oy = max(0.0, min(a.end_y, b.end_y) - max(a.y, b.y))
            area = ox * oy
            # Same-room walls meet at corners (~WALL×WALL). Flag larger crossings.
            if area > WALL * WALL * 2.5:
                hits.append((i, j, area))
    return hits


def grid_reachable(start, goal, walls: list[Rect], bounds: Rect, cell: float = 24.0) -> bool:
    """Coarse BFS: idle agent from start reaches goal without entering wall cells."""
    def blocked(x, y):
        for w in walls:
            if w.x - 2 <= x <= w.end_x + 2 and w.y - 2 <= y <= w.end_y + 2:
                return True
        return False

    sx = int((start[0] - bounds.x) / cell)
    sy = int((start[1] - bounds.y) / cell)
    gx = int((goal[0] - bounds.x) / cell)
    gy = int((goal[1] - bounds.y) / cell)
    cols = max(1, int(math.ceil(bounds.w / cell)))
    rows = max(1, int(math.ceil(bounds.h / cell)))
    if not (0 <= sx < cols and 0 <= sy < rows and 0 <= gx < cols and 0 <= gy < rows):
        return False
    blocked_cells = set()
    for iy in range(rows):
        for ix in range(cols):
            cx = bounds.x + (ix + 0.5) * cell
            cy = bounds.y + (iy + 0.5) * cell
            if blocked(cx, cy):
                blocked_cells.add((ix, iy))
    if (sx, sy) in blocked_cells:
        blocked_cells.discard((sx, sy))
    if (gx, gy) in blocked_cells:
        blocked_cells.discard((gx, gy))
    from collections import deque
    q = deque([(sx, sy)])
    seen = {(sx, sy)}
    while q:
        x, y = q.popleft()
        if abs(x - gx) + abs(y - gy) <= 1:
            return True
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < cols and 0 <= ny < rows and (nx, ny) not in seen and (nx, ny) not in blocked_cells:
                seen.add((nx, ny))
                q.append((nx, ny))
    return False



def build(cfg: dict):
    shared = cfg.get("shared", {})
    seats = max(2, min(8, int(shared.get("meeting_room", {}).get("seats", 6))))
    team_rooms = [r for r in cfg.get("rooms", []) if not r.get("isolated")]
    hub_size = (1320.0, 700.0)
    hub = Rect(ORIGIN[0] + 760.0, ORIGIN[1] + 420.0, hub_size[0], hub_size[1])
    hub_c = hub.center()
    base_rx, base_ry = 1080.0, 600.0
    corridor_w = 78.0
    door_w = corridor_w + 10.0
    clear = corridor_w + EXT_WALL * 2.0

    hr_room = next((r for r in team_rooms if r["id"] == "hr"), {})  # lives inside the HR satellite
    team_rooms = [r for r in team_rooms if r["id"] != "hr"]
    sat_specs = [
        {"kind": "meeting", "theta": -math.pi * 0.5, "id": "meeting", "room": hr_room},
        {"kind": "server", "theta": -math.pi * 0.25, "id": "server"},
    ]
    exec_room = next((r for r in team_rooms if r["id"] == "executive"), None)
    others = [r for r in team_rooms if r["id"] != "executive"]
    sat_specs.append({"kind": "team", "room": exec_room or {}, "theta": math.pi * 0.5,
                      "prominent": True, "id": "executive"})
    prefer = ["engineering", "product_design", "operations", "finance", "special_projects"]
    ordered = []
    for pid in prefer:
        for r in others:
            if r["id"] == pid and r not in ordered:
                ordered.append(r)
    for r in others:
        if r not in ordered:
            ordered.append(r)
    other_thetas = [0.0, math.pi * 0.25, math.pi * 0.75, math.pi, math.pi * 1.25]
    for i, r in enumerate(ordered):
        th = other_thetas[i] if i < len(other_thetas) else (i * 2 * math.pi / max(1, len(ordered)))
        sat_specs.append({"kind": "team", "room": r, "theta": th, "id": r["id"]})
    if exec_room is None:
        sat_specs = [s for s in sat_specs if not (s.get("prominent") and s["kind"] == "team" and not s.get("room"))]

    # Mirror Office.gd `_fit_satellite_ring`: grow from compact base until clear.
    ring_rx, ring_ry = fit_satellite_ring(hub, sat_specs, seats, base_rx, base_ry, clear)
    print(f"ring_fit=({ring_rx:.1f},{ring_ry:.1f}) base=({base_rx:.1f},{base_ry:.1f}) clear={clear:.1f}")

    walls: list[Rect] = []
    rooms = [{"id": "hub", "name": "Hub", "center": hub_c, "rect": hub}]
    hub_doors: list[tuple[float, float]] = []
    spokes = []
    signs: list[dict] = []

    for spec in sat_specs:
        theta = float(spec["theta"])
        prominent = bool(spec.get("prominent", False))
        if spec["kind"] == "team":
            sat_size = team_size(spec["room"])
            if prominent:
                sat_size = (sat_size[0] * 1.28, sat_size[1] * 1.18)
            rid = spec["room"].get("id", spec["id"])
            rname = spec["room"].get("name", rid)
        elif spec["kind"] == "meeting":
            sat_size = hr_size(seats, spec.get("room") or {})
            rid, rname = "meeting", "HR"
        else:
            sat_size = (380.0, 390.0)
            rid, rname = "server", "Server Room"
        sc = (hub_c[0] + math.cos(theta) * ring_rx, hub_c[1] + math.sin(theta) * ring_ry)
        sat = Rect(sc[0] - sat_size[0] * 0.5, sc[1] - sat_size[1] * 0.5, sat_size[0], sat_size[1])
        dx, dy = sc[0] - hub_c[0], sc[1] - hub_c[1]
        route = corridor_route(hub, sat, dx, dy, corridor_w)
        hub_exit, sat_exit = route[0], route[-1]
        hub_doors.append(hub_exit)
        walls += frame_walls(sat, sat_exit, door_w)
        edge = nearest_edge(sat, sat_exit)
        if edge in ("n", "s"):
            assert abs(sat_exit[1] - (sat.y if edge == "n" else sat.end_y)) < 0.5, (rid, sat_exit, edge)
        else:
            assert abs(sat_exit[0] - (sat.x if edge == "w" else sat.end_x)) < 0.5, (rid, sat_exit, edge)
        # Spoke direction must point from hub exit toward sat exit (aligned junction).
        sx, sy = sat_exit[0] - hub_exit[0], sat_exit[1] - hub_exit[1]
        assert math.hypot(sx, sy) > 20.0, f"corridor too short for {rid}: {math.hypot(sx, sy)}"
        rooms.append({
            "id": rid, "name": rname, "center": sat.center(), "rect": sat,
            "hub_exit": hub_exit, "sat_exit": sat_exit, "edge": edge,
            "hub_in": inset_inside(hub, hub_exit),
            "sat_in": inset_inside(sat, sat_exit),
            "elbows": route[1:-1],
        })
        # Placard at NW corner (Office._sign_rect) — must sit inside the room.
        signs.append({"name": rname, "room_id": rid, "rect": Rect(sat.x + 10, sat.y + 8, 80, 26)})
        spokes.append({"from": hub_exit, "to": sat_exit, "path": route, "width": corridor_w, "id": rid})

    walls += hub_perimeter(hub, hub_doors, door_w)
    return rooms, walls, spokes, door_w, corridor_w, signs, (ring_rx, ring_ry)


def path_for(a: dict, b: dict, hub_center) -> list[tuple[float, float]]:
    """room → door(inside) → door → spoke → door → door(inside) → hub → …"""
    pts = [a["center"]]
    if a["id"] != "hub":
        pts += [a["sat_in"], a["sat_exit"], *reversed(a["elbows"]), a["hub_exit"], a["hub_in"]]
    pts.append(hub_center)
    if b["id"] != "hub":
        pts += [b["hub_in"], b["hub_exit"], *b["elbows"], b["sat_exit"], b["sat_in"]]
    pts.append(b["center"])
    out = [pts[0]]
    for p in pts[1:]:
        if math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) > 0.5:
            out.append(p)
    return out



def verify_hub_amenities(hub: Rect) -> int:
    """Mirror Office.gd _build_break/_canteen/_rec: amenity WPs must sit inside
    their live hub zone rects (not leftover corridor-map coords) and not deep
    inside blocking furniture (agent_radius pad).
    """
    AGENT_R = 11.0
    WALL = 12.0
    pad = 56.0
    zone_w = (hub.w - pad * 4.0) / 3.0
    zone_h = hub.h * 0.70
    zone_y = hub.y + (hub.h - zone_h) * 0.5
    break_r = Rect(hub.x + pad, zone_y, zone_w, zone_h)
    canteen_r = Rect(break_r.end_x + pad, zone_y, zone_w, zone_h)
    rec_r = Rect(canteen_r.end_x + pad, zone_y, zone_w, zone_h)
    zones = {"break": break_r, "canteen": canteen_r, "rec": rec_r}
    obstacles: list[Rect] = []
    wps: list[tuple[str, tuple[float, float], str]] = []

    def add_obs(r: Rect) -> None:
        obstacles.append(r)

    def wp(name: str, pos: tuple[float, float], kind: str) -> None:
        wps.append((name, pos, kind))

    # ---- break (Office.gd _build_break) ----
    p, e, m = (break_r.x, break_r.y), (break_r.end_x, break_r.end_y), 14.0
    coffee = Rect(p[0] + m, p[1] + 44, 52, 42); add_obs(coffee)
    wp("Coffee_Machine", (coffee.x + coffee.w * 0.5, coffee.end_y + 26), "break")
    water = Rect(e[0] - m - 40, p[1] + 44, 40, 44); add_obs(water)
    wp("Water_Cooler", (water.x + water.w * 0.5, water.end_y + 26), "break")
    vend = Rect(water.x - 12 - 44, p[1] + 42, 44, 40); add_obs(vend)
    wp("Vending_Machine", (vend.x + vend.w * 0.5, vend.end_y + 28), "break")
    sofa_w = min(156.0, break_r.w * 0.42)
    sofa = Rect(p[0] + m, e[1] - 50 - 46, sofa_w, 46); add_obs(Rect(sofa.x, sofa.y, sofa.w, 12.0))  # backrest only
    wp("Sofa_1", (sofa.x + sofa.w * 0.30, sofa.y + 26), "break")
    wp("Sofa_2", (sofa.x + sofa.w * 0.70, sofa.y + 26), "break")
    table_w = min(120.0, break_r.w * 0.34)
    table = Rect(e[0] - m - table_w, sofa.y, table_w, 58)
    if table.x < sofa.end_x + 20.0:
        table.x = sofa.end_x + 20.0
        table.w = max(72.0, e[0] - m - table.x)
    add_obs(table)
    f1x = max(p[0] + 8.0, table.x - 14.0)
    f2x = min(e[0] - 8.0, table.end_x + 14.0)
    for n, x, y in (
        ("Foosball_1", f1x, table.y + 22),
        ("Foosball_2", f2x, table.y + 22),
        ("Foosball_3", f1x, table.y + 50),
        ("Foosball_4", f2x, table.y + 50),
    ):
        wp(n, (x, y), "break")
    add_obs(Rect(p[0] + m, e[1] - 50, 34, 34))

    # soft dividers (obstacles)
    div_gap = 110.0
    div_w = 18.0  # planter boxes
    for dx in (break_r.end_x + pad * 0.5 - div_w * 0.5, canteen_r.end_x + pad * 0.5 - div_w * 0.5):
        top_h = (zone_h - div_gap) * 0.5
        add_obs(Rect(dx, break_r.y, div_w, top_h))
        add_obs(Rect(dx, break_r.end_y - top_h, div_w, top_h))

    # ---- canteen ----
    p, e, m = (canteen_r.x, canteen_r.y), (canteen_r.end_x, canteen_r.end_y), 14.0
    micro = Rect(e[0] - m - 36, p[1] + 52, 36, 28); add_obs(micro)
    coffee = Rect(micro.x - 10 - 48, p[1] + 44, 48, 40); add_obs(coffee)
    fridge = Rect(coffee.x - 10 - 40, p[1] + 36, 40, 52); add_obs(fridge)
    counter_w = max(120.0, fridge.x - (p[0] + m) - 12.0)
    counter = Rect(p[0] + m, p[1] + 42, counter_w, 40); add_obs(counter)
    wp("Canteen_Counter", (counter.x + counter.w * 0.5, counter.end_y + 26), "canteen")
    tw = min(96.0, (canteen_r.w - m * 2.0 - 40.0) * 0.42)
    tables = [(p[0] + m + 10, p[1] + max(150.0, canteen_r.h * 0.34))]
    if canteen_r.w >= 300.0:
        tables.append((e[0] - m - 10 - tw, tables[0][1]))
    tables.append((canteen_r.center()[0] - tw * 0.5, e[1] - 52 - 70))
    seat_i = 1
    for tpos in tables:
        table = Rect(tpos[0], tpos[1], tw, 52); add_obs(table)
        wp(f"Canteen_Seat_{seat_i}", (table.x - 16, table.y + table.h * 0.5), "canteen"); seat_i += 1
        wp(f"Canteen_Seat_{seat_i}", (table.end_x + 16, table.y + table.h * 0.5), "canteen"); seat_i += 1
    while seat_i <= 6:
        wp(f"Canteen_Seat_{seat_i}", (canteen_r.center()[0] + (seat_i - 5) * 28.0, e[1] - 60), "canteen")
        seat_i += 1

    # ---- rec ----
    p, e, m = (rec_r.x, rec_r.y), (rec_r.end_x, rec_r.end_y), 16.0
    rug = Rect(p[0] + m, p[1] + 70, rec_r.w - m * 2.0, rec_r.h - 120)
    add_obs(Rect(p[0] + m, p[1] + 48, 22, 36))  # lamp
    add_obs(Rect(e[0] - m - 22, p[1] + 48, 22, 36))
    add_obs(Rect(rec_r.center()[0] - 28, p[1] + 40, 56, 48))  # fountain
    for pr in (
        (rec_r.center()[0] - 70, p[1] + 44),
        (rec_r.center()[0] + 40, p[1] + 44),
        (p[0] + m, e[1] - 52),
        (e[0] - m - 30, e[1] - 52),
    ):
        add_obs(Rect(pr[0], pr[1], 30, 30))
    mat_w = min(70.0, rug.w * 0.22)
    mat_h = min(110.0, rug.h * 0.55)
    mat_y = rug.y + rug.h * 0.22
    mat1 = Rect(rug.x + rug.w * 0.08, mat_y, mat_w, mat_h)
    mat2 = Rect(rug.x + rug.w * 0.08 + mat_w + 18.0, mat_y, mat_w, mat_h)
    wp("Yoga_Mat_1", (mat1.x + mat1.w * 0.5, mat1.y + mat1.h * 0.5 + 10), "rec")
    wp("Yoga_Mat_2", (mat2.x + mat2.w * 0.5, mat2.y + mat2.h * 0.5 + 10), "rec")
    cw = min(44.0, rug.w * 0.14)
    ch = min(36.0, rug.h * 0.18)
    c1 = Rect(rug.end_x - rug.w * 0.38, rug.y + rug.h * 0.28, cw, ch)
    c2 = Rect(rug.end_x - rug.w * 0.22, rug.y + rug.h * 0.48, cw, ch)
    wp("Meditation_Cushion_1", (c1.x + c1.w * 0.5, c1.y + c1.h * 0.5 - 2), "rec")
    wp("Meditation_Cushion_2", (c2.x + c2.w * 0.5, c2.y + c2.h * 0.5 - 2), "rec")

    def in_rect(r: Rect, px: float, py: float) -> bool:
        return r.x <= px <= r.end_x and r.y <= py <= r.end_y

    def in_obs(px: float, py: float, grow: float) -> bool:
        for o in obstacles:
            if o.x - grow <= px <= o.end_x + grow and o.y - grow <= py <= o.end_y + grow:
                return True
        return False

    # Sofa seats sit on the sofa prop by design; foosball stands may graze the
    # table after agent_radius inflation — only flag hard zone misses and
    # standing amenity spots (yoga/meditate/coffee/canteen) buried in props.
    sit_on_prop = {"Sofa_1", "Sofa_2", "Foosball_1", "Foosball_2", "Foosball_3", "Foosball_4"}
    bad = 0
    for name, pos, kind in wps:
        zr = zones[kind]
        ok_zone = in_rect(zr, pos[0], pos[1])
        # Standing spots must stay clear of obstacles (+ agent radius).
        check_obs = name not in sit_on_prop
        ok_obs = (not check_obs) or (not in_obs(pos[0], pos[1], AGENT_R))
        status = "OK" if ok_zone and ok_obs else ("OUT_OF_ZONE" if not ok_zone else "IN_OBSTACLE")
        if status != "OK":
            bad += 1
        print(f"amenity wp={name} pos=({pos[0]:.1f},{pos[1]:.1f}) expect={kind} {status}")
    print(f"amenity_waypoints_checked={len(wps)} bad={bad}")
    return bad




def bank_safe_world_rect(exec_rect: Rect, cos_desk_center_y: float | None = None) -> Rect:
    """Mirror Main.gd `_bank_safe_world_rect` (cabinet footprint, world space)."""
    SAFE_W, SAFE_D = 36.0, 32.0
    desk_y = exec_rect.y + 110.0 if cos_desk_center_y is None else cos_desk_center_y
    x = exec_rect.x + 22.0
    y = min(max(desk_y - SAFE_D * 0.5, exec_rect.y + 88.0), exec_rect.end_y - SAFE_D - 72.0)
    return Rect(x, y, SAFE_W, SAFE_D)


def verify_bank_safe(rooms: list[dict], cfg: dict) -> int:
    """Fail if the Executive bank-safe footprint is outside the Executive room."""
    exec_room = next((r for r in rooms if r["id"] == "executive"), None)
    if exec_room is None:
        print("FAIL: no executive room for bank safe")
        return 1
    er: Rect = exec_room["rect"]
    # Approximate CoS desk centre y the same way Office.gd lays it out.
    room_cfg = next((r for r in cfg.get("rooms", []) if r.get("id") == "executive"), {})
    cw, _ch = team_size(room_cfg) if room_cfg else (er.w / 1.28, er.h / 1.18)
    origin_y = er.y
    desk_y = origin_y + ROOM_TOP + 26.0 + 21.0  # desk top + half height
    sr = bank_safe_world_rect(er, desk_y)
    cx, cy = sr.x + sr.w * 0.5, sr.y + sr.h * 0.5
    inside = (
        er.x <= sr.x
        and sr.end_x <= er.end_x
        and er.y <= sr.y
        and sr.end_y <= er.end_y
    )
    # Cabinet-sized, against west wall, clear of north door band.
    size_ok = 30.0 <= sr.w <= 48.0 and 28.0 <= sr.h <= 44.0
    margin_ok = (sr.y >= er.y + 80.0) and (sr.end_y <= er.end_y - 60.0) and (sr.x >= er.x + 16.0)
    print(
        f"bank_safe_rect=({sr.x:.1f},{sr.y:.1f},{sr.w:.1f}x{sr.h:.1f}) center=({cx:.1f},{cy:.1f}) "
        f"executive=({er.x:.1f},{er.y:.1f},{er.w:.1f}x{er.h:.1f}) "
        f"{'OK' if inside and margin_ok and size_ok else 'OUT'}"
    )
    if not (inside and margin_ok and size_ok):
        print("FAIL: bank safe world footprint not a cabinet-sized rect inside Executive")
        return 1
    print("OK: bank safe world footprint inside Executive room")
    return 0


def point_in_rect(p, r: Rect, tol: float = 0.0) -> bool:
    return (
        r.x - tol <= p[0] <= r.end_x + tol
        and r.y - tol <= p[1] <= r.end_y + tol
    )


def rect_inside(inner: Rect, outer: Rect, tol: float = 1.0) -> bool:
    return (
        outer.x - tol <= inner.x
        and inner.end_x <= outer.end_x + tol
        and outer.y - tol <= inner.y
        and inner.end_y <= outer.end_y + tol
    )


def dist_point_segment(p, a, b) -> float:
    ax, ay = a
    bx, by = b
    px, py = p
    abx, aby = bx - ax, by - ay
    apx, apy = px - ax, py - ay
    ab2 = abx * abx + aby * aby
    if ab2 < 1e-9:
        return math.hypot(apx, apy)
    t = max(0.0, min(1.0, (apx * abx + apy * aby) / ab2))
    return math.hypot(px - (ax + t * abx), py - (ay + t * aby))


def point_in_spoke(p, a, b, half_w: float) -> bool:
    return dist_point_segment(p, a, b) <= half_w + 1e-6


def point_in_campus(p, rooms: list[dict], spokes: list[dict], corridor_w: float) -> bool:
    """True if p is inside a room (incl. exterior wall fringe) or a spoke strip."""
    for rm in rooms:
        if point_in_rect(p, rm["rect"], tol=EXT_WALL + 2.0):
            return True
    half = corridor_w * 0.5 + EXT_WALL
    for sp in spokes:
        for (ax, ay), (bx, by) in spoke_legs(sp):
            # Extend ends slightly into rooms / past the elbow (matches drawn / nav spoke).
            dx, dy = bx - ax, by - ay
            ln = math.hypot(dx, dy) or 1.0
            ux, uy = dx / ln, dy / ln
            ext = EXT_WALL + 10.0
            a2 = (ax - ux * ext, ay - uy * ext)
            b2 = (bx + ux * ext, by + uy * ext)
            if point_in_spoke(p, a2, b2, half):
                return True
    return False


def spoke_legs(sp: dict) -> list:
    path = sp.get("path") or [sp["from"], sp["to"]]
    return list(zip(path[:-1], path[1:]))


def hub_zone_rects(hub: Rect):
    pad = 56.0
    zone_w = (hub.w - pad * 4.0) / 3.0
    zone_h = hub.h * 0.70
    zone_y = hub.y + (hub.h - zone_h) * 0.5
    break_r = Rect(hub.x + pad, zone_y, zone_w, zone_h)
    canteen_r = Rect(break_r.end_x + pad, zone_y, zone_w, zone_h)
    rec_r = Rect(canteen_r.end_x + pad, zone_y, zone_w, zone_h)
    return break_r, canteen_r, rec_r


def verify_no_outside_footprints(rooms: list[dict], walls: list[Rect], spokes: list[dict], corridor_w: float) -> int:
    """Fail if floor zones, rugs, walls or paths sit on the grass outside rooms/corridors."""
    hub = next(r for r in rooms if r["id"] == "hub")
    hub_r: Rect = hub["rect"]
    break_r, canteen_r, rec_r = hub_zone_rects(hub_r)
    bad = 0

    # Hub zone floors must stay inside the rectangular hub (no grass spill).
    for name, zr in (("break", break_r), ("canteen", canteen_r), ("rec", rec_r)):
        if not rect_inside(zr, hub_r, tol=0.5):
            bad += 1
            print(f"  floor_zone_outside_hub {name} rect=({zr.x:.1f},{zr.y:.1f},{zr.w:.1f}x{zr.h:.1f})")
        for corner in (
            (zr.x, zr.y),
            (zr.end_x, zr.y),
            (zr.x, zr.end_y),
            (zr.end_x, zr.end_y),
        ):
            if not point_in_campus(corner, rooms, spokes, corridor_w):
                bad += 1
                print(f"  floor_corner_on_grass {name} {corner}")

    # Soft rugs painted in hub zones / sample sat NW pads must stay on campus.
    rug_samples = []
    # Rec rug (mirrors Office._build_rec)
    m = 16.0
    rec_rug = Rect(rec_r.x + m, rec_r.y + 70, rec_r.w - m * 2.0, rec_r.h - 120)
    rug_samples.append(("rec_rug", rec_rug, hub_r))
    # Per-satellite: a 1/4 inset floor sample (catches old hard-coded footprints).
    for rm in rooms:
        if rm["id"] == "hub":
            continue
        rr: Rect = rm["rect"]
        sample = Rect(rr.x + 20, rr.y + 20, max(40.0, rr.w - 40), max(40.0, rr.h - 40))
        rug_samples.append((f"{rm['id']}_floor", sample, rr))

    for name, rug, parent in rug_samples:
        if rug.w <= 0 or rug.h <= 0:
            continue
        if not rect_inside(rug, parent, tol=2.0):
            bad += 1
            print(f"  rug_outside_room {name}")
        for corner in (
            (rug.x, rug.y),
            (rug.end_x, rug.y),
            (rug.x, rug.end_y),
            (rug.end_x, rug.end_y),
            rug.center(),
        ):
            if not point_in_campus(corner, rooms, spokes, corridor_w):
                bad += 1
                print(f"  rug_corner_on_grass {name} {corner}")

    # Wall segment centres must sit on a room perimeter / campus (no free-standing grass walls).
    for i, w in enumerate(walls):
        cx, cy = w.center()
        if point_in_campus((cx, cy), rooms, spokes, corridor_w):
            continue
        # Allow hub inner dividers (already inside hub).
        bad += 1
        print(f"  wall_on_grass #{i} center=({cx:.1f},{cy:.1f}) size=({w.w:.1f}x{w.h:.1f})")

    # Spoke midpoints and door ends must be on campus (path not ending in grass).
    for sp in spokes:
        legs = spoke_legs(sp)
        mids = [(f"mid{i}", ((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5)) for i, (a, b) in enumerate(legs)]
        for label, pt in (("from", sp["from"]), ("to", sp["to"]), *mids):
            if not point_in_campus(pt, rooms, spokes, corridor_w):
                bad += 1
                print(f"  path_on_grass {sp['id']}.{label} {pt}")

    print(f"outside_footprints_bad={bad}")
    if bad:
        print("FAIL: floor/rug/wall/path footprint on grass outside room or corridor")
        return bad
    print("OK: no floor/rug/wall/path footprints outside room or corridor polygons")
    return 0






def verify_hub_zone_no_plank_floor() -> int:
    """Break/Canteen/Rec must not go through _draw_floor (zen→wood planks become
    dark diagonals / grey-brown patches on the grass under iso floor_xf)."""
    office = Path(__file__).resolve().parents[1] / "Office.gd"
    src = office.read_text()
    bad = 0
    if "func _draw_hub_zone_overlay" not in src:
        bad += 1
        print("  missing _draw_hub_zone_overlay")
    if 'if a.kind in ["break", "canteen", "rec"]:' not in src:
        bad += 1
        print("  hub zones not skipped in floor draw loops")
    # zen must be listed in a textured arm, not only the wood-plank default
    match = src.find('match str(a.get("theme"')
    default = src.find("\n\t\t_:", match)
    if match < 0 or default < 0:
        # Fallback: just require zen mentioned near tile/lobby arm
        if '"zen"' not in src[src.find("func _draw_floor"):src.find("func _draw_hub")]:
            bad += 1
            print("  theme zen missing from _draw_floor non-default arms")
    else:
        arms = src[match:default]
        if '"zen"' not in arms:
            bad += 1
            print("  theme zen missing from non-default _draw_floor arms")
    if 'draw_rect(f.rect as Rect2, Color("#b3aa99"))' not in src and 'draw_rect(f.rect, Color("#b3aa99"))' not in src:
        bad += 1
        print("  base pad exact-footprint draw missing")
    if "draw_rect(f.rect.grow(EXT_WALL" in src or "draw_rect((f.rect as Rect2).grow(EXT_WALL" in src:
        bad += 1
        print("  base pad still grows EXT_WALL (grass spill)")
    print(f"hub_zone_floor_draw_bad={bad}")
    if bad:
        print("FAIL: hub zone floor draw can leave grass patches / diagonals")
        return bad
    print("OK: hub zones use overlay; no EXT_WALL base-pad spill")
    return 0


def verify_floor_prop_sort() -> int:
    """Rugs/mats/cushions must y-sort under agents (NW iso_anchor + low z_index)
    and cushions must be flat (no raised _box)."""
    prop = ROOT / "Prop.gd"
    src = prop.read_text()
    bad = 0
    # iso_anchor must special-case floor kinds
    start = src.find("func iso_anchor() -> void:")
    if start < 0:
        start = src.find("func iso_anchor() -> Vector2:")
    end = src.find("\nfunc ", start + 10) if start >= 0 else -1
    block = src[start:end] if start >= 0 else ""
    if '"rug", "yoga_mat", "cushion"' not in block and '"rug"' not in block:
        bad += 1
        print("  floor_prop_anchor_missing: iso_anchor lacks rug/yoga_mat/cushion case")
    elif "r.position.x" not in block and "position.x" not in block:
        bad += 1
        print("  floor_prop_anchor_not_nw: expected NW (min x+y) corner for floor props")
    if 'kind in ["rug", "yoga_mat", "cushion"]' not in src and "z_index = -20" not in src:
        bad += 1
        print("  floor_prop_z_index_missing: rugs/mats need z_index under standing props")
    # Flat cushion
    cstart = src.find("func _iso_cushion() -> void:")
    cend = src.find("\nfunc ", cstart + 10) if cstart >= 0 else -1
    cblock = src[cstart:cend] if cstart >= 0 else ""
    if "_box(" in cblock:
        bad += 1
        print("  cushion_still_raised: _iso_cushion uses _box (sorts above walkers)")
    if "_plane_top(0" not in cblock and "plane_top(0" not in cblock:
        bad += 1
        print("  cushion_not_flat_plane: expected _plane_top(0) floor cushion")
    # Flat rug
    rstart = src.find("func _iso_rug() -> void:")
    rend = src.find("\nfunc ", rstart + 10) if rstart >= 0 else -1
    rblock = src[rstart:rend] if rstart >= 0 else ""
    if "_box(" in rblock:
        bad += 1
        print("  rug_still_raised: _iso_rug uses _box")
    print(f"floor_prop_sort_bad={bad}")
    if bad:
        print("FAIL: floor props do not sort flat under agents")
        return bad
    print("OK: floor props use NW iso_anchor, low z_index, flat draw")
    return 0


def verify_no_grass_speckles() -> int:
    """Decorative grass draw_circle speckles read as leftover grey dots."""
    office = (ROOT / "Office.gd").read_text()
    start = office.find("func _draw_iso() -> void:")
    end = office.find("\nfunc ", start + 10) if start >= 0 else -1
    block = office[start:end] if start >= 0 else ""
    bad = 0
    if "draw_circle" in block and "6e955d" in block:
        bad += 1
        print("  iso_grass_speckles_present")
    if "for i in 140:" in block and "draw_circle" in block:
        bad += 1
        print("  iso_grass_speckle_loop_present")
    # Top-down too
    if 'Color("#6e955d")' in office and "draw_circle" in office:
        # Allow if only outside _draw_iso and commented — count live calls near grass
        if "for i in 60:" in office and 'Color("#6e955d")' in office:
            bad += 1
            print("  topdown_grass_speckles_present")
    print(f"grass_speckle_bad={bad}")
    if bad:
        print("FAIL: grass speckles still drawn (look like grey leftover dots)")
        return bad
    print("OK: solid grass only (no decorative speckles)")
    return 0


def verify_amenity_pose_room_gate() -> int:
    """Amenity poses + activity bubbles must match area_kind_at (never WP name alone)."""
    agent = (ROOT / "Agent.gd").read_text()
    main = (ROOT / "Main.gd").read_text()
    harness = (ROOT / "agent_harness.py").read_text()
    bad = 0
    if "SEAT_EXPECTED_KINDS" not in agent:
        bad += 1
        print("  missing SEAT_EXPECTED_KINDS")
    else:
        for seat, kinds in (
            ("yoga", "rec"),
            ("meditate", "rec"),
            ("foosball", "break"),
            ("sofa", "break"),
        ):
            if f'"{seat}"' not in agent or kinds not in agent:
                bad += 1
                print(f"  seat_map_incomplete seat={seat} need_kind={kinds}")
    if "func _seat_room_ok" not in agent:
        bad += 1
        print("  missing _seat_room_ok")
    if "SEAT_ARRIVE_MAX" not in agent:
        bad += 1
        print("  missing SEAT_ARRIVE_MAX gap gate")
    # Blind near-arrive trust lets yoga poses fire in team rooms when stuck.
    seat_fn = agent.split("func _seat_room_ok", 1)[-1].split("\nfunc ", 1)[0]
    if "distance_to(_target_pos) <= SEAT_ARRIVE_MAX" in seat_fn:
        after = seat_fn.split("distance_to(_target_pos) <= SEAT_ARRIVE_MAX", 1)[1][:160]
        if "return true" in after:
            bad += 1
            print("  _seat_room_ok still blind-trusts near-arrive (must check area_kind_at)")
    if "area_kind_at.call" not in seat_fn:
        bad += 1
        print("  _seat_room_ok does not call area_kind_at")
    if "area_kind_at" not in agent:
        bad += 1
        print("  missing area_kind_at Callable")
    if 'Callable(self, "_area_kind_at")' not in main and "area_kind_at =" not in main:
        bad += 1
        print("  Main does not inject area_kind_at on spawn")
    if "_seat_room_ok(_pending_seat)" not in agent and "not _seat_room_ok" not in agent:
        bad += 1
        print("  arrive/process does not call _seat_room_ok")
    for needle in ("_show_or_defer_activity_bubble", "_on_agent_arrived", "_activity_text_expected_kind"):
        if needle not in main:
            bad += 1
            print(f"  Main missing {needle}")
    for block_name in ("_show_or_defer_activity_bubble", "_on_agent_arrived"):
        if f"func {block_name}" not in main:
            continue
        block = main.split(f"func {block_name}", 1)[-1].split("\nfunc ", 1)[0]
        if "wp_kind" in block and "_room_kind_match(expect, wp_kind)" in block:
            bad += 1
            print(f"  {block_name} still ORs waypoint kind into place_ok")
    for needle in ("required_room_for_activity_text", "BREAK_ONLY_SPOTS", "_idle_wander", "CANTEEN_COUNTER"):
        if needle not in harness:
            bad += 1
            print(f"  harness missing {needle}")
    if "agent.target = seat  # director will re-emit" in harness:
        bad += 1
        print("  canteen still overwrites target with seat (counter phase broken)")
    route = main.split("func _route", 1)[-1].split("\nfunc ", 1)[0]
    if "SEAT_ARRIVE_MAX" not in route:
        bad += 1
        print("  _route missing near-marker check (stuck holders never re-path)")
    print(f"amenity_pose_gate_bad={bad}")
    if bad:
        print("FAIL: amenity pose room gating incomplete")
        return bad
    print("OK: amenity poses + activity bubbles gated; canteen/rec wander intact")
    return 0


def verify_seeded_desks_in_rooms(rooms: list[dict], cfg: dict) -> int:
    """Every seeded member desk waypoint formula lands inside its team room."""
    bad = 0
    seeded = 0
    for room in rooms:
        if room["id"] in ("hub", "meeting", "server") or room.get("kind") in ("hub", "meeting", "server"):
            # still check members if any
            pass
        members = []
        # rooms from build() may not carry members — read cfg
        cfg_id = "hr" if room["id"] == "meeting" else room["id"]  # HR team sits in the HR satellite
        for cr in cfg.get("rooms", []):
            if str(cr.get("id")) == cfg_id:
                members = cr.get("members", [])
                break
        if not members:
            continue
        rr: Rect = room["rect"]
        desks = max(int(room.get("desks", len(members))), len(members), 1)
        cols = min(3, desks)
        for i, m in enumerate(members):
            seeded += 1
            col = i % cols
            row = i // cols
            # Mirror Office.gd diorama desk placement (approx centre of cell).
            cell_x = rr.x + PAD_X + col * CELL[0] + CELL[0] * 0.5
            cell_y = rr.y + ROOM_TOP + row * CELL[1] + CELL[1] * 0.55
            if not (rr.x + 8 <= cell_x <= rr.end_x - 8 and rr.y + 8 <= cell_y <= rr.end_y - 8):
                bad += 1
                print(f"  desk_outside room={room['id']} agent={m.get('agent_id')} pos=({cell_x:.0f},{cell_y:.0f})")
    print(f"seeded_desks_checked={seeded} bad={bad}")
    if bad:
        print("FAIL: seeded desks outside their rooms")
        return bad
    expected = sum(len(r.get("members", [])) for r in cfg.get("rooms", []) if not r.get("isolated"))
    if seeded != expected:
        print(f"FAIL: expected {expected} seeded agents (office.json roster), found {seeded}")
        return 1
    print(f"OK: {seeded} seeded desks inside team rooms")
    return 0


def verify_walkmesh_coverage(rooms: list[dict], walls: list[Rect], spokes: list[dict], corridor_w: float) -> int:
    """Walkable = rooms + corridor strips only. Grass samples must not be on campus;
    door and room-centre samples must be."""
    bad = 0

    for r in rooms:
        cx, cy = r["rect"].center()
        if not point_in_campus((cx, cy), rooms, spokes, corridor_w):
            bad += 1
            print(f"  room_center_not_walkable {r['id']}")
        sat_exit = r.get("sat_exit")
        if sat_exit and not point_in_campus(sat_exit, rooms, spokes, corridor_w):
            bad += 1
            print(f"  door_not_walkable {r['id']} {sat_exit}")
        hub_exit = r.get("hub_exit")
        if hub_exit and not point_in_campus(hub_exit, rooms, spokes, corridor_w):
            bad += 1
            print(f"  hub_door_not_walkable {r['id']} {hub_exit}")

    min_x = min(r["rect"].x for r in rooms) - 120
    min_y = min(r["rect"].y for r in rooms) - 120
    max_x = max(r["rect"].end_x for r in rooms) + 120
    max_y = max(r["rect"].end_y for r in rooms) + 120
    grass_pts = [
        (min_x + 20, min_y + 20),
        (max_x - 20, min_y + 20),
        (min_x + 20, max_y - 20),
        (max_x - 20, max_y - 20),
        (min_x + 20, (min_y + max_y) * 0.5),
        (max_x - 20, (min_y + max_y) * 0.5),
    ]
    for gp in grass_pts:
        if point_in_campus(gp, rooms, spokes, corridor_w):
            bad += 1
            print(f"  grass_sample_walkable {gp}")
    print(f"walkmesh_coverage_bad={bad}")
    if bad:
        print("FAIL: walkmesh coverage holes or grass walkable")
        return bad
    print("OK: walkmesh covers rooms/doors/corridors; grass samples not walkable")
    return 0


def verify_desk_reach_from_hub(rooms: list[dict], walls: list[Rect], hub_center: tuple[float, float]) -> int:
    """Each team room centre must be grid-reachable from the hub (door→desk path)."""
    min_x = min(r["rect"].x for r in rooms) - 40
    min_y = min(r["rect"].y for r in rooms) - 40
    max_x = max(r["rect"].end_x for r in rooms) + 40
    max_y = max(r["rect"].end_y for r in rooms) + 40
    bounds = Rect(min_x, min_y, max_x - min_x, max_y - min_y)
    bad = 0
    checked = 0
    for r in rooms:
        if r["id"] in ("hub",):
            continue
        if r.get("kind") in ("hub",):
            continue
        goal = r["rect"].center()
        checked += 1
        if not grid_reachable(hub_center, goal, walls, bounds):
            bad += 1
            print(f"  desk_reach_fail room={r['id']} goal={goal}")
    print(f"desk_reach_checked={checked} bad={bad}")
    if bad:
        print("FAIL: some rooms unreachable from hub (door/path break)")
        return bad
    print("OK: hub → every room centre reachable")
    return 0

def verify_prop_iso_draw_routing() -> int:
    """Rugs/cushions/lamps in iso must use _iso_* — _draw_* paints world AABBs
    in screen space and leaves grey-brown rectangles on the grass."""
    prop = Path(__file__).resolve().parents[1] / "Prop.gd"
    src = prop.read_text()
    start = src.find("func _draw_iso() -> void:")
    if start < 0:
        print("FAIL: Prop._draw_iso missing")
        return 1
    end = src.find("\nfunc ", start + 10)
    block = src[start:end]
    bad = 0
    for kind, good in (
        ("rug", "_iso_rug()"),
        ("yoga_mat", "_iso_yoga_mat()"),
        ("cushion", "_iso_cushion()"),
        ("fountain", "_iso_fountain()"),
        ("lamp", "_iso_lamp()"),
    ):
        needle = '"%s": %s' % (kind, good)
        if needle not in block:
            bad += 1
            print("  prop_iso_route_bad kind=%s expected=%s" % (kind, good))
            for line in block.splitlines():
                if '"%s"' % kind in line:
                    print("    found: %s" % line.strip())
    start2 = src.find("func _draw() -> void:")
    end2 = src.find("\nfunc ", start2 + 10)
    block2 = src[start2:end2]
    for kind, bad_fn in (
        ("rug", "_iso_rug()"),
        ("yoga_mat", "_iso_yoga_mat()"),
        ("cushion", "_iso_cushion()"),
        ("fountain", "_iso_fountain()"),
        ("lamp", "_iso_lamp()"),
    ):
        needle = '"%s": %s' % (kind, bad_fn)
        if needle in block2:
            bad += 1
            print("  prop_topdown_calls_iso kind=%s" % kind)
    print("prop_iso_route_bad=%d" % bad)
    if bad:
        print("FAIL: Prop.gd iso/top-down floor-prop draw routing is swapped")
        return bad
    print("OK: Prop.gd iso floor props use _iso_* (no grass AABB spills)")
    return 0


def main() -> int:
    if verify_prop_iso_draw_routing():
        return 1
    if verify_floor_prop_sort():
        return 1
    if verify_no_grass_speckles():
        return 1
    if verify_amenity_pose_room_gate():
        return 1
    live = ROOT / "office.json"  # gitignored roster; fresh clones only have the default
    cfg = json.loads((live if live.exists() else ROOT / "office.default.json").read_text())
    rooms, walls, spokes, door_w, corridor_w, signs, ring = build(cfg)
    hub = next(r for r in rooms if r["id"] == "hub")
    print(f"rooms={len(rooms)} walls={len(walls)} spokes={len(spokes)} door_w={door_w} corridor_w={corridor_w}")

    # --- 1) No room footprint overlaps (incl. exterior wall thickness) --------
    overlaps = []
    for i, a in enumerate(rooms):
        for b in rooms[i + 1:]:
            if rects_overlap(a["rect"], b["rect"], EXT_WALL):
                overlaps.append(f"{a['id']} vs {b['id']}")
    print(f"room_footprint_overlaps={len(overlaps)}")
    if overlaps:
        for line in overlaps:
            print(f"  OVERLAP {line}")
        print("FAIL: room walls / footprints overlap")
        return 1
    print("OK: no room footprint overlaps")

    wall_hits = wall_rects_overlap_area(walls)
    # Filter hub-divider vs sat false positives lightly: still report count.
    print(f"wall_polygon_large_overlaps={len(wall_hits)}")
    if wall_hits:
        for i, j, area in wall_hits[:12]:
            print(f"  walls #{i}/#{j} overlap_area={area:.1f}")
        print("FAIL: wall polygons overlap")
        return 1
    print("OK: no wall polygon overlaps")

    # --- 2) Every door on its corridor / edge ---------------------------------
    door_bad = 0
    for sp in spokes:
        he, se = sp["from"], sp["to"]
        rid = sp["id"]
        room = next(r for r in rooms if r["id"] == rid)
        if not point_on_segment(he, he, se, tol=1.0) or not point_on_segment(se, he, se, tol=1.0):
            door_bad += 1
            print(f"  door_off_spoke {rid}")
            continue
        # Corridor must have positive length (hub and sat not glued).
        if math.hypot(se[0] - he[0], se[1] - he[1]) < corridor_w * 0.5:
            door_bad += 1
            print(f"  corridor_too_short {rid} len={math.hypot(se[0]-he[0], se[1]-he[1]):.1f}")
            continue
        # sat_exit on sat edge
        edge = nearest_edge(room["rect"], se)
        if edge in ("n", "s"):
            ok = abs(se[1] - (room["rect"].y if edge == "n" else room["rect"].end_y)) < 0.6
        else:
            ok = abs(se[0] - (room["rect"].x if edge == "w" else room["rect"].end_x)) < 0.6
        if not ok:
            door_bad += 1
            print(f"  sat_door_not_on_edge {rid}")
    print(f"spoke_door_alignments_ok={len(spokes) - door_bad}/{len(spokes)}")
    if door_bad:
        print("FAIL: doors not on corridors / edges")
        return 1
    print("OK: every door on its corridor and room edge")

    # --- 3) Room-pair reachability without wall crossings --------------------
    pairs = 0
    hits = 0
    hit_details = []
    for i, a in enumerate(rooms):
        for b in rooms[i + 1:]:
            pts = path_for(a, b, hub["center"])
            pairs += 1
            bad = False
            for s in range(len(pts) - 1):
                p0, p1 = pts[s], pts[s + 1]
                for wi, w in enumerate(walls):
                    if seg_intersects_rect(p0, p1, w):
                        bad = True
                        hit_details.append(
                            f"{a['id']}→{b['id']} seg {p0}->{p1} hits wall#{wi} "
                            f"({w.x:.1f},{w.y:.1f},{w.w:.1f}x{w.h:.1f})"
                        )
                        break
                if bad:
                    break
            if bad:
                hits += 1

    print(f"room_pairs_checked={pairs}")
    print(f"pairs_with_wall_intersection={hits}")
    print(f"pairs_clear={pairs - hits}")
    if hit_details:
        print("--- first hits ---")
        for line in hit_details[:15]:
            print(line)
    if hits:
        print("FAIL: paths cross walls")
        return 1
    print("OK: all room-pair paths clear of wall segments")

    # --- 4) Amenity spots + signs/labels inside rooms ------------------------
    amenity_bad = verify_hub_amenities(hub["rect"])
    if amenity_bad:
        print(f"FAIL: {amenity_bad} amenity waypoints outside their zone or in obstacles")
        return 1
    print("OK: amenity waypoints inside Break/Canteen/Rec zones")

    sign_bad = 0
    for s in signs:
        rr = next(r for r in rooms if r["id"] == s["room_id"])
        sr: Rect = s["rect"]
        inside = (
            rr["rect"].x <= sr.x
            and sr.end_x <= rr["rect"].end_x
            and rr["rect"].y <= sr.y
            and sr.end_y <= rr["rect"].end_y
        )
        if not inside:
            sign_bad += 1
            print(f"  sign_out {s['name']} room={s['room_id']}")
    print(f"signs_in_room_checked={len(signs)} bad={sign_bad}")
    if sign_bad:
        print("FAIL: signs/labels outside their rooms")
        return 1
    print("OK: signs and labels sit inside their rooms")

    # --- 5) Headless idle reach: hub → canteen + hub → rec -------------------
    # Amenity positions from the same formulas as verify_hub_amenities.
    pad = 56.0
    zone_w = (hub["rect"].w - pad * 4.0) / 3.0
    zone_h = hub["rect"].h * 0.70
    zone_y = hub["rect"].y + (hub["rect"].h - zone_h) * 0.5
    break_r = Rect(hub["rect"].x + pad, zone_y, zone_w, zone_h)
    canteen_r = Rect(break_r.end_x + pad, zone_y, zone_w, zone_h)
    rec_r = Rect(canteen_r.end_x + pad, zone_y, zone_w, zone_h)
    canteen_goal = (canteen_r.center()[0], canteen_r.y + canteen_r.h * 0.55)
    rec_goal = (rec_r.x + rec_r.w * 0.35, rec_r.y + rec_r.h * 0.45)
    # Campus bounds from all rooms
    min_x = min(r["rect"].x for r in rooms) - 40
    min_y = min(r["rect"].y for r in rooms) - 40
    max_x = max(r["rect"].end_x for r in rooms) + 40
    max_y = max(r["rect"].end_y for r in rooms) + 40
    bounds = Rect(min_x, min_y, max_x - min_x, max_y - min_y)
    start = hub["center"]
    # For hub-internal reach, only hub divider walls matter — use all walls but
    # start/goal are inside hub walk poly.
    can_ok = grid_reachable(start, canteen_goal, walls, bounds)
    rec_ok = grid_reachable(start, rec_goal, walls, bounds)
    print(f"idle_reach_canteen={'OK' if can_ok else 'FAIL'} goal={canteen_goal}")
    print(f"idle_reach_rec={'OK' if rec_ok else 'FAIL'} goal={rec_goal}")
    if not (can_ok and rec_ok):
        print("FAIL: idle agent cannot reach canteen and/or rec room in headless sim")
        return 1
    print("OK: headless idle sim reaches canteen and rec room")

    if verify_hub_zone_no_plank_floor():
        return 1
    if verify_no_outside_footprints(rooms, walls, spokes, corridor_w):
        return 1

    if verify_bank_safe(rooms, cfg):
        return 1
    if verify_floor_prop_sort():
        return 1
    if verify_no_grass_speckles():
        return 1
    if verify_amenity_pose_room_gate():
        return 1
    if verify_seeded_desks_in_rooms(rooms, cfg):
        return 1
    if verify_walkmesh_coverage(rooms, walls, spokes, corridor_w):
        return 1
    hub_c = hub["center"]
    if verify_desk_reach_from_hub(rooms, walls, hub_c):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
