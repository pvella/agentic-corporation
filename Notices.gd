## Persistent store of important office events for the hub Notice Board.
## Newest-first; capped; written to a gitignored project-local JSON file.
class_name Notices
extends RefCounted

const FILE_NAME := ".office_notices.json"
const MAX_EVENTS := 100
const BOARD_PIN_COUNT := 7

signal changed

## Newest first. Each entry:
## {id, ts, kind, title, detail, icon, color, pending, meta}
var events: Array = []


func _path() -> String:
	var root := ProjectSettings.globalize_path("res://")
	if root.ends_with("/"):
		return root + FILE_NAME
	return root.path_join(FILE_NAME)


func load_from_disk() -> void:
	events.clear()
	var path := _path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Array:
		for item in parsed:
			if item is Dictionary:
				events.append(item)
	elif parsed is Dictionary and parsed.has("events") and parsed["events"] is Array:
		for item in parsed["events"]:
			if item is Dictionary:
				events.append(item)
	_trim()


func save_to_disk() -> void:
	var path := _path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Notices: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(events, "\t"))
	f.close()


func add(kind: String, title: String, detail: String = "", opts: Dictionary = {}) -> Dictionary:
	var entry := {
		"id": "n_%d_%d" % [Time.get_ticks_msec(), events.size()],
		"ts": Time.get_unix_time_from_system(),
		"kind": kind,
		"title": title,
		"detail": detail,
		"icon": str(opts.get("icon", _default_icon(kind))),
		"color": str(opts.get("color", _default_color(kind))),
		"pending": bool(opts.get("pending", false)),
		"meta": opts.get("meta", {}),
	}
	events.push_front(entry)
	_trim()
	save_to_disk()
	changed.emit()
	return entry


func resolve_ask(request_id: String) -> void:
	if request_id.is_empty():
		return
	var dirty := false
	for e in events:
		if not (e is Dictionary):
			continue
		if str(e.get("kind", "")) != "ask_human":
			continue
		var meta: Variant = e.get("meta", {})
		if meta is Dictionary and str(meta.get("request_id", "")) == request_id:
			e["pending"] = false
			var detail := str(e.get("detail", ""))
			if not detail.ends_with(" · handled"):
				e["detail"] = (detail + " · handled").strip_edges()
			dirty = true
	if dirty:
		save_to_disk()
		changed.emit()


func resolve_all_pending_asks_for(agent_id: String) -> void:
	var dirty := false
	for e in events:
		if not (e is Dictionary):
			continue
		if str(e.get("kind", "")) != "ask_human" or not bool(e.get("pending", false)):
			continue
		var meta: Variant = e.get("meta", {})
		if meta is Dictionary and str(meta.get("agent_id", "")) == agent_id:
			e["pending"] = false
			dirty = true
	if dirty:
		save_to_disk()
		changed.emit()


func latest(n: int = BOARD_PIN_COUNT) -> Array:
	var out: Array = []
	var limit := mini(n, events.size())
	for i in limit:
		out.append(events[i])
	return out


func format_time(ts: float) -> String:
	var unix := int(ts)
	var dt := Time.get_datetime_dict_from_unix_time(unix)
	return "%02d:%02d" % [int(dt.get("hour", 0)), int(dt.get("minute", 0))]


func _trim() -> void:
	while events.size() > MAX_EVENTS:
		events.pop_back()


func _default_icon(kind: String) -> String:
	match kind:
		"hire":
			return "✦"
		"fire":
			return "☠"
		"knowledge_add":
			return "📄"
		"knowledge_remove":
			return "🗑"
		"meeting_start":
			return "🤝"
		"meeting_end":
			return "✓"
		"ask_human":
			return "!"
		"task_ok":
			return "✔"
		"task_fail":
			return "✖"
		"error":
			return "⚠"
		_:
			return "•"


func _default_color(kind: String) -> String:
	match kind:
		"hire":
			return "#ffd54f"  # god-light gold
		"fire":
			return "#ef5350"
		"knowledge_add":
			return "#29b6f6"
		"knowledge_remove":
			return "#ef9a9a"
		"meeting_start":
			return "#ce93d8"
		"meeting_end":
			return "#b39ddb"
		"ask_human":
			return "#ffb74d"
		"task_ok":
			return "#81c784"
		"task_fail":
			return "#e57373"
		"error":
			return "#e06c75"
		_:
			return "#b0bec5"


static func fire_variant_label(variant: String) -> String:
	var v := variant.strip_edges().to_lower()
	match v:
		"ambulance":
			return "ambulance"
		"ufo":
			return "UFO"
		"stomp":
			return "stomp"
		"anvil":
			return "anvil"
		"trapdoor":
			return "trapdoor"
		"escort":
			return "escort"
		"":
			return "dismissed"
		_:
			return v
