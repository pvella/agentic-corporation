# Graphics / nav full audit checklist (PR #20)

Branch: `feature/graphics-polish`. Keep hub-spoke campus; minimal fixes, no redesign.

## (a) Graphics — rooms + overview at overview & zoomed scale

| Check | Status | Notes |
|-------|--------|-------|
| Overview render (campus) | ✅ | Before/after under `/workspace/graphics-polish/` |
| Zoomed Executive | ✅ | CoS at desk no longer under rug |
| Zoomed Engineering | ✅ | Floor rug sorts under agents |
| Zoomed Product & Design | ✅ | |
| Zoomed Operations | ✅ | |
| Zoomed Finance | ✅ | |
| Zoomed Special Projects | ✅ | |
| Zoomed Server / Meeting / Hub zones | ✅ | |
| No stray grey dots on grass | ✅ | Removed decorative grass speckles; inset + shortened lamps |
| No leftover floor/rug patches on grass | ✅ | `verify_no_outside_footprints` |
| Rugs/mats/cushions flat (z≈0) | ✅ | `_plane_top(0)`; cushions no longer `_box` |
| Floor props sort under agents | ✅ | NW `iso_anchor` + `z_index = -20` |
| Walls: no gaps at door/spoke joints | ✅ | Existing spoke/door align checks |
| Labels / bubbles vs signs | ⚠ monitor | Overview LOD hides note tags; watch overlaps in live |
| CoS visible at Executive desk | ✅ | Rug no longer covers chair/feet; 13 desks seeded |

## (b) Walkmesh — rebake from current geometry

| Check | Status | Notes |
|-------|--------|-------|
| Bake from `office.get_floor_outlines()` | ✅ | Runtime `_bake_navigation()` each layout build |
| No walkable grass | ✅ | `verify_walkmesh_coverage` grass samples |
| No holes inside rooms/corridors | ✅ | Room centres + doors on campus |
| Every door connects to its corridor | ✅ | `spoke_door_alignments_ok` |
| Desks / amenities / activity spots reachable in-room | ✅ | Amenity WP checks + desk reach from hub |

## (c) Walk paths + idle/work sim

| Check | Status | Notes |
|-------|--------|-------|
| Paths door-to-door (no wall crossings) | ✅ | Room-pair segment clear |
| No dead ends in grass | ✅ | Path-on-grass checks |
| Amenity poses only in correct rooms | ✅ | Near-arrive trusts WP; `_seat_room_ok` + `SEAT_EXPECTED_KINDS` |
| Activity bubbles only on arrival in-room | ✅ | Main `_show_or_defer_activity_bubble` |
| Idle visits Canteen + Rec | ✅ | `_idle_wander` + canteen counter→seat; `test_canteen_and_rec_visited_over_idle_cycles` |
| Yoga/meditate → Rec | ✅ | |
| Foosball/sofa/coffee → Break | ✅ | |
| Canteen eat → Canteen | ✅ | Seat meta + zone WPs |
| Work at own desk | ✅ | Desk seat + room kinds |
| Headless idle reach hub→canteen/rec | ✅ | Grid sim in `verify_hub_nav.py` |
| Hub → every room centre | ✅ | `verify_desk_reach_from_hub` |

## Permanent automated checks

`tools/verify_hub_nav.py` (run: `python3 tools/verify_hub_nav.py`):

1. Room / wall overlaps  
2. Door ↔ spoke alignment  
3. Room-pair paths clear of walls  
4. Amenity WPs + signs in rooms  
5. Idle reach canteen/rec  
6. No outside footprints  
7. Floor prop sort (anchor + z_index + flat cushion/rug)  
8. No grass speckles  
9. Amenity pose room gate in Agent/Main  
10. 13 seeded desks in rooms  
11. Walkmesh coverage (no grass walkable)  
12. Desk reach from hub  

## Issues found → fixed (this pass)

1. **CoS “missing” / under rug** — rugs used centre `iso_anchor` and sorted over chairs; cushions were raised `_box`. → NW floor anchor, `z_index=-20`, flat cushions.  
2. **Grey dots on grass** — decorative `draw_circle` speckles + tall lamps near N walls projecting SE. → solid grass only; lamps inset/shortened.  
3. **Amenity poses in wrong rooms** — seat applied on near/stuck arrive without room check. → `_seat_room_ok` + injected `_area_kind_at`.  
4. **Audit gaps** — extended `verify_hub_nav.py` with permanent checks above; this checklist on the PR.

## Style

Hub-spoke campus retained (rectangular hub + satellite ring). No hex-fill redesign. Cozy diorama props kept with minimal placement tweaks only.
