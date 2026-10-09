## ANSI SGR escape sequences -> Godot RichTextLabel BBCode.
##
## Supports: reset (0), bold (1), dim (2), italic (3), underline (4),
## 22/23/24 resets, 16 foreground/background colours (30-37, 90-97, 40-47,
## 100-107), 39/49 default colours, 256-colour (38;5;n / 48;5;n) and truecolour
## (38;2;r;g;b / 48;2;r;g;b). Other CSI/OSC sequences (cursor moves, clears,
## hyperlinks) are stripped. Literal '[' in text is escaped so log output can
## never inject BBCode.
##
## Usage: const Ansi := preload("res://ansi.gd"); label.append_text(Ansi.to_bbcode(line))
extends RefCounted

## Terminal palette (One Dark-ish) for codes 30-37 / 90-97.
const PALETTE: Array[String] = [
	"#3f4451", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#d7dae0",  # normal
	"#5c6370", "#ff7b86", "#b5e890", "#ffd68a", "#7cc4ff", "#de8ef5", "#6fd6e3", "#ffffff",  # bright
]

static var _csi: RegEx = null


static func _get_regex() -> RegEx:
	if _csi == null:
		_csi = RegEx.new()
		# group 1: CSI params, group 2: CSI final byte; or an OSC sequence.
		_csi.compile("\\x1b\\[([0-9;?]*)[ -/]*([@-~])|\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)|\\x1b[()][A-Za-z0-9]|\\x1b[=>]")
	return _csi


static func escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


static func _xterm256(n: int) -> String:
	if n < 16:
		return PALETTE[n]
	if n < 232:
		var i := n - 16
		var steps := [0, 95, 135, 175, 215, 255]
		var c := Color8(steps[int(i / 36.0) % 6], steps[int(i / 6.0) % 6], steps[i % 6])
		return "#" + c.to_html(false)
	var g := 8 + (n - 232) * 10
	return "#" + Color8(g, g, g).to_html(false)


## Converts one chunk of terminal output to BBCode.
static func to_bbcode(text: String) -> String:
	var re := _get_regex()
	var out := ""
	var pos := 0
	var st := {"b": false, "d": false, "i": false, "u": false, "fg": "", "bg": ""}
	var open := ""  # closing tags for currently open state, innermost first

	for m in re.search_all(text):
		out += escape_bbcode(text.substr(pos, m.get_start() - pos))
		pos = m.get_end()
		if m.get_string(2) != "m":
			continue  # non-SGR sequence: drop it
		out += open
		_apply_sgr(st, m.get_string(1))
		var tags := _open_tags(st)
		out += tags[0]
		open = tags[1]
	out += escape_bbcode(text.substr(pos))
	out += open
	return out


static func _apply_sgr(st: Dictionary, params: String) -> void:
	var codes: PackedStringArray = params.split(";") if params != "" else PackedStringArray(["0"])
	var k := 0
	while k < codes.size():
		var c := codes[k].to_int() if codes[k] != "" else 0
		match c:
			0:
				st.b = false; st.d = false; st.i = false; st.u = false; st.fg = ""; st.bg = ""
			1: st.b = true
			2: st.d = true
			3: st.i = true
			4: st.u = true
			22:
				st.b = false; st.d = false
			23: st.i = false
			24: st.u = false
			39: st.fg = ""
			49: st.bg = ""
			38, 48:
				var colour := ""
				if k + 2 < codes.size() and codes[k + 1] == "5":
					colour = _xterm256(clampi(codes[k + 2].to_int(), 0, 255))
					k += 2
				elif k + 4 < codes.size() and codes[k + 1] == "2":
					colour = "#" + Color8(codes[k + 2].to_int(), codes[k + 3].to_int(), codes[k + 4].to_int()).to_html(false)
					k += 4
				if c == 38:
					st.fg = colour
				else:
					st.bg = colour
			_:
				if c >= 30 and c <= 37:
					st.fg = PALETTE[c - 30]
				elif c >= 90 and c <= 97:
					st.fg = PALETTE[c - 90 + 8]
				elif c >= 40 and c <= 47:
					st.bg = PALETTE[c - 40]
				elif c >= 100 and c <= 107:
					st.bg = PALETTE[c - 100 + 8]
		k += 1


## Returns [opening_tags, closing_tags] for a style state.
static func _open_tags(st: Dictionary) -> Array[String]:
	var o := ""
	var cl := ""
	var fg: String = st.fg
	if st.d and fg == "":
		fg = "#7f848e"
	if st.bg != "":
		o += "[bgcolor=%s]" % st.bg
		cl = "[/bgcolor]" + cl
	if fg != "":
		o += "[color=%s]" % fg
		cl = "[/color]" + cl
	if st.b:
		o += "[b]"
		cl = "[/b]" + cl
	if st.i:
		o += "[i]"
		cl = "[/i]" + cl
	if st.u:
		o += "[u]"
		cl = "[/u]" + cl
	return [o, cl]


## Removes every escape sequence (for speech bubbles etc).
static func strip(text: String) -> String:
	return _get_regex().sub(text, "", true)
