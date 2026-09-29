// kc_window.h —— GDExtension 接线层：Win32 窗口样式
//
// 这两件事 GDScript 做不到（要 SetWindowLongPtr），但**不需要改引擎**。
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// 窗口样式。HWND 从 DisplayServer.window_get_native_handle(WINDOW_HANDLE, 0) 拿。
class KeyCountWindow : public RefCounted {
	GDCLASS(KeyCountWindow, RefCounted)

protected:
	static void _bind_methods();

public:
	KeyCountWindow() = default;
	~KeyCountWindow() override = default;

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
// >>> zone:human
namespace kc_ext {

// 启动时记录「宠物出现之前谁持有键盘」。由模块初始化（kc_module.cpp）在
// MODULE_INITIALIZATION_LEVEL_SCENE 阶段调用；**必须早于**任何 restore_prev_foreground。
// 见 kc_window.cpp 里的长注释（为什么不能直接 GetForegroundWindow）。
void remember_prev_foreground();
// <<<
} // namespace kc_ext
