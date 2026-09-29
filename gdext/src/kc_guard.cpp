// kc_guard.cpp —— KeyCountGuard 的实现（命名内核互斥体）
#include "kc_guard.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/string.hpp>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

using namespace godot;

void KeyCountGuard::_bind_methods() {
	ClassDB::bind_method(D_METHOD("try_acquire", "name"), &KeyCountGuard::try_acquire);
	ClassDB::bind_method(D_METHOD("release"), &KeyCountGuard::release);
	ClassDB::bind_method(D_METHOD("is_held"), &KeyCountGuard::is_held);
}

KeyCountGuard::~KeyCountGuard() {
	release();
}

bool KeyCountGuard::try_acquire(const String &name) {
#ifdef _WIN32
	release();
	Char16String wname = name.utf16();
	HANDLE h = CreateMutexW(nullptr, TRUE, reinterpret_cast<LPCWSTR>(wname.get_data()));
	if (h == nullptr) {
		return false;
	}
	if (GetLastError() == ERROR_ALREADY_EXISTS) {
		// 别人拿着：把自己这个句柄关掉，不要假装拿到
		CloseHandle(h);
		return false;
	}
	handle_ = h;
	return true;
#else
	(void)name;
	return true;
#endif
}

void KeyCountGuard::release() {
#ifdef _WIN32
	if (handle_ != nullptr) {
		CloseHandle(reinterpret_cast<HANDLE>(handle_));
		handle_ = nullptr;
	}
#endif
}

bool KeyCountGuard::is_held() const {
	return handle_ != nullptr;
}
