// kc_hook.h —— 全局键盘钩子 + 键名归一化
//
// 刻意不依赖 Godot：这一份代码要能同时用于
//   1) 独立小 exe（验证抓键准不准）
//   2) GDExtension
//   3) 引擎内原生模块
// 所以这里只用 Win32 + 标准库，不许出现任何 godot/ 头文件。
#pragma once

#include <cstdint>
#include <string>

namespace kc {

// 一次物理按键。注意：IME 无关 —— 用拼音打「你好」记到的是 n i h a o 五下。
struct KeyEvent {
	uint32_t vk = 0;       // Win32 虚拟键码
	uint32_t scancode = 0; // 硬件扫描码（make code，已去掉 E0/E1 前缀）
	bool extended = false; // 是否 E0/E1 前缀
	bool is_down = true;   // 按下还是抬起
	bool repeated = false; // 长按自动重复（Windows 会持续发 down）
};

// 扫描码 → 归一化键名。规则见 SPEC.md：
//   字母数字按基准键位记小写（Shift+A 记 "a"，不分裂成两行）
//   命名键 "enter" "space" "tab" "backspace" "esc" "delete" "up"...
//   修饰键 "shift" "ctrl" "alt" "win"（左右不区分）
//   无法识别 → "sc<hex>"
std::string key_name(const KeyEvent &e);

// 启动全局键盘钩子。
// 内部起一个**专用线程跑自己的消息循环** —— 低层钩子由安装它的线程派发，
// 所以不能借用 Godot 的主循环；专用线程让钩子在 Godot 卡帧/未响应时也照样收键。
// 返回 false 表示安装失败（GetLastError 里是原因）。
bool hook_start();

// 停止钩子并回收线程。可重复调用。
void hook_stop();

bool hook_running();

// 从队列里取事件。返回取到的条数（最多 max 条）。
// 游戏循环里每帧调一次即可 —— 钩子线程只入队，绝不在钩子回调里做重活。
// 低层钩子回调超过 LowLevelHooksTimeout（默认 300ms）会被 Windows 静默摘掉，
// 所以入队路径必须短。
size_t hook_poll(KeyEvent *out, size_t max);

// 因为钩子队列会满，这里报告自启动以来被丢弃的事件数（0 表示没丢过）。
uint64_t hook_dropped();

} // namespace kc
