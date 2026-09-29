// kc_store_ext.cpp —— KeyCountStore 的实现（native SQLite 存储的薄接线）
#include "kc_store_ext.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

using namespace godot;

namespace {

std::string to_std(const String &s) {
	return std::string(s.utf8().get_data());
}

String to_gd(const std::string &s) {
	return String::utf8(s.c_str());
}

} // namespace

void KeyCountStore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "path"), &KeyCountStore::open);
	ClassDB::bind_method(D_METHOD("close"), &KeyCountStore::close);
	ClassDB::bind_method(D_METHOD("is_open"), &KeyCountStore::is_open);
	ClassDB::bind_method(D_METHOD("commit", "rows"), &KeyCountStore::commit);
	ClassDB::bind_method(D_METHOD("query_day", "day"), &KeyCountStore::query_day);
	ClassDB::bind_method(D_METHOD("query_hours", "day"), &KeyCountStore::query_hours);
	ClassDB::bind_method(D_METHOD("query_days", "from", "to"), &KeyCountStore::query_days);
	ClassDB::bind_method(D_METHOD("begin_run", "started_at", "version"), &KeyCountStore::begin_run);
	ClassDB::bind_method(D_METHOD("end_run", "ended_at", "note"), &KeyCountStore::end_run);
	ClassDB::bind_method(D_METHOD("recent_runs", "limit"), &KeyCountStore::recent_runs);
	ClassDB::bind_method(D_METHOD("get_last_error"), &KeyCountStore::get_last_error);
}

KeyCountStore::~KeyCountStore() {
	store_.close();
}

bool KeyCountStore::open(const String &path) {
	return store_.open(to_std(path));
}

void KeyCountStore::close() {
	store_.close();
}

bool KeyCountStore::is_open() const {
	return store_.is_open();
}

bool KeyCountStore::commit(const Array &rows) {
	std::vector<kc::Row> out;
	out.reserve(static_cast<size_t>(rows.size()));
	for (int i = 0; i < rows.size(); i++) {
		// 形状不对就明确失败，不静默跳行 —— 静默丢数据比报错严重得多
		if (rows[i].get_type() != Variant::DICTIONARY) {
			store_.note_error(to_std(String("commit 第 ") + String::num(i) + " 行不是 Dictionary"));
			return false;
		}
		Dictionary d = rows[i];
		if (!d.has("day") || !d.has("hour") || !d.has("key")) {
			store_.note_error(to_std(String("commit 第 ") + String::num(i) + " 行缺少 day/hour/key"));
			return false;
		}
		kc::Row r;
		r.day = to_std(String(d["day"]));
		r.hour = static_cast<int>(static_cast<int64_t>(d["hour"]));
		r.key = to_std(String(d["key"]));
		r.delta = d.has("delta") ? static_cast<int64_t>(d["delta"]) : 1;
		if (r.day.empty() || r.key.empty() || r.hour < 0 || r.hour > 23) {
			store_.note_error(to_std(String("commit 第 ") + String::num(i) +
						 " 行字段不合法（day/key 为空，或 hour 不在 0..23）"));
			return false;
		}
		out.push_back(std::move(r));
	}
	return store_.commit(out);
}

Dictionary KeyCountStore::query_day(const String &day) {
	Dictionary out;
	int64_t total = 0;
	std::vector<std::pair<std::string, int64_t>> by_key;
	const bool ok = store_.query_day(to_std(day), &total, &by_key);
	Array arr;
	if (ok) {
		for (const auto &kv : by_key) {
			Array pair;
			pair.append(to_gd(kv.first));
			pair.append(static_cast<int64_t>(kv.second));
			arr.append(pair);
		}
	}
	out["ok"] = ok;
	out["total"] = ok ? total : 0;
	out["by_key"] = arr;
	return out;
}

Dictionary KeyCountStore::query_hours(const String &day) {
	Dictionary out;
	std::vector<int64_t> hours;
	const bool ok = store_.query_hours(to_std(day), &hours);
	Array arr;
	if (ok) {
		for (size_t i = 0; i < hours.size(); i++) {
			arr.append(static_cast<int64_t>(hours[i]));
		}
	}
	out["ok"] = ok;
	out["hours"] = arr;
	return out;
}

Dictionary KeyCountStore::query_days(const String &from, const String &to) {
	Dictionary out;
	std::vector<std::pair<std::string, int64_t>> days;
	const bool ok = store_.query_days(to_std(from), to_std(to), &days);
	Array arr;
	if (ok) {
		for (const auto &kv : days) {
			Array pair;
			pair.append(to_gd(kv.first));
			pair.append(static_cast<int64_t>(kv.second));
			arr.append(pair);
		}
	}
	out["ok"] = ok;
	out["days"] = arr;
	return out;
}

bool KeyCountStore::begin_run(const String &started_at, const String &version) {
	return store_.begin_run(to_std(started_at), to_std(version));
}

bool KeyCountStore::end_run(const String &ended_at, const String &note) {
	return store_.end_run(to_std(ended_at), to_std(note));
}

Dictionary KeyCountStore::recent_runs(int limit) {
	Dictionary out;
	std::vector<std::pair<std::string, std::string>> runs;
	const bool ok = store_.recent_runs(limit, &runs);
	Array arr;
	if (ok) {
		for (const auto &kv : runs) {
			Array pair;
			pair.append(to_gd(kv.first));
			pair.append(to_gd(kv.second));
			arr.append(pair);
		}
	}
	out["ok"] = ok;
	out["runs"] = arr;
	return out;
}

String KeyCountStore::get_last_error() const {
	return to_gd(store_.last_error());
}
