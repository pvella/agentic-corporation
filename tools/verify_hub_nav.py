#!/usr/bin/env python3
"""Verify hub-and-spoke door alignment and that room-pair paths never cross walls.

Mirrors Office.gd hub geometry. Asserts:
  1) each satellite door sits on the spoke/wall junction
  2) every simulated room↔room path has no segment intersecting a wall rect
Reports the count of verified pairs (non-zero exit on any hit).
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


def build(cfg: dict):
    shared = cfg.get("shared", {})
    seats = max(2, min(8, int(shared.get("meeting_room", {}).get("seats", 6))))
    team_rooms = [r for r in cfg.get("rooms", []) if not r.get("isolated")]
    hub_size = (1320.0, 700.0)
    hub = Rect(ORIGIN[0] + 760.0, ORIGIN[1] + 420.0, hub_size[0], hub_size[1])
    hub_c = hub.center()
    ring_rx, ring_ry = 1400.0, 780.0
    corridor_w = 78.0
    door_w = corridor_w + 10.0

    sat_specs = [
        {"kind": "meeting", "theta": -math.pi * 0.5, "id": "meeting"},
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

    walls: list[Rect] = []
    rooms = [{"id": "hub", "name": "Hub", "center": hub_c, "rect": hub}]
    hub_doors: list[tuple[float, float]] = []
    spokes = []

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
            per_side = math.ceil(seats / 2.0)
            sat_size = (max(360.0, per_side * 84.0 + 190.0), 400.0)
            rid, rname = "meeting", "Meeting Room"
        else:
            sat_size = (380.0, 390.0)
            rid, rname = "server", "Server Room"
        sc = (hub_c[0] + math.cos(theta) * ring_rx, hub_c[1] + math.sin(theta) * ring_ry)
        sat = Rect(sc[0] - sat_size[0] * 0.5, sc[1] - sat_size[1] * 0.5, sat_size[0], sat_size[1])
        dx, dy = sc[0] - hub_c[0], sc[1] - hub_c[1]
        hub_exit = snap_to_edge(hub, rect_exit(hub, dx, dy))
        sat_exit = snap_to_edge(sat, rect_exit(sat, -dx, -dy))
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
        })
        spokes.append({"from": hub_exit, "to": sat_exit, "width": corridor_w, "id": rid})

    walls += hub_perimeter(hub, hub_doors, door_w)
    return rooms, walls, spokes, door_w, corridor_w


def path_for(a: dict, b: dict, hub_center) -> list[tuple[float, float]]:
    """room → door(inside) → door → spoke → door → door(inside) → hub → …"""
    pts = [a["center"]]
    if a["id"] != "hub":
        pts += [a["sat_in"], a["sat_exit"], a["hub_exit"], a["hub_in"]]
    pts.append(hub_center)
    if b["id"] != "hub":
        pts += [b["hub_in"], b["hub_exit"], b["sat_exit"], b["sat_in"]]
    pts.append(b["center"])
    out = [pts[0]]
    for p in pts[1:]:
        if math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) > 0.5:
            out.append(p)
    return out


def main() -> int:
    cfg = json.loads((ROOT / "office.json").read_text())
    rooms, walls, spokes, door_w, corridor_w = build(cfg)
    hub = next(r for r in rooms if r["id"] == "hub")
    print(f"rooms={len(rooms)} walls={len(walls)} spokes={len(spokes)} door_w={door_w} corridor_w={corridor_w}")
    print(f"spoke_door_alignments_ok={len(spokes)}")

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
    return 0


if __name__ == "__main__":
    sys.exit(main())
