extends Node2D
# v0 占位宠物：先证明「链路 + 不抢焦点 + 全局抓键 + 透明」四件事都对。
# 美术后补 —— 这里就是一个会呼吸的圆，颜色和动作由打字速度驱动。

# 日志写在工程目录里，不用写死绝对路径 —— 这样整个工程可以随意搬家
const LOG_PATH := "run.log"
const SLEEPY_AFTER := 180.0   # 静默多久打瞌睡
const EXCITED_KPM := 400.0    # 多快算兴奋

var hook: KeyCountHook
var win: KeyCountWindow
var hwnd: int = 0

# 统计先只放内存；落盘入库是下一步
var total_today: int = 0
var by_key: Dictionary = {}
var _down_times: Array = []
var _last_key_time: float = 0.0
var state_name: String = "idle"

var _log: FileAccess = null
var _log_t: float = 0.0
var _focus_true_frames: int = 0
var _frames: int = 0
var _dragging: bool = false
# 关键对照：走「窗口焦点」这条路的按键有几个。
# 如果宠物真在抢焦点，你打的字会落到这里；如果这里一直是 0 而钩子数在涨，就不抢。
var _input_key_count: int = 0

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_input_key_count += 1

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _logline(s: String) -> void:
	if _log != null:
		_log.store_line("%7.2f %s" % [_now(), s])
		_log.flush()

func _ready() -> void:
	_log = FileAccess.open(ProjectSettings.globalize_path("res://") + LOG_PATH, FileAccess.WRITE)
	hwnd = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, 0)
	win = KeyCountWindow.new()
	_logline("hwnd=0x%X  prev_foreground=0x%X  foreground=0x%X" % [hwnd, win.get_prev_foreground(), win.get_foreground()])
	_logline("ex_style 之前 : %s" % win.describe_ex_style(hwnd))
	_logline("set_no_activate -> %s" % str(win.set_no_activate(hwnd, true)))
	_logline("ex_style 之后 : %s" % win.describe_ex_style(hwnd))
	get_window().set_flag(Window.FLAG_NO_FOCUS, true)
	# Godot 自己会在启动时激活窗口，NOACTIVATE 挡不住它，所以把焦点还回去
	_logline("第一帧 restore_prev_foreground -> %s" % str(win.restore_prev_foreground()))

	hook = KeyCountHook.new()
	hook.key_event.connect(_on_key_event)
	_logline("hook.start() -> %s" % str(hook.start()))
	# 順便验证扩展真的被加载了：键名表在 GDScript 侧也过一遍
	_logline("key_name_of(0x41, 0, false) = %s" % KeyCountHook.key_name_of(0x41, 0, false))
	_logline("key_name_of(0x0D, 0x1C, true) = %s" % KeyCountHook.key_name_of(0x0D, 0x1C, true))

func _on_key_event(key_name: String, vk: int, scancode: int, extended: bool, is_down: bool, repeated: bool) -> void:
	if not is_down or repeated:
		return
	total_today += 1
	by_key[key_name] = int(by_key.get(key_name, 0)) + 1
	_down_times.append(_now())
	_last_key_time = _now()
	_logline("KEY %-12s vk=0x%02X sc=0x%02X ext=%d" % [key_name, vk, scancode, 1 if extended else 0])

# 最近 30 秒的击键数换算成「每分钟」
func kpm() -> float:
	var now := _now()
	while _down_times.size() > 0 and now - float(_down_times[0]) > 30.0:
		_down_times.pop_front()
	return float(_down_times.size()) * 2.0

func _process(_delta: float) -> void:
	_frames += 1
	if hook != null:
		hook.poll()
	if get_window().has_focus():
		_focus_true_frames += 1

	var now := _now()
	# 启动后 2.5 秒内，只要发现自己握前台就把键盘还回去。
	# Godot 的激活可能晚于第一帧，所以不能只在 _ready 做一次。
	if now < 2.5 and win != null and win.get_foreground() == hwnd:
		if win.restore_prev_foreground():
			_logline("把焦点还给了 0x%X" % win.get_prev_foreground())
	var rate := kpm()
	var idle_for := now - _last_key_time
	if idle_for > SLEEPY_AFTER:
		state_name = "sleepy"
	elif rate >= EXCITED_KPM:
		state_name = "excited"
	elif rate > 0.0:
		state_name = "typing"
	else:
		state_name = "idle"

	if now - _log_t >= 1.0:
		_log_t = now
		_logline("ALIVE state=%s total=%d kpm=%.0f idle=%.0fs focused=%s focus_true_frames=%d input_keys=%d dropped=%d" % [
			state_name, total_today, rate, idle_for,
			str(get_window().has_focus()), _focus_true_frames, _input_key_count,
			hook.get_dropped_count() if hook != null else -1,
		])
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.position.distance_to(get_viewport_rect().size / 2.0) < 90.0:
				_dragging = true
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		DisplayServer.window_set_position(DisplayServer.window_get_position() + Vector2i(event.relative))

func _draw() -> void:
	var c := get_viewport_rect().size / 2.0
	var r := 74.0
	var col := Color(0.35, 0.75, 0.95, 0.85)
	match state_name:
		"typing":
			col = Color(0.30, 0.90, 0.70, 0.90)
			r = 80.0
		"excited":
			col = Color(1.00, 0.72, 0.20, 0.95)
			r = 88.0
		"sleepy":
			col = Color(0.50, 0.50, 0.65, 0.70)
			r = 66.0
	var speed := 1.2 if state_name == "typing" else 0.6
	var breath := 1.0 + 0.06 * sin(_now() * speed)
	draw_circle(c, r * breath, col)
	draw_arc(c, r * breath, 0.0, TAU, 64, Color(1, 1, 1, 0.85), 3.0)

	# 注意：Godot 默认字体不含中文字形，这里先用 ASCII，中文字体是待办
	var font := ThemeDB.fallback_font
	draw_string(font, c + Vector2(-90, 4), "today %d keys" % total_today,
			HORIZONTAL_ALIGNMENT_CENTER, 180, 20, Color(1, 1, 1, 0.95))
	draw_string(font, c + Vector2(-90, 26), "%.0f kpm  %s" % [kpm(), state_name],
			HORIZONTAL_ALIGNMENT_CENTER, 180, 14, Color(1, 1, 1, 0.75))
