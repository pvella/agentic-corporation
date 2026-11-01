## Headless unit test for ansi.gd:
##   godot --headless --path . --script res://tests/test_ansi.gd
extends SceneTree

const Ansi := preload("res://ansi.gd")


func _init() -> void:
	var cases := [
		["plain [text]", "plain [lb]text]"],
		["\u001b[32mline 1\u001b[0m", "[color=#98c379]line 1[/color]"],
		["\u001b[1;31mERR\u001b[0m ok", "[color=#e06c75][b]ERR[/b][/color] ok"],
		["\u001b[1mA\u001b[22mB", "[b]A[/b]B"],
		["\u001b[38;5;196mX\u001b[39mY", "[color=#ff0000]X[/color]Y"],
		["\u001b[38;2;1;2;3mZ\u001b[m", "[color=#010203]Z[/color]"],
		["\u001b[2K\u001b[1Gclear", "clear"],
		["\u001b[4;94mU", "[color=#7cc4ff][u]U[/u][/color]"],
	]
	var failed := 0
	for c: Array in cases:
		var got := Ansi.to_bbcode(c[0])
		if got != c[1]:
			failed += 1
			printerr("FAIL: %s\n  expected %s\n  got      %s" % [c[0].c_escape(), c[1], got])
	if Ansi.strip("\u001b[32mhi\u001b[0m") != "hi":
		failed += 1
		printerr("FAIL: strip")
	print("ansi tests: %d/%d passed" % [cases.size() + 1 - failed, cases.size() + 1])
	quit(1 if failed else 0)
