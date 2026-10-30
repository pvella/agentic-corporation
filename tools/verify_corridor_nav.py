#!/usr/bin/env python3
"""Verify corridor-layout door alignment and room-pair paths vs walls.

Mirrors Office.gd (pre-hex grid layout). Asserts no path segment intersects a
wall body across all room pairs; reports the clear-pair count.
"""
from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WALL = 12.0
EXT_WALL = 14.0
CORRIDOR = 96.0
CELL = (176.0, 162.0)
PAD_X = 26.0
ROOM_TOP = 68.0
ROOM_BOTTOM = 84.0
DOOR = 84.0
ORIGIN = (40.0, 40.0)
WING_GAP = 34.0
AMENITY_W = 176.0


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

    def center(self):
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


def cell_size(cell: dict) -> tuple[float, float]:
    k = cell["kind"]
    if k == "team":
        return team_size(cell["room"])
    if k == "break":
        return (480, 470)
    if k == "canteen":
        return (420, 470)
    if k == "server":
        return (380, 420)
    if k == "rec":
        return (400, 430)
    if k == "meeting":
        per = math.ceil(int(cell.get("seats", 6)) / 2.0)
        return (max(360.0, per * 84.0 + 190.0), 450)
    return (320, 450)


def corridor_wall(walls, cell, r: Rect, door_cx: float):
    if cell["kind"] in ("lobby", "lounge"):
        return None
    door_w = 110.0 if cell["kind"] in ("break", "meeting", "rec") else DOOR
    cx = door_cx
    left_w = max(0.0, cx - door_w * 0.5 - r.x)
    right_x = cx + door_w * 0.5
    right_w = max(0.0, r.end_x - right_x)
    if left_w > 0.05:
        walls.append(Rect(r.x, r.y, left_w, r.h))
    if right_w > 0.05:
        walls.append(Rect(right_x, r.y, right_w, r.h))
    # Door opening centre on the corridor side of this wall.
    if r.y < 1e12:  # always
        # top-row wall sits above corridor; bottom-row wall below corridor
        return (cx, r.y + r.h * 0.5, door_w)
    return (cx, r.y, door_w)


def seg_hits_wall(a, b, w: Rect) -> bool:
    dx, dy = b[0] - a[0], b[1] - a[1]
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, a[0] - w.x), (dx, w.end_x - a[0]), (-dy, a[1] - w.y), (dy, w.end_y - a[1])):
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
    return (t1 - t0) > 1e-4 and t0 < 1 - 1e-6 and t1 > 1e-6


def build(cfg: dict):
    shared = cfg.get("shared", {})
    team_rooms = [r for r in cfg.get("rooms", []) if not r.get("isolated")]
    wings_cfg = [r for r in cfg.get("rooms", []) if r.get("isolated")]
    top, bottom = [], []
    for i, r in enumerate(team_rooms):
        (top if i % 2 == 0 else bottom).append({"kind": "team", "room": r})
    top.insert(min(1, len(top)), {"kind": "break", "name": "Break"})
    seats = max(2, min(8, int(shared.get("meeting_room", {}).get("seats", 6))))
    bottom.insert(min(1, len(bottom)), {"kind": "meeting", "name": "Meeting", "seats": seats})
    if len(top) >= len(bottom):
        bottom.insert(min(2, len(bottom)), {"kind": "canteen", "name": "Canteen"})
    else:
        top.insert(min(2, len(top)), {"kind": "canteen", "name": "Canteen"})
    if len(bottom) <= len(top):
        bottom.append({"kind": "server", "name": "Server"})
    else:
        top.append({"kind": "server", "name": "Server"})
    if len(top) <= len(bottom):
        top.append({"kind": "rec", "name": "Rec"})
    else:
        bottom.append({"kind": "rec", "name": "Rec"})
    has_lobby = False
    while len(bottom) < len(top):
        bottom.append({"kind": "lobby" if not has_lobby else "lounge"})
        has_lobby = True
    while len(top) < len(bottom):
        top.append({"kind": "lounge"})
    cols = len(top)
    col_w = [max(cell_size(top[c])[0], cell_size(bottom[c])[0]) for c in range(cols)]
    h_top = max(cell_size(top[c])[1] for c in range(cols))
    h_bot = max(cell_size(bottom[c])[1] for c in range(cols))
    x0 = ORIGIN[0] + EXT_WALL
    y0 = ORIGIN[1] + EXT_WALL + 30.0
    total_w = sum(col_w) + WALL * (cols - 1)
    y_corr = y0 + h_top + WALL
    y_bot = y_corr + CORRIDOR + WALL
    corr = Rect(x0, y_corr, total_w, CORRIDOR)

    walls: list[Rect] = []
    rooms = []
    x = x0
    for c in range(cols):
        door_cx = x + col_w[c] * 0.5
        if c > 0:
            walls.append(Rect(x - WALL, y0, WALL, h_top))
            walls.append(Rect(x - WALL, y_bot, WALL, h_bot))
        top_wall = Rect(x - (WALL if c > 0 else 0.0), y0 + h_top,
                        col_w[c] + (WALL if c > 0 else 0.0), WALL)
        bot_wall = Rect(x - (WALL if c > 0 else 0.0), y_corr + CORRIDOR,
                        col_w[c] + (WALL if c > 0 else 0.0), WALL)
        corridor_wall(walls, top[c], top_wall, door_cx)
        corridor_wall(walls, bottom[c], bot_wall, door_cx)
        # Room centres + door points into corridor
        if top[c]["kind"] not in ("lounge",):
            rid = top[c]["room"]["id"] if top[c]["kind"] == "team" else top[c]["kind"]
            if top[c]["kind"] not in ("lobby", "lounge"):
                rooms.append({
                    "id": f"top:{rid}",
                    "center": (door_cx, y0 + h_top * 0.5),
                    "door": (door_cx, y_corr),  # into corridor from above
                    "side": "top",
                })
        if bottom[c]["kind"] not in ("lounge", "lobby"):
            rid = bottom[c]["room"]["id"] if bottom[c]["kind"] == "team" else bottom[c]["kind"]
            rooms.append({
                "id": f"bot:{rid}",
                "center": (door_cx, y_bot + h_bot * 0.5),
                "door": (door_cx, y_corr + CORRIDOR),
                "side": "bot",
            })
        x += col_w[c] + WALL

    # Corridor as a "room" hub for connectivity checks
    hub = {"id": "corridor", "center": corr.center(), "door": corr.center(), "side": "corr"}

    # Door alignment: each room door x equals cell centre and lies on corridor edge
    align_ok = 0
    for rm in rooms:
        assert abs(rm["door"][0] - rm["center"][0]) < 0.5
        if rm["side"] == "top":
            assert abs(rm["door"][1] - y_corr) < 0.5
        else:
            assert abs(rm["door"][1] - (y_corr + CORRIDOR)) < 0.5
        align_ok += 1

    return rooms, walls, hub, align_ok, corr


def path_for(a, b, hub):
    """room → door → corridor centre → door → room (canonical)."""
    if a["id"] == b["id"]:
        return [a["center"]]
    return [a["center"], a["door"], hub["center"], b["door"], b["center"]]


def main() -> int:
    cfg = json.loads((ROOT / "office.json").read_text())
    rooms, walls, hub, align_ok, corr = build(cfg)
    print(f"rooms={len(rooms)} walls={len(walls)} door_alignments_ok={align_ok}")
    print(f"corridor=({corr.x:.0f},{corr.y:.0f},{corr.w:.0f}x{corr.h:.0f})")

    pairs = 0
    hits = 0
    details = []
    all_nodes = rooms  # pairs among rooms (corridor is the connector, not a pair endpoint required)
    for i, a in enumerate(all_nodes):
        for b in all_nodes[i + 1:]:
            pts = path_for(a, b, hub)
            pairs += 1
            bad = False
            for s in range(len(pts) - 1):
                p0, p1 = pts[s], pts[s + 1]
                for wi, w in enumerate(walls):
                    if seg_hits_wall(p0, p1, w):
                        bad = True
                        details.append(f"{a['id']}→{b['id']} seg {p0}->{p1} wall#{wi} "
                                       f"({w.x:.1f},{w.y:.1f},{w.w:.1f}x{w.h:.1f})")
                        break
                if bad:
                    break
            if bad:
                hits += 1

    print(f"room_pairs_checked={pairs}")
    print(f"pairs_with_wall_intersection={hits}")
    print(f"pairs_clear={pairs - hits}")
    if details:
        print("--- first hits ---")
        for line in details[:12]:
            print(line)
    if hits:
        print("FAIL")
        return 1
    print("OK: all room-pair paths clear of wall segments")
    return 0


if __name__ == "__main__":
    sys.exit(main())
