// kc_hook_ext.h —— GDExtension 接线层：全局键盘钩子
//
// 这一层刻意很薄：只把 native/kc_hook.cpp 的能力暴露给 GDScript。
// 统计、聚合、宠物状态机都在 GDScript 里，不进引擎。
//
// 为什么叫 `kc_hook_ext` 而不是 `kc_hook`：`native/kc_hook.h` 已经叫那个名字，而 CPPPATH 里
// `src/` 排在 `../native/` 前面、引号 include 又先查"自己所在目录" —— 同名会把 native 的
// 那份**遮住**，`kc::hook_start` 那套符号就再也拿不到。
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

} // namespace godot
