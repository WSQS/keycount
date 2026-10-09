extends Node2D
# v0 宠物：透明置顶、不抢焦点、全局抓键，并把计数落盘。
# 美术后补 —— 这里仍是一个会呼吸的圆。
#
# 职责划分：什么算一天、哪个小时、多久 flush 一次，都在这里决定（业务口径）；
# 扩展只负责「可靠写进去 / 查得回来」。改口径不用重编扩展。

const LOG_PATH := "user://run.log"           # 日志放 user://：导出版不会在 exe 旁边留文件，装进 Program Files 也能写
const LOG_MAX_BYTES := 1_000_000             # 超过就轮转，只留 1 份旧日志（不轮转时实测长到过 80MB）
const DB_PATH := "user://keycount.db"       # 存 %APPDATA%\Godot\app_userdata\<项目名>\
const VERSION := "v1"

const FLUSH_INTERVAL := 10.0                 # 最长 10 秒落一次盘
const FLUSH_EVENTS := 200                    # 或攒够 200 下就落
const SLEEPY_AFTER := 180.0                  # 静默多久打瞌睡
const EXCITED_KPM := 400.0                   # 多快算兴奋

var hook: KeyCountHook
var win: KeyCountWindow
var store: KeyCountStore
var hwnd: int = 0

# 展示用计数（启动时从库里读回今日已有数字，所以重启不会归零）
var today_total: int = 0
var by_key: Dictionary = {}
var _display_day: String = ""
var _down_times: Array = []
var _last_key_time: float = 0.0
var state_name: String = "idle"

# 待落盘的增量：bucket 键 -> {"day","hour","key","delta"}
var _pending: Dictionary = {}
var _pending_events: int = 0
var _last_flush: float = 0.0
var _flush_fail_count: int = 0

var _log: FileAccess = null
# 必须存成成员：RefCounted 引用计数归零会立刻析构，那样锁就释放了
var _guard: KeyCountGuard = null
var _log_t: float = 0.0
var _focus_true_frames: int = 0
var _input_key_count: int = 0
var _dragging: bool = false
var _drag_offset: Vector2i = Vector2i.ZERO   # 抓取点相对窗口左上角的偏移（绝对坐标法用）
var _db_ok: bool = false

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# 简单轮转：当前日志超过上限就改名为 run.log.1（只留一份）。
# 日志是**诊断**用的，不是数据 —— 计数在 SQLite 库里，轮转永远不碰它。
func _rotate_log() -> void:
	var cur := ProjectSettings.globalize_path(LOG_PATH)
	var f := FileAccess.open(cur, FileAccess.READ)
	if f == null:
		return
	var size := f.get_length()
	f = null
	if size < LOG_MAX_BYTES:
		return
	var old := cur + ".1"
	DirAccess.remove_absolute(old)
	DirAccess.rename_absolute(cur, old)

func _logline(s: String) -> void:
	if _log != null:
		_log.store_line("%7.2f %s" % [_now(), s])
		_log.flush()

func _today_string() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]

func _stamp() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d:%02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]

func _ready() -> void:
	# ---- 单实例：两个宠物会把每一下按键记两次（实测过，9 下变 18）----
	# 启动器里那层查进程只能拦住正常路径，而且刚启动的进程有时读不到 CommandLine，
	# 所以真正牢的保证在这里。
	#
	# 顺序很重要：**先抢锁、再开日志**。
	# 否则第二个实例会在抢锁之前就把第一个实例的 run.log 截掉（本文件用 WRITE 模式打开），
	# 两个进程同时写同一个日志文件，读出来直接是乱码。
	_guard = KeyCountGuard.new()
	if not _guard.try_acquire("keycount_pet_single_instance"):
		# 不能写日志（那是共享文件），打到 stdout 去 —— 用 -RedirectStandardOutput 能收到
		print("keycount: 已经有一个宠物在跑，本进程退出（两个一起跑会让计数翻倍）")
		get_window().hide()   # 别在屏幕上一闪
		get_tree().quit()
		return

	_rotate_log()
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)

	var wall := _stamp()
	_logline("启动 %s  版本 %s" % [wall, VERSION])

	hwnd = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, 0)
	win = KeyCountWindow.new()
	_logline("hwnd=0x%X  prev_foreground=0x%X  foreground=0x%X" % [hwnd, win.get_prev_foreground(), win.get_foreground()])
	_logline("set_no_activate -> %s" % str(win.set_no_activate(hwnd, true)))
	_logline("ex_style : %s" % win.describe_ex_style(hwnd))
	get_window().set_flag(Window.FLAG_NO_FOCUS, true)
	_logline("第一帧 restore_prev_foreground -> %s" % str(win.restore_prev_foreground()))

	# ---- 落盘 ----
	store = KeyCountStore.new()
	_db_ok = store.open(ProjectSettings.globalize_path(DB_PATH))
	if _db_ok:
		_logline("库已打开: %s" % ProjectSettings.globalize_path(DB_PATH))
		if not store.begin_run(wall, VERSION):
			_logline("!! begin_run 失败: %s" % store.get_last_error())
		# 上次是不是没正常结束？（被强杀/断电 → ended_at 为空）
		var runs: Dictionary = store.recent_runs(2)
		if runs.get("ok", false):
			var list: Array = runs["runs"]
			if list.size() >= 1:
				var last: Array = list[0]
				if String(last[1]) == "":
					_logline("注意：上一次运行没有正常结束（%s），可能是被强杀或断电" % String(last[0]))
				else:
					_logline("上一次运行 %s → %s" % [String(last[0]), String(last[1])])
		_load_day(_today_string())
	else:
		_logline("!! 库打开失败: %s" % store.get_last_error())

	hook = KeyCountHook.new()
	hook.key_event.connect(_on_key_event)
	_logline("hook.start() -> %s" % str(hook.start()))

# 把某天已有的数据读回内存，用于展示（重启后不归零）
func _load_day(day: String) -> void:
	_display_day = day
	today_total = 0
	by_key = {}
	if not _db_ok:
		return
	var res: Dictionary = store.query_day(day)
	if not res.get("ok", false):
		_logline("!! 读 %s 的数据失败: %s" % [day, store.get_last_error()])
		return
	today_total = int(res["total"])
	for pair in res["by_key"]:
		by_key[String(pair[0])] = int(pair[1])
	_logline("%s 库里已有 %d 下（%d 种键）" % [day, today_total, by_key.size()])

func _on_key_event(key_name: String, vk: int, scancode: int, extended: bool, is_down: bool, repeated: bool) -> void:
	if not is_down or repeated:
		return

	var dt := Time.get_datetime_dict_from_system()
	var day := "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	# 跨零点：先把昨天的尾巴落到盘上，再切天重新载入
	if day != _display_day:
		_logline("跨天了：%s → %s" % [_display_day, day])
		_flush(true)
		_load_day(day)

	today_total += 1
	by_key[key_name] = int(by_key.get(key_name, 0)) + 1

	var bk := "%s|%d|%s" % [day, dt.hour, key_name]
	if not _pending.has(bk):
		_pending[bk] = { "day": day, "hour": dt.hour, "key": key_name, "delta": 0 }
	_pending[bk]["delta"] = int(_pending[bk]["delta"]) + 1
	_pending_events += 1

	_down_times.append(_now())
	_last_key_time = _now()
	# 逐键行只在 debug 构建里写：发布版不留「带时间序的按键流水」，日志只记状态。
	# 开发期（编辑器 / debug 模板）照旧写，判据依赖它。
	if OS.is_debug_build():
		_logline("KEY %-12s vk=0x%02X sc=0x%02X ext=%d" % [key_name, vk, scancode, 1 if extended else 0])

# 把待落盘的增量写进库。失败时**不清空** —— 数据留在内存里下次再试，不丢。
func _flush(verbose: bool) -> bool:
	if _pending.is_empty():
		return true
	if not _db_ok:
		if verbose:
			_logline("库不可用，%d 个桶留在内存里" % _pending.size())
		return false
	var rows: Array = []
	for bk in _pending:
		var r: Dictionary = _pending[bk]
		if int(r["delta"]) > 0:
			rows.append(r)
	if rows.is_empty():
		_pending.clear()
		_pending_events = 0
		return true
	if not store.commit(rows):
		_flush_fail_count += 1
		_logline("!! 落盘失败（第 %d 次）: %s —— %d 个桶留在内存里，下次重试"
			% [_flush_fail_count, store.get_last_error(), rows.size()])
		return false
	_pending.clear()
	_pending_events = 0
	_last_flush = _now()
	if verbose:
		_logline("已落盘 %d 个桶" % rows.size())
	return true

func kpm() -> float:
	var now := _now()
	while _down_times.size() > 0 and now - float(_down_times[0]) > 30.0:
		_down_times.pop_front()
	return float(_down_times.size()) * 2.0

func _process(_delta: float) -> void:
	if hook != null:
		hook.poll()
	if get_window().has_focus():
		_focus_true_frames += 1

	var now := _now()
	if now < 2.5 and win != null and win.get_foreground() == hwnd:
		if win.restore_prev_foreground():
			_logline("把焦点还给了 0x%X" % win.get_prev_foreground())

	# 定期落盘
	if _pending_events >= FLUSH_EVENTS or (not _pending.is_empty() and now - _last_flush >= FLUSH_INTERVAL):
		_flush(false)

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
		_logline("ALIVE state=%s total=%d kpm=%.0f idle=%.0fs pending=%d/%d focused=%s input_keys=%d db=%s" % [
			state_name, today_total, rate, idle_for,
			_pending.size(), _pending_events,
			str(get_window().has_focus()), _input_key_count,
			"ok" if _db_ok else "FAIL",
		])
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_shutdown()

func _exit_tree() -> void:
	_shutdown()

func _shutdown() -> void:
	if _guard != null:
		_guard.release()
	if store == null or not _db_ok:
		return
	_flush(true)
	if store.end_run(_stamp(), ""):
		_logline("已记录本次运行结束")
	else:
		_logline("!! end_run 失败: %s" % store.get_last_error())
	store.close()
	_db_ok = false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.position.distance_to(get_viewport_rect().size / 2.0) < 90.0:
				_dragging = true
				# 绝对坐标：记下抓取点相对窗口左上角的偏移，之后每次直接把窗口摆到
				# “光标 - 偏移”。不能累加 event.relative —— 我们在移动自己所在的窗口，
				# WM_MOUSEMOVE 的客户区坐标基准随之变化（Godot 的补正
				# _update_real_mouse_position 与队列里旧基准的消息有竞争），
				# 实测每帧只跟 30%、约 45% 的帧反向跳（抖动/闪烁）。
				_drag_offset = DisplayServer.mouse_get_position() - DisplayServer.window_get_position()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		DisplayServer.window_set_position(DisplayServer.mouse_get_position() - _drag_offset)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_input_key_count += 1

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
	if not _db_ok:
		col = Color(0.85, 0.25, 0.25, 0.85)   # 存不下去就变红，不许假装正常
	var speed := 1.2 if state_name == "typing" else 0.6
	var breath := 1.0 + 0.06 * sin(_now() * speed)
	draw_circle(c, r * breath, col)
	draw_arc(c, r * breath, 0.0, TAU, 64, Color(1, 1, 1, 0.85), 3.0)

	# 注意：Godot 默认字体不含中文字形，这里先用 ASCII，中文字体是待办
	var font := ThemeDB.fallback_font
	draw_string(font, c + Vector2(-90, 0), "today %d keys" % today_total,
			HORIZONTAL_ALIGNMENT_CENTER, 180, 20, Color(1, 1, 1, 0.95))
	draw_string(font, c + Vector2(-90, 22), "%.0f kpm  %s" % [kpm(), state_name],
			HORIZONTAL_ALIGNMENT_CENTER, 180, 14, Color(1, 1, 1, 0.75))
	if not _db_ok:
		draw_string(font, c + Vector2(-90, 40), "DB UNAVAILABLE",
				HORIZONTAL_ALIGNMENT_CENTER, 180, 12, Color(1, 0.8, 0.8, 0.95))
