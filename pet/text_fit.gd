extends RefCounted
## 文字排版口径：**一行文字必须待在它所在高度的圆弦内**。
##
## 为什么需要它（实测 2026-10-09）：原先文字用一个固定 **180px 宽**的盒子居中，
## 而那个盒子比圆本身还宽（idle 直径 148），且 `draw_string` **不会自动缩字号** ⇒
## 数字一变长就出圈：
##   "today 11992 keys"    size20 = 166px  > idle 直径 148  ✗（用户就是看到这个）
##   "today 99999999 keys" size20 = 201px  > sleepy 直径 132  ✗
##
## 口径只写在这里，`pet/pet.gd` 调它，`pet/test_text_fit.gd` 单测它。

## 圆心为原点时，y 高度处圆的半弦长（y 在圆外则返回 0）
static func chord_half_width(radius: float, y: float) -> float:
	var d := radius * radius - y * y
	return sqrt(d) if d > 0.0 else 0.0

## 一行文字可用的总宽度（两侧各留 margin）
static func width_budget(radius: float, y_top: float, margin: float) -> float:
	return 2.0 * maxf(chord_half_width(radius, y_top) - margin, 0.0)

## `width_budget` 的**反函数**：要让这行文字放得下，圆至少要多大？
## 由 width_budget(r, y) ≥ w 解出：r ≥ sqrt((w/2 + margin)² + y²)
##
## 这是“圈变大”那条路的依据：数字变长时先拿它把圆撑大，
## 而不是一上来就缩字号（字号是主角，圆是配角）。
static func radius_needed(text_width: float, y_top: float, margin: float) -> float:
	var half := text_width / 2.0 + margin
	return sqrt(half * half + y_top * y_top)

## 好几行一起看：需要多大的圆？（取各行需求的最大值）
## lines: [{"text": String, "dy": float, "base": int}, ...]
static func radius_for_lines(font: Font, lines: Array, margin: float) -> float:
	var need := 0.0
	for l in lines:
		var w: float = font.get_string_size(l["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, int(l["base"])).x
		need = maxf(need, radius_needed(w, top_y(float(l["dy"]), int(l["base"])), margin))
	return need

## 把一行文字缩到能放进圆弦里，返回字号（不小于 min_size）。
## 传 y_top 而不是基线：文字**顶端**那一行最窄，按它算才保守。
##
## 注意：这是**兜底**路径 —— 正常情况应当先把圆撑大（见 radius_needed）；
## 只有圆已经到窗口能装下的上限时，才回头缩字号。
static func fit_size(font: Font, text: String, base_size: int, min_size: int,
		radius: float, y_top: float, margin: float) -> int:
	var budget := width_budget(radius, y_top, margin)
	var size := base_size
	while size > min_size and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > budget:
		size -= 1
	return size

## 一行文字（相对圆心的基线 y、基础字号）的顶端 y。
## 口径：用字号近似 ascent —— 宁可多留一点，也不要压线。
static func top_y(baseline_y: float, base_size: int) -> float:
	return baseline_y - float(base_size)
