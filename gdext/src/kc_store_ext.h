// kc_store_ext.h —— GDExtension 接线层：计数存储
//
// 为什么叫 `kc_store_ext` 而不是 `kc_store`：`native/kc_store.h` 已经叫那个名字，同名会被
// 引号 include 的"自己所在目录优先"遮住（见 kc_hook_ext.h 里的说明）。
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include "kc_store.h" // native/kc_store.h

namespace godot {

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

} // namespace godot
