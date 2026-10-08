extends Node2D

const LOG_PATH := "user://spike-godot-run.log"

var _log: FileAccess
var _t := 0.0
var _keys := 0
var _focus_true := 0

func _logline(s: String) -> void:
	if _log:
		_log.store_line("%.2f %s" % [Time.get_ticks_msec() / 1000.0, s])
		_log.flush()

func _ready() -> void:
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	var w := get_window()
	# 关键使能条件 1：GDExtension 能不能拿到 Win32 HWND
	var hwnd: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, 0)
	_logline("HWND=0x%X  (int=%d)" % [hwnd, hwnd])
	# 关键使能条件 2：Godot 有没有内置「不抢焦点」
	_logline("FLAG_NO_FOCUS 存在? %s" % (Window.FLAG_NO_FOCUS != null))
	w.set_flag(Window.FLAG_NO_FOCUS, true)
	_logline("设了 FLAG_NO_FOCUS 之后 flags=%d  has_focus=%s" % [w.get_flag(Window.FLAG_NO_FOCUS), w.has_focus()])
	_logline("DisplayServer mouse_get_position=%s (跨窗口全局鼠标位置可用?)" % DisplayServer.mouse_get_position())
	_logline("screen_count=%d  window.size=%s pos=%s" % [DisplayServer.get_screen_count(), w.size, w.position])

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_keys += 1
		_logline("KEY_RECEIVED %s (total=%d) focused=%s" % [event.as_text(), _keys, get_window().has_focus()])

func _process(delta: float) -> void:
	_t += delta
	if get_window().has_focus():
		_focus_true += 1
	if _t >= 1.0:
		_t = 0.0
		_logline("ALIVE fps=%d keys=%d focused=%s focus_true_frames=%d" % [Engine.get_frames_per_second(), _keys, get_window().has_focus(), _focus_true])
	queue_redraw()

func _draw() -> void:
	var r := 90.0 + 18.0 * sin(Time.get_ticks_msec() / 700.0)
	draw_circle(Vector2(210, 210), r, Color(0.15, 0.85, 0.95, 0.92))
	draw_arc(Vector2(210, 210), r, 0.0, TAU, 64, Color(1, 1, 1, 0.9), 4.0)
