// kc_window.cpp —— KeyCountWindow 与「记录/归还前置窗口」的实现
#include "kc_window.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/string.hpp>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <cstdio>
#include <cstdlib>

using namespace godot;

namespace {

#ifdef _WIN32
// >>> zone:human
HWND g_prev_foreground = nullptr;
// <<<
HWND to_hwnd(int64_t p) {
	return reinterpret_cast<HWND>(static_cast<intptr_t>(p));
}

// 改扩展样式必须跟一次 SWP_FRAMECHANGED 才会真正生效
void refresh_frame(HWND h) {
	SetWindowPos(h, nullptr, 0, 0, 0, 0,
			SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

bool no_activate_impl(int64_t hwnd, bool on) {
	HWND h = to_hwnd(hwnd);
	if (h == nullptr || !IsWindow(h)) {
		return false;
	}
	LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
	if (on) {
		ex |= (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
	} else {
		ex &= ~static_cast<LONG_PTR>(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
	}
	SetWindowLongPtrW(h, GWL_EXSTYLE, ex);
	refresh_frame(h);
	const LONG_PTR now = GetWindowLongPtrW(h, GWL_EXSTYLE);
	return on ? ((now & WS_EX_NOACTIVATE) != 0) : ((now & WS_EX_NOACTIVATE) == 0);
}

bool click_through_impl(int64_t hwnd, bool on) {
	HWND h = to_hwnd(hwnd);
	if (h == nullptr || !IsWindow(h)) {
		return false;
	}
	LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
	if (on) {
		ex |= (WS_EX_LAYERED | WS_EX_TRANSPARENT);
	} else {
		ex &= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
	}
	SetWindowLongPtrW(h, GWL_EXSTYLE, ex);
	refresh_frame(h);
	const LONG_PTR now = GetWindowLongPtrW(h, GWL_EXSTYLE);
	return on ? ((now & WS_EX_TRANSPARENT) != 0) : ((now & WS_EX_TRANSPARENT) == 0);
}

int64_t ex_style_impl(int64_t hwnd) {
	HWND h = to_hwnd(hwnd);
	if (h == nullptr || !IsWindow(h)) {
		return -1;
	}
	return static_cast<int64_t>(GetWindowLongPtrW(h, GWL_EXSTYLE));
}

#else

bool no_activate_impl(int64_t, bool) { return false; }
bool click_through_impl(int64_t, bool) { return false; }
int64_t ex_style_impl(int64_t) { return -1; }

#endif // _WIN32

} // namespace
// >>> zone:human
namespace kc_ext {
// 启动时把「宠物出现之前谁持有键盘」记下来。
//
// 为什么需要它：实测发现光给窗口打 WS_EX_NOACTIVATE 不够 —— Godot 自己在启动时
// 会把窗口激活，而 NOACTIVATE 只挡住「用户点击激活」，挡不住程序主动激活。
// 结果就是宠物攥着 hwndFocus（用 GetGUIThreadInfo 验过），你随手打的字会落进宠物里。
// 所以要把焦点还回原来那个窗口。
//
// 另一个实测教训：这个函数在 MODULE_INITIALIZATION_LEVEL_SCENE 阶段
// **拿不到 HWND**（Godot 还没建窗口，window_get_native_handle 返回 0），
// 所以在这里只能记录前置窗口，样式得等窗口建好后再打。
void remember_prev_foreground() {
#ifdef _WIN32
	// 优先用启动器传来的值。
	//
	// 为什么不能直接 GetForegroundWindow()：实测发现 Godot 在**扩展初始化之前**
	// 就已经创建并激活了窗口，所以在扩展里看到的「前台」永远是宠物自己
	// （日志里 prev_foreground == hwnd 就是这个原因）。
	// 只有启动器在拉起宠物之前那一刻才能看到真实的「原来谁持有键盘」。
	const char *env = std::getenv("KC_PREV_FOREGROUND");
	if (env != nullptr && *env != '\0') {
		const unsigned long long parsed = std::strtoull(env, nullptr, 0);
		if (parsed != 0) {
			HWND h = reinterpret_cast<HWND>(static_cast<intptr_t>(parsed));
			if (IsWindow(h)) {
				g_prev_foreground = h;
				return;
			}
		}
	}
	g_prev_foreground = GetForegroundWindow();
#endif
}

} // namespace kc_ext
// <<<
void KeyCountWindow::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_no_activate", "hwnd", "on"), &KeyCountWindow::set_no_activate);
	ClassDB::bind_method(D_METHOD("set_click_through", "hwnd", "on"), &KeyCountWindow::set_click_through);
	ClassDB::bind_method(D_METHOD("get_ex_style", "hwnd"), &KeyCountWindow::get_ex_style);
	ClassDB::bind_method(D_METHOD("describe_ex_style", "hwnd"), &KeyCountWindow::describe_ex_style);
	ClassDB::bind_method(D_METHOD("restore_prev_foreground"), &KeyCountWindow::restore_prev_foreground);
	ClassDB::bind_method(D_METHOD("get_prev_foreground"), &KeyCountWindow::get_prev_foreground);
	ClassDB::bind_method(D_METHOD("get_foreground"), &KeyCountWindow::get_foreground);
}

int64_t KeyCountWindow::get_prev_foreground() const {
#ifdef _WIN32
	return static_cast<int64_t>(reinterpret_cast<intptr_t>(g_prev_foreground));
#else
	return 0;
#endif
}

int64_t KeyCountWindow::get_foreground() const {
#ifdef _WIN32
	return static_cast<int64_t>(reinterpret_cast<intptr_t>(GetForegroundWindow()));
#else
	return 0;
#endif
}
// >>> zone:human
bool KeyCountWindow::restore_prev_foreground() {
#ifdef _WIN32
	if (g_prev_foreground == nullptr || !IsWindow(g_prev_foreground)) {
		return false;
	}
	if (GetForegroundWindow() == g_prev_foreground) {
		return true; // 已经还回去了
	}
	return SetForegroundWindow(g_prev_foreground) != 0;
#else
	return false;
#endif
}
// <<<

bool KeyCountWindow::set_no_activate(int64_t hwnd, bool on) {
	return no_activate_impl(hwnd, on);
}

bool KeyCountWindow::set_click_through(int64_t hwnd, bool on) {
	return click_through_impl(hwnd, on);
}

int64_t KeyCountWindow::get_ex_style(int64_t hwnd) const {
	return ex_style_impl(hwnd);
}

String KeyCountWindow::describe_ex_style(int64_t hwnd) const {
#ifdef _WIN32
	const int64_t ex = ex_style_impl(hwnd);
	if (ex < 0) {
		return "hwnd 无效";
	}
	String s;
	auto add = [&](const char *name, bool present) {
		if (!s.is_empty()) {
			s += " ";
		}
		s += name;
		s += present ? "=1" : "=0";
	};
	add("noactivate", (ex & WS_EX_NOACTIVATE) != 0);
	add("toolwindow", (ex & WS_EX_TOOLWINDOW) != 0);
	add("layered", (ex & WS_EX_LAYERED) != 0);
	add("transparent", (ex & WS_EX_TRANSPARENT) != 0);
	return s;
#else
	(void)hwnd;
	return "非 Windows";
#endif
}
