// kc_hook.cpp —— 全局键盘钩子的实现
#include "kc_hook.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <deque>
#include <mutex>
#include <thread>

namespace kc {
namespace {

constexpr size_t kQueueCap = 8192;

HHOOK g_hook = nullptr;
std::thread g_thread;
std::atomic<int> g_state{0}; // 0=启动中 1=已装 2=失败
std::atomic<bool> g_stop_requested{false};
std::atomic<uint64_t> g_dropped{0};

std::mutex g_mutex;
std::deque<KeyEvent> g_queue;
bool g_held[256] = {}; // vk < 256 的按住状态，用来识别长按自动重复

// 低层钩子回调：必须短。超 LowLevelHooksTimeout（默认 300ms）会被 Windows 静默摘钩，
// 所以这里只入队，绝不做日志/磁盘/回调用户代码。
LRESULT CALLBACK hook_proc(int code, WPARAM wparam, LPARAM lparam) {
	if (code == HC_ACTION) {
		const auto *kb = reinterpret_cast<const KBDLLHOOKSTRUCT *>(lparam);
		const bool is_down = (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN);
		const bool is_up = (wparam == WM_KEYUP || wparam == WM_SYSKEYUP);
		if (is_down || is_up) {
			KeyEvent e;
			e.vk = kb->vkCode;
			e.scancode = static_cast<uint32_t>(kb->scanCode) & 0xFFu; // 去掉 E0/E1 前缀
			e.extended = (kb->flags & LLKHF_EXTENDED) != 0;
			e.is_down = is_down;

			std::lock_guard<std::mutex> lk(g_mutex);
			if (e.vk < 256) {
				e.repeated = is_down && g_held[e.vk];
				g_held[e.vk] = is_down;
			}
			if (g_queue.size() < kQueueCap) {
				g_queue.push_back(e);
			} else {
				g_dropped.fetch_add(1, std::memory_order_relaxed);
			}
		}
	}
	return CallNextHookEx(g_hook, code, wparam, lparam);
}

void thread_main() {
	// 低层钩子由「安装它的线程」派发，所以这个线程必须自己跑消息循环，
	// 不能借 Godot 的主循环 —— 否则 Godot 卡帧时就会漏键。
	g_hook = SetWindowsHookExW(WH_KEYBOARD_LL, hook_proc, GetModuleHandleW(nullptr), 0);
	if (g_hook == nullptr) {
		g_state.store(2);
		return;
	}
	g_state.store(1);

	MSG msg;
	while (!g_stop_requested.load(std::memory_order_relaxed)) {
		while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
		}
		// 带超时地等消息，这样 stop 请求能被及时看到
		MsgWaitForMultipleObjectsEx(0, nullptr, 20, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
	}

	UnhookWindowsHookEx(g_hook);
	g_hook = nullptr;
}

// ---------- 键名归一化 ----------
//
// 以 **vkCode 为主**，扫描码只在 vk 认不出来时兜底。原因是实测出来的：
// SendKeys/SendInput 造出来的合成事件 scancode 是 0x00，
// 而只按扫描码查表就会退化成一堆 "sc00"（真实硬件按键不受影响）。
// 远控、KVM、键位重映射工具同样可能不发扫描码 —— 只有 vk 是可靠的。
//
// vk 唯一不能区分的两处，用 extended 标志补：
//   VK_RETURN：主回车 vs 小键盘回车
//   VK_ADD/VK_SUBTRACT/VK_DIVIDE/VK_MULTIPLY/VK_DECIMAL/VK_NUMPAD*：vk 本身就够

std::string vk_name(uint32_t vk, bool extended) {
	switch (vk) {
		case VK_BACK: return "backspace";
		case VK_TAB: return "tab";
		case VK_RETURN: return extended ? "kp_enter" : "enter";
		case VK_SHIFT: return "shift";
		case VK_CONTROL: return "ctrl";
		case VK_MENU: return "alt";
		case VK_PAUSE: return "pause";
		case VK_CAPITAL: return "capslock";
		case VK_ESCAPE: return "esc";
		case VK_SPACE: return "space";
		case VK_PRIOR: return "pageup";
		case VK_NEXT: return "pagedown";
		case VK_END: return "end";
		case VK_HOME: return "home";
		case VK_LEFT: return "left";
		case VK_UP: return "up";
		case VK_RIGHT: return "right";
		case VK_DOWN: return "down";
		case VK_SNAPSHOT: return "printscreen";
		case VK_INSERT: return "insert";
		case VK_DELETE: return "delete";
		case VK_LWIN:
		case VK_RWIN: return "win";
		case VK_APPS: return "apps";
		case VK_NUMLOCK: return "numlock";
		case VK_SCROLL: return "scrolllock";
		case VK_LSHIFT:
		case VK_RSHIFT: return "shift";
		case VK_LCONTROL:
		case VK_RCONTROL: return "ctrl";
		case VK_LMENU:
		case VK_RMENU: return "alt";
		// OEM 键（美式布局命名；其他布局靠扫描码兜底）
		case VK_OEM_1: return "semicolon";
		case VK_OEM_PLUS: return "equal";
		case VK_OEM_COMMA: return "comma";
		case VK_OEM_MINUS: return "minus";
		case VK_OEM_PERIOD: return "dot";
		case VK_OEM_2: return "slash";
		case VK_OEM_3: return "backquote";
		case VK_OEM_4: return "leftbracket";
		case VK_OEM_5: return "backslash";
		case VK_OEM_6: return "rightbracket";
		case VK_OEM_7: return "quote";
		default: break;
	}

	// 数字行 '0'-'9'
	if (vk >= '0' && vk <= '9') {
		return std::string(1, static_cast<char>(vk));
	}
	// 字母一律记小写 —— 按基准键位记，Shift+A 和 A 不分裂成两行
	if (vk >= 'A' && vk <= 'Z') {
		return std::string(1, static_cast<char>(vk - 'A' + 'a'));
	}
	// 小键盘 0-9
	if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) {
		char buf[10];
		snprintf(buf, sizeof(buf), "kp_%d", int(vk - VK_NUMPAD0));
		return buf;
	}
	switch (vk) {
		case VK_MULTIPLY: return "kp_multiply";
		case VK_ADD: return "kp_plus";
		case VK_SEPARATOR: return "kp_separator";
		case VK_SUBTRACT: return "kp_minus";
		case VK_DECIMAL: return "kp_dot";
		case VK_DIVIDE: return "kp_slash";
		default: break;
	}
	// 功能键 F1..F24 = 0x70..0x87
	if (vk >= VK_F1 && vk <= VK_F24) {
		char buf[8];
		snprintf(buf, sizeof(buf), "f%d", int(vk - VK_F1) + 1);
		return buf;
	}
	return std::string();
}

// 扫描码兜底：只在 vk 认不出来时用
std::string scancode_name(uint32_t sc, bool extended) {
	if (extended) {
		switch (sc) {
			case 0x1C: return "kp_enter";
			case 0x1D: return "ctrl";
			case 0x35: return "kp_slash";
			case 0x37: return "printscreen";
			case 0x38: return "alt";
			case 0x47: return "home";
			case 0x48: return "up";
			case 0x49: return "pageup";
			case 0x4B: return "left";
			case 0x4D: return "right";
			case 0x4F: return "end";
			case 0x50: return "down";
			case 0x51: return "pagedown";
			case 0x52: return "insert";
			case 0x53: return "delete";
			case 0x5B:
			case 0x5C: return "win";
			case 0x5D: return "apps";
			default: break;
		}
	}
	switch (sc) {
		case 0x01: return "esc";
		case 0x02: return "1";
		case 0x03: return "2";
		case 0x04: return "3";
		case 0x05: return "4";
		case 0x06: return "5";
		case 0x07: return "6";
		case 0x08: return "7";
		case 0x09: return "8";
		case 0x0A: return "9";
		case 0x0B: return "0";
		case 0x0C: return "minus";
		case 0x0D: return "equal";
		case 0x0E: return "backspace";
		case 0x0F: return "tab";
		case 0x1A: return "leftbracket";
		case 0x1B: return "rightbracket";
		case 0x1C: return "enter";
		case 0x1D: return "ctrl";
		case 0x27: return "semicolon";
		case 0x28: return "quote";
		case 0x29: return "backquote";
		case 0x2A: return "shift";
		case 0x2B: return "backslash";
		case 0x33: return "comma";
		case 0x34: return "dot";
		case 0x35: return "slash";
		case 0x36: return "shift";
		case 0x37: return "kp_multiply";
		case 0x38: return "alt";
		case 0x39: return "space";
		case 0x3A: return "capslock";
		case 0x45: return "numlock";
		case 0x46: return "scrolllock";
		case 0x57: return "f11";
		case 0x58: return "f12";
		default: break;
	}
	// 字母行
	static const char *row_q = "qwertyuiop";
	static const char *row_a = "asdfghjkl";
	static const char *row_z = "zxcvbnm";
	if (sc >= 0x10 && sc <= 0x19) return std::string(1, row_q[sc - 0x10]);
	if (sc >= 0x1E && sc <= 0x26) return std::string(1, row_a[sc - 0x1E]);
	if (sc >= 0x2C && sc <= 0x32) return std::string(1, row_z[sc - 0x2C]);
	if (sc >= 0x3B && sc <= 0x44) {
		char buf[8];
		snprintf(buf, sizeof(buf), "f%d", int(sc - 0x3B) + 1);
		return buf;
	}
	if (sc >= 0x47 && sc <= 0x53) {
		switch (sc) {
			case 0x47: return "kp_7";
			case 0x48: return "kp_8";
			case 0x49: return "kp_9";
			case 0x4A: return "kp_minus";
			case 0x4B: return "kp_4";
			case 0x4C: return "kp_5";
			case 0x4D: return "kp_6";
			case 0x4E: return "kp_plus";
			case 0x4F: return "kp_1";
			case 0x50: return "kp_2";
			case 0x51: return "kp_3";
			case 0x52: return "kp_0";
			case 0x53: return "kp_dot";
			default: break;
		}
	}
	return std::string();
}

} // namespace

std::string key_name(const KeyEvent &e) {
	{
		const std::string s = vk_name(e.vk, e.extended);
		if (!s.empty()) {
			return s;
		}
	}
	{
		const std::string s = scancode_name(e.scancode, e.extended);
		if (!s.empty()) {
			return s;
		}
	}
	// 两个都认不出来 —— 明确记成未知，不要假装成某个键
	char buf[24];
	snprintf(buf, sizeof(buf), "vk%02x_sc%02x", unsigned(e.vk), unsigned(e.scancode));
	return buf;
}

bool hook_start() {
	if (g_thread.joinable()) {
		return g_state.load() == 1;
	}
	g_stop_requested.store(false);
	g_state.store(0);
	g_thread = std::thread(thread_main);
	// 等安装结果，最多约 2 秒
	for (int i = 0; i < 2000; ++i) {
		const int s = g_state.load();
		if (s == 1) {
			return true;
		}
		if (s == 2) {
			g_thread.join();
			return false;
		}
		Sleep(1);
	}
	return false;
}

void hook_stop() {
	if (!g_thread.joinable()) {
		return;
	}
	g_stop_requested.store(true);
	g_thread.join();
	g_state.store(0);
	std::lock_guard<std::mutex> lk(g_mutex);
	g_queue.clear();
	std::fill(std::begin(g_held), std::end(g_held), false);
}

bool hook_running() {
	return g_state.load() == 1;
}

size_t hook_poll(KeyEvent *out, size_t max) {
	if (out == nullptr || max == 0) {
		return 0;
	}
	std::lock_guard<std::mutex> lk(g_mutex);
	const size_t n = std::min(max, g_queue.size());
	for (size_t i = 0; i < n; ++i) {
		out[i] = g_queue.front();
		g_queue.pop_front();
	}
	return n;
}

uint64_t hook_dropped() {
	return g_dropped.load(std::memory_order_relaxed);
}

} // namespace kc
