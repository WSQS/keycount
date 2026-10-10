extends SceneTree
## 文字排版口径的单测：headless 就能跑，所以能进 CI（不需要真实桌面）。
##
##   godot --headless --path pet --script test_text_fit.gd
##
## 口径（2026-10-10 定）：
##   数字是这个宠物的主角 ⇒ **先按文字把圆撑大**，而不是把字缩小。
##   只有圆已经到窗口能装下的上限（CIRCLE_MAX_RADIUS）时，才回头缩字号兜底。
##
## 回归对象（用户报的）：数字一变长，英文字母就跑到圆外。
## 旧实现用固定 180px 宽的盒子 + 固定字号（盒子比圆还宽、draw_string 也不缩字号）。

## 注意：显式 preload，不依赖工程的类缓存（class_name 要编辑器导入过才登记）
const TextFit := preload("res://text_fit.gd")

var failed := 0

func check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failed += 1

func _init() -> void:
	var font := ThemeDB.fallback_font
	var margin := 6.0
	print("===== 文字排版口径自检 =====\n")

	# ---- 1) 弦长几何 ----
	check(is_equal_approx(TextFit.chord_half_width(100.0, 0.0), 100.0), "弦长：过圆心处就是半径")
	check(is_equal_approx(TextFit.chord_half_width(100.0, 100.0), 0.0), "弦长：正好落在圆边上为 0")
	check(is_equal_approx(TextFit.chord_half_width(100.0, 130.0), 0.0), "弦长：圆外也是 0（不返回负数）")

	# ---- 2) radius_needed 是 width_budget 的反函数（往返一致）----
	for w in [40.0, 120.0, 166.0, 201.0]:
		for y in [0.0, -14.0, -20.0, -40.0]:
			var r := TextFit.radius_needed(w, y, margin)
			var back := TextFit.width_budget(r, y, margin)
			check(absf(back - w) < 0.05, "往返：宽 %.0f / y %.0f → 需要半径 %.1f → 反算宽度 %.1f" % [w, y, r, back])

	# ---- 3) 核心口径：数字变长 ⇒ **需要的半径变大**，而字号保持基准 ----
	var prev_r := 0.0
	for n in [0, 9, 11992, 123456, 1234567, 99999999]:
		var lines := [{ "text": "today %d keys" % n, "dy": 0.0, "base": 20 }]
		var r := TextFit.radius_for_lines(font, lines, margin)
		check(r >= prev_r - 0.01, "n=%-9d → 需要半径 %.1f（不小于上一档 %.1f）" % [n, r, prev_r])
		prev_r = r
		# 只要还在窗口上限内，字号就该是基准 20（不该为了塞进小圆而缩字）
		if r <= 176.0:
			check(TextFit.fit_size(font, lines[0]["text"], 20, 10, r, TextFit.top_y(0.0, 20), margin) == 20,
					"n=%-9d → 半径 %.1f 够用时字号仍是 20" % [n, r])

	# ---- 4) 细节：8 位数的需求半径仍远小于窗口上限（所以现实中几乎不会缩字）----
	var r8 := TextFit.radius_for_lines(font, [{ "text": "today 99999999 keys", "dy": 0.0, "base": 20 }], margin)
	check(r8 < 176.0, "8 位数只需要半径 %.1f < 窗口上限 176（所以是圈变大，字不变）" % r8)

	# ---- 5) 兜底路径：圆顶到上限时，缩字号必须真的能塞下 ----
	var huge := "today 1234567890123456 keys"
	var r_cap := 176.0
	var size := TextFit.fit_size(font, huge, 20, 10, r_cap, TextFit.top_y(0.0, 20), margin)
	var w: float = font.get_string_size(huge, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	check(TextFit.radius_needed(w, TextFit.top_y(0.0, 20), margin) <= r_cap + 0.5,
			"顶到上限时缩字兜底：size%d 宽 %.0f 能塞进半径 %.0f" % [size, w, r_cap])
	check(size >= 10, "兜底也不会缩到看不见（下限 10，实测 %d）" % size)

	# ---- 6) 第二行（kpm + 状态名）同样算得出来 ----
	for kmp_v in [0, 80, 1234, 9999]:
		var text := "%.0f kpm  excited" % float(kmp_v)
		var r := TextFit.radius_for_lines(font, [{ "text": text, "dy": 22.0, "base": 14 }], margin)
		var w2: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		check(TextFit.width_budget(r, TextFit.top_y(22.0, 14), margin) >= w2 - 0.5,
				"第二行 kpm=%d → 半径 %.1f 放得下（宽 %.0f）" % [kmp_v, r, w2])

	print("\n%s（失败 %d 项）" % ["全部通过 ✅" if failed == 0 else "有失败 ❌", failed])
	quit(0 if failed == 0 else 1)
