extends SceneTree
## 文字排版口径的单测：headless 就能跑，所以能进 CI（不需要真实桌面）。
##
##   godot --headless --path pet --script test_text_fit.gd
##
## 回归对象（用户报的）：数字一变长，英文字母就跑到圆外。
## 原实现用固定 180px 宽的盒子 + 固定字号（盒子比圆还宽、draw_string 也不缩字号）。

## 注意：显式 preload，不依赖工程的类缓存（class_name 要编辑器导入过才登记）
const TextFit := preload("res://text_fit.gd")

var failed := 0

func check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failed += 1

func _init() -> void:
	var font := ThemeDB.fallback_font
	print("===== 文字排版口径自检 =====\n")

	# ---- 1) 弦长几何 ----
	check(is_equal_approx(TextFit.chord_half_width(100.0, 0.0), 100.0), "弦长：过圆心处就是半径")
	check(is_equal_approx(TextFit.chord_half_width(100.0, 100.0), 0.0), "弦长：正好落在圆边上为 0")
	check(is_equal_approx(TextFit.chord_half_width(100.0, 130.0), 0.0), "弦长：圆外也是 0（不返回负数）")

	# ---- 2) 每个状态 × 每个数字长度：文字必须放进圆弦 ----
	var radii := { "idle": 74.0, "typing": 80.0, "excited": 88.0, "sleepy": 66.0 }
	for state in radii:
		var radius: float = radii[state]
		for n in [0, 9, 11992, 123456, 1234567, 99999999]:
			var text := "today %d keys" % n
			var y_top := TextFit.top_y(0.0, 20)
			var size := TextFit.fit_size(font, text, 20, 10, radius, y_top, 6.0)
			var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			var budget := TextFit.width_budget(radius, y_top, 6.0)
			check(w <= budget + 0.5, "%s n=%-9d → size%-2d 宽 %.0f ≤ 预算 %.0f" % [state, n, size, w, budget])
			# ---- 3) 选中的必须是「能放下的最大字号」（否则白白牺牲可读性）----
			if size < 20:
				var w_up: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size + 1).x
				check(w_up > budget, "%s n=%-9d → size%d 放不下（size%d 已是最大）" % [state, n, size + 1, size])

	# ---- 4) 再长也不许缩到看不见（下限 10）----
	var tiny := TextFit.fit_size(font, "today 999999999999 keys", 20, 10, 66.0, TextFit.top_y(0.0, 20), 6.0)
	check(tiny == 10, "极端长也只到下限 10（实测 %d）" % tiny)

	# ---- 5) 第二行（kpm + 状态名）同样要放得下 ----
	for kmp_v in [0, 80, 1234, 9999]:
		var text := "%.0f kpm  excited" % float(kmp_v)
		var y_top := TextFit.top_y(22.0, 14)
		var size := TextFit.fit_size(font, text, 14, 10, 74.0, y_top, 6.0)
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var budget := TextFit.width_budget(74.0, y_top, 6.0)
		check(w <= budget + 0.5, "第二行 kpm=%d → size%d 宽 %.0f ≤ 预算 %.0f" % [kmp_v, size, w, budget])

	print("\n%s（失败 %d 项）" % ["全部通过 ✅" if failed == 0 else "有失败 ❌", failed])
	quit(0 if failed == 0 else 1)
