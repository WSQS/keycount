// kc_gdext.h —— GDExtension 接线层
//
// 这一层刻意很薄：只把 native/kc_hook.cpp 的能力和几个 Win32 窗口样式
// 暴露给 GDScript。统计、聚合、宠物状态机都在 GDScript 里，不进引擎。
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include "kc_store.h"

namespace godot {

// 全局键盘钩子。
//
// 用法（GDScript）：
//     var hook := KeyCountHook.new()
//     hook.key_event.connect(_on_key)
//     hook.start()
//     # 每帧调用，把钩子线程队列里的事件搬到主线程并触发信号
//     func _process(_d): hook.poll()
//
// 为什么必须 poll 而不是让钩子直接发信号：钩子回调跑在**它自己的线程**上，
// 而 Godot 的对象不是线程安全的；从钩子线程 emit_signal 会随机崩。
class KeyCountHook : public RefCounted {
	GDCLASS(KeyCountHook, RefCounted)

protected:
	static void _bind_methods();

public:
	KeyCountHook() = default;
	~KeyCountHook() override;

	// 安装/卸载全局钩子。钩子跑在自己的线程 + 自己的消息循环上，
	// 所以 Godot 卡帧不会漏键。start() 返回是否装上了。
	bool start();
	void stop();
	bool is_running() const;

	// 把队列里的事件搬到主线程并触发 key_event 信号，返回搬了几条。
	int poll();

	// 自启动以来因为队列满而丢弃的事件数（不静默丢）
	int64_t get_dropped_count() const;

	// 键名归一化：字母数字按基准键位记小写，命名键如 "enter"/"space"，
	// 认不出来记 "vkXX_scYY"。给自检用，不参与运行时路径。
	static String key_name_of(int64_t vk, int64_t scancode, bool extended);
};

// 窗口样式。HWND 从 DisplayServer.window_get_native_handle(WINDOW_HANDLE, 0) 拿。
//
// 这两件事 GDScript 做不到（要 SetWindowLongPtr），但**不需要改引擎**。
class KeyCountWindow : public RefCounted {
	GDCLASS(KeyCountWindow, RefCounted)

protected:
	static void _bind_methods();

public:
	KeyCountWindow() = default;
	~KeyCountWindow() override;

	// WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
	// —— 不抢焦点、不进 Alt-Tab。桌宠必须开这个，否则它会吞掉你正在编辑器里打的字。
	bool set_no_activate(int64_t hwnd, bool on);

	// WS_EX_LAYERED | WS_EX_TRANSPARENT
	// —— 鼠标事件穿透到下面的窗口。要配合「光标在透明像素上时才开」使用。
	bool set_click_through(int64_t hwnd, bool on);

	// 读当前扩展样式，用来验证上面两个到底生效没有
	int64_t get_ex_style(int64_t hwnd) const;

	// 把扩展样式翻成人话，方便打日志/断言
	String describe_ex_style(int64_t hwnd) const;

	// 把键盘焦点还给「宠物出现之前那个窗口」。
	//
	// 实测：只打 WS_EX_NOACTIVATE 是不够的 —— Godot 启动时会自己激活窗口，
	// 而 NOACTIVATE 只挡「用户点击激活」。结果宠物撑着 hwndFocus，
	// 你随手打的字会落进宠物里。所以启动后要主动把焦点还回去。
	// 返回是否已回到目标窗口。
	bool restore_prev_foreground();

	// 启动时记录的前置窗口 HWND（0 表示没记到）
	int64_t get_prev_foreground() const;

	// 当前前台窗口 HWND
	int64_t get_foreground() const;
};

// 计数存储，底层是 SQLite（见 thirdparty/sqlite/PIN.txt）。
//
// 这一层只负责「可靠地写进去 / 查得回来」。
// 什么算一天、哪个小时、批量多久 flush 一次 —— 全在 GDScript 那边决定，
// 因为那些是业务口径，不是存储职责（以后改口径不用重编扩展）。
class KeyCountStore : public RefCounted {
	GDCLASS(KeyCountStore, RefCounted)

protected:
	static void _bind_methods();

public:
	KeyCountStore() = default;
	~KeyCountStore() override;

	// 打开（不存在则建表）。建议用 user://keycount.db
	bool open(const String &path);
	void close();
	bool is_open() const;

	// 把一个批次写进**一个事务**。每行是一个 Dictionary：
	//   {"day": "2026-09-28", "hour": 14, "key": "a", "delta": 3}
	// 同一天的同一个键会累加。要么全成，要么全不成。
	bool commit(const Array &rows);

	// 某天：{ "ok": bool, "total": int, "by_key": [[key, count], ...] }（按次数降序）。
	// 带 ok 是为了让调用方能区分「真的是 0」与「查询失败」—— 不允许假装数据还在。
	Dictionary query_day(const String &day);

	// { "ok": bool, "hours": [24 个整数] }（找自己的活跃时段用）
	Dictionary query_hours(const String &day);

	// { "ok": bool, "days": [[day, total], ...] }，闭区间，只含有数据的日子
	Dictionary query_days(const String &from, const String &to);

	// ---- run_log：用来发现「昨天其实没在跑」----
	bool begin_run(const String &started_at, const String &version);
	bool end_run(const String &ended_at, const String &note);
	// { "ok": bool, "runs": [[started_at, ended_at], ...] }，ended_at 为空表示那次没正常结束
	Dictionary recent_runs(int limit);

	String get_last_error() const;

private:
	kc::Store store_;
};

// 单实例锁。
//
// 为什么需要它：每个宠物进程都会装自己的全局键盘钩子，两个一起跑会把同一下按键**记两次**
// （实测过：9 下变成 18）。启动器里那层「查进程」只能拦住正常路径，而且刚启动的进程
// 有时读不到 CommandLine（实测遇到的竞态），所以真正牢的保证必须由宠物自己给。
//
// 用命名内核对象而不是锁文件：进程一死，Windows 自动释放，不会留下「崩了之后就再也起不来」的死锁文件。
class KeyCountGuard : public RefCounted {
	GDCLASS(KeyCountGuard, RefCounted)

protected:
	static void _bind_methods();

public:
	KeyCountGuard() = default;
	~KeyCountGuard() override;

	// 返回 false 表示已经有另一个实例拿着这个锁。
	// 注意：调用方必须持有本对象（存成成员变量），否则引用计数归零会立刻释放锁。
	bool try_acquire(const String &name);
	void release();
	bool is_held() const;

private:
	void *handle_ = nullptr;
};

} // namespace godot
