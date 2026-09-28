// kc_gdext.h —— GDExtension 接线层
//
// 这一层刻意很薄：只把 native/kc_hook.cpp 的能力和几个 Win32 窗口样式
// 暴露给 GDScript。统计、聚合、宠物状态机都在 GDScript 里，不进引擎。
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

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

} // namespace godot
