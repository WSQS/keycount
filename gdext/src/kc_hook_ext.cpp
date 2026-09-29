// kc_hook_ext.cpp —— KeyCountHook 的实现（native 钩子的薄接线）
#include "kc_hook_ext.h"

#include "kc_hook.h" // native/kc_hook.h —— 引号 include 找不到同名文件时会落到 CPPPATH 的 ../native/

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

void KeyCountHook::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start"), &KeyCountHook::start);
	ClassDB::bind_method(D_METHOD("stop"), &KeyCountHook::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &KeyCountHook::is_running);
	ClassDB::bind_method(D_METHOD("poll"), &KeyCountHook::poll);
	ClassDB::bind_method(D_METHOD("get_dropped_count"), &KeyCountHook::get_dropped_count);
	ClassDB::bind_static_method("KeyCountHook", D_METHOD("key_name_of", "vk", "scancode", "extended"), &KeyCountHook::key_name_of);

	ADD_SIGNAL(MethodInfo("key_event",
			PropertyInfo(Variant::STRING, "key_name"),
			PropertyInfo(Variant::INT, "vk"),
			PropertyInfo(Variant::INT, "scancode"),
			PropertyInfo(Variant::BOOL, "extended"),
			PropertyInfo(Variant::BOOL, "is_down"),
			PropertyInfo(Variant::BOOL, "repeated")));
}

KeyCountHook::~KeyCountHook() {
	// 对象被释放时必须把钩子收掉，否则钩子线程会留着
	kc::hook_stop();
}

bool KeyCountHook::start() {
	return kc::hook_start();
}

void KeyCountHook::stop() {
	kc::hook_stop();
}

bool KeyCountHook::is_running() const {
	return kc::hook_running();
}

int KeyCountHook::poll() {
	// 钩子线程只入队；这里在主线程把事件搬出来并触发信号。
	// 绝不能在钩子回调里 emit_signal —— Godot 对象不是线程安全的。
	kc::KeyEvent ev[256];
	const size_t n = kc::hook_poll(ev, 256);
	for (size_t i = 0; i < n; ++i) {
		emit_signal("key_event",
				String(kc::key_name(ev[i]).c_str()),
				static_cast<int>(ev[i].vk),
				static_cast<int>(ev[i].scancode),
				ev[i].extended,
				ev[i].is_down,
				ev[i].repeated);
	}
	return static_cast<int>(n);
}

int64_t KeyCountHook::get_dropped_count() const {
	return static_cast<int64_t>(kc::hook_dropped());
}

String KeyCountHook::key_name_of(int64_t vk, int64_t scancode, bool extended) {
	kc::KeyEvent e;
	e.vk = static_cast<uint32_t>(vk);
	e.scancode = static_cast<uint32_t>(scancode);
	e.extended = extended;
	return String(kc::key_name(e).c_str());
}
