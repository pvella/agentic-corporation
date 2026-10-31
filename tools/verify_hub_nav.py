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
    sofa = Rect(p[0] + m, e[1] - 50 - 46, sofa_w, 46); add_obs(sofa)
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
    for dx in (break_r.end_x + pad * 0.5 - WALL * 0.5, canteen_r.end_x + pad * 0.5 - WALL * 0.5):
        top_h = (zone_h - div_gap) * 0.5
        add_obs(Rect(dx, break_r.y, WALL, top_h))
        add_obs(Rect(dx, break_r.end_y - top_h, WALL, top_h))

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




def bank_safe_world_anchor(exec_rect: Rect, cos_desk_center_y: float | None = None) -> tuple[float, float]:
    """Mirror Main.gd `_bank_safe_world_anchor` (world space, pre-Iso)."""
    desk_y = exec_rect.y + 110.0 if cos_desk_center_y is None else cos_desk_center_y
    y = min(max(desk_y, exec_rect.y + 90.0), exec_rect.end_y - 90.0)
    return (exec_rect.x + 56.0, y)


def verify_bank_safe(rooms: list[dict], cfg: dict) -> int:
    """Fail if the Executive bank-safe world anchor is outside the Executive room."""
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
    sx, sy = bank_safe_world_anchor(er, desk_y)
    inside = er.x < sx < er.end_x and er.y < sy < er.end_y
    # Also keep a margin from door-side (north) and not past south wall.
    margin_ok = (sy >= er.y + 80.0) and (sy <= er.end_y - 80.0) and (sx >= er.x + 40.0)
    print(
        f"bank_safe_world=({sx:.1f},{sy:.1f}) executive=({er.x:.1f},{er.y:.1f},{er.w:.1f}x{er.h:.1f}) "
        f"{'OK' if inside and margin_ok else 'OUT'}"
    )
    if not (inside and margin_ok):
        print("FAIL: bank safe world anchor not inside Executive room")
        return 1
    print("OK: bank safe world anchor inside Executive room")
    return 0

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

    amenity_bad = verify_hub_amenities(hub["rect"])
    if amenity_bad:
        print(f"FAIL: {amenity_bad} amenity waypoints outside their zone or in obstacles")
        return 1
    print("OK: amenity waypoints inside Break/Canteen/Rec zones")

    if verify_bank_safe(rooms, cfg):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
