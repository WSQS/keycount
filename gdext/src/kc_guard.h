// kc_guard.h —— GDExtension 接线层：单实例锁
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

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
