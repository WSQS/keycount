// test_store.cpp —— 独立验证 kc_store（不需要 Godot，不需要宠物在跑）
//
//   test_store.exe
#include "kc_store.h"

#include "sqlite3.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

int g_failed = 0;

void check(bool ok, const char *what) {
	printf("%s %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok) {
		g_failed++;
	}
}

std::string temp_db_path() {
	return "test_store.db";
}

void remove_db_files(const std::string &base) {
	// WAL 模式会额外产生 -wal / -shm
	for (const char *suffix : { "", "-wal", "-shm", "-journal" }) {
		remove((base + suffix).c_str());
	}
}

// 用**独立**的 sqlite3 连接直接看表结构，确认没有混进「内容」类列。
// 这条不变量很重要：一旦表里出现字符/时序列，就等于存下了密码和聊天记录。
void check_schema_has_no_content_columns() {
	sqlite3 *raw = nullptr;
	if (sqlite3_open(temp_db_path().c_str(), &raw) != SQLITE_OK) {
		check(false, "用外部连接打开库（证明它是标准 SQLite 文件）");
		return;
	}
	check(true, "用外部连接打开库（证明它是标准 SQLite 文件）");

	sqlite3_stmt *stmt = nullptr;
	if (sqlite3_prepare_v2(raw, "PRAGMA table_info(key_hourly);", -1, &stmt, nullptr) != SQLITE_OK) {
		check(false, "读取 key_hourly 列信息");
		sqlite3_close(raw);
		return;
	}
	std::vector<std::string> cols;
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		const char *name = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 1));
		cols.push_back(name != nullptr ? name : "");
	}
	sqlite3_finalize(stmt);

	const std::vector<std::string> expected = { "day", "hour", "key", "count" };
	check(cols == expected, "key_hourly 的列正好是 day/hour/key/count（没有内容类列）");

	// 反向断言：任何列名里都不该出现这些词
	bool suspicious = false;
	for (const std::string &c : cols) {
		for (const char *bad : { "text", "char", "seq", "order", "title", "window", "clip" }) {
			if (c.find(bad) != std::string::npos) {
				suspicious = true;
			}
		}
	}
	check(!suspicious, "列名里没有任何可能承载输入内容的字段");

	sqlite3_close(raw);
}

void dump_day(const std::string &day) {
	kc::Store s;
	if (!s.open(temp_db_path())) {
		printf("   (打不开库: %s)\n", s.last_error().c_str());
		return;
	}
	int64_t total = 0;
	std::vector<std::pair<std::string, int64_t>> by_key;
	s.query_day(day, &total, &by_key);
	printf("   %s 总计 %lld：", day.c_str(), (long long)total);
	for (size_t i = 0; i < by_key.size() && i < 6; i++) {
		printf("%s×%lld ", by_key[i].first.c_str(), (long long)by_key[i].second);
	}
	printf("\n");
}

// ---- 存储结构版本与迁移 ----
// 这一组断言盯的是“升级不能弄丢用户的历史”：旧库（还没有 user_version）打开后
// 要自动升级、数据还在；而比程序新的库要**拒绝打开**，不能按旧结构往上写。

bool exec_raw(sqlite3 *raw, const char *sql) {
	char *err = nullptr;
	const int rc = sqlite3_exec(raw, sql, nullptr, nullptr, &err);
	if (err != nullptr) {
		sqlite3_free(err);
	}
	return rc == SQLITE_OK;
}

int raw_int(const std::string &path, const char *sql) {
	sqlite3 *raw = nullptr;
	if (sqlite3_open(path.c_str(), &raw) != SQLITE_OK) {
		return -1;
	}
	sqlite3_stmt *stmt = nullptr;
	int v = -1;
	if (sqlite3_prepare_v2(raw, sql, -1, &stmt, nullptr) == SQLITE_OK) {
		if (sqlite3_step(stmt) == SQLITE_ROW) {
			v = sqlite3_column_int(stmt, 0);
		}
		sqlite3_finalize(stmt);
	}
	sqlite3_close(raw);
	return v;
}

void check_schema_version_migration() {
	const std::string legacy = "test_store_legacy.db";
	remove_db_files(legacy);

	// 造一个“旧版”库：与引入 user_version 之前的实现完全一致（只建表、不写版本号）
	{
		sqlite3 *raw = nullptr;
		sqlite3_open_v2(legacy.c_str(), &raw,
				SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
		check(exec_raw(raw, "CREATE TABLE key_hourly (day TEXT NOT NULL, hour INTEGER NOT NULL, "
						      "key TEXT NOT NULL, count INTEGER NOT NULL, "
						      "PRIMARY KEY (day, hour, key)) WITHOUT ROWID;"),
				"造旧库：建 key_hourly");
		check(exec_raw(raw, "CREATE TABLE run_log (id INTEGER PRIMARY KEY AUTOINCREMENT, "
						      "started_at TEXT NOT NULL, ended_at TEXT, version TEXT NOT NULL, note TEXT);"),
				"造旧库：建 run_log");
		check(exec_raw(raw, "INSERT INTO key_hourly VALUES ('2026-01-02', 9, 'a', 4242);"),
				"造旧库：塞入历史计数");
		check(exec_raw(raw, "INSERT INTO run_log (started_at, version) "
						      "VALUES ('2026-01-02 09:00:00', 'v0.0.0');"),
				"造旧库：塞入一条运行记录");
		sqlite3_close(raw);
	}
	check(raw_int(legacy, "PRAGMA user_version;") == 0, "旧库的 user_version 确实是 0");

	{
		kc::Store s;
		check(s.open(legacy), "打开旧库（应当自动升级）");
		check(s.schema_version() == 1, "升级后 schema_version = 1");
		int64_t v = -1;
		check(s.query_bucket("2026-01-02", 9, "a", &v) && v == 4242,
				"升级没动数据：历史计数 4242 还在");
		std::vector<std::pair<std::string, std::string>> runs;
		check(s.recent_runs(5, &runs) && runs.size() == 1, "升级没动数据：运行记录还在");
		s.close();
	}
	check(raw_int(legacy, "PRAGMA user_version;") == 1, "库里真的写上了 user_version=1");

	// 反向：库比程序新 → 必须拒绝打开（宁可报错，不要假装）
	const std::string future = "test_store_future.db";
	remove_db_files(future);
	{
		sqlite3 *raw = nullptr;
		sqlite3_open_v2(future.c_str(), &raw,
				SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
		exec_raw(raw, "CREATE TABLE key_hourly (day TEXT NOT NULL, hour INTEGER NOT NULL, "
				      "key TEXT NOT NULL, count INTEGER NOT NULL, "
				      "PRIMARY KEY (day, hour, key)) WITHOUT ROWID;");
		exec_raw(raw, "PRAGMA user_version=999;");
		sqlite3_close(raw);
	}
	{
		kc::Store s;
		check(!s.open(future), "拒绝打开「结构版本更新」的库");
		check(s.last_error().find("999") != std::string::npos,
				"错误信息里带上实际版本号（便于排查）");
		check(!s.is_open(), "拒绝之后没留下半开状态");
	}

	remove_db_files(legacy);
	remove_db_files(future);
}

} // namespace

int main() {
	const std::string db = temp_db_path();
	remove_db_files(db);

	printf("===== kc_store 自检 =====\n\n");

	// ---------- 1) 建库与基本写入 ----------
	{
		kc::Store s;
		check(s.open(db), "建库/开库");
		check(s.is_open(), "is_open");

		std::vector<kc::Row> rows = {
			{ "2026-09-28", 14, "a", 3 },
			{ "2026-09-28", 14, "space", 2 },
			{ "2026-09-28", 15, "a", 1 },
			{ "2026-09-27", 23, "enter", 5 },
		};
		check(s.commit(rows), "写入一批增量");

		int64_t v = -1;
		s.query_bucket("2026-09-28", 14, "a", &v);
		check(v == 3, "分桶精确：2026-09-28 14 时 a = 3");
		s.query_bucket("2026-09-28", 99, "a", &v);
		check(v == 0, "不存在的桶返回 0");

		// 同桶再写一次必须累加（upsert），不能变成两行或覆盖
		std::vector<kc::Row> again = { { "2026-09-28", 14, "a", 4 } };
		check(s.commit(again), "再次写入同一个桶");
		s.query_bucket("2026-09-28", 14, "a", &v);
		check(v == 7, "同桶累加：3 + 4 = 7");

		int64_t total = 0;
		std::vector<std::pair<std::string, int64_t>> by_key;
		check(s.query_day("2026-09-28", &total, &by_key), "查某天");
		check(total == 10, "那天总计 = a@14 的 7 + space 的 2 + a@15 的 1 = 10");
		check(by_key.size() == 2, "那天有两个不同的键");
		check(!by_key.empty() && by_key[0].first == "a" && by_key[0].second == 8,
				"按次数降序：a=8 排第一");

		std::vector<int64_t> hours;
		check(s.query_hours("2026-09-28", &hours), "查小时分布");
		check(hours.size() == 24 && hours[14] == 9 && hours[15] == 1 && hours[0] == 0,
				"小时分布正确：14 时 9 下、15 时 1 下、0 时 0 下");

		std::vector<std::pair<std::string, int64_t>> days;
		check(s.query_days("2026-09-01", "2026-09-30", &days), "查区间");
		check(days.size() == 2, "区间内只有两天有数据");
		check(days[0].first == "2026-09-27" && days[1].first == "2026-09-28",
				"区间结果按日期升序");

		std::string first, last;
		check(s.day_range(&first, &last), "查数据覆盖范围");
		check(first == "2026-09-27" && last == "2026-09-28", "范围 = 2026-09-27 .. 2026-09-28");

		s.close();
		check(!s.is_open(), "close 之后 is_open=false");
	}

	// ---------- 2) 关掉再打开，数据必须还在（这就是「落盘」）----------
	{
		kc::Store s;
		check(s.open(db), "重新打开同一个库");
		int64_t v = -1;
		s.query_bucket("2026-09-28", 14, "a", &v);
		check(v == 7, "重开后数据还在：2026-09-28 14 时 a 仍然是 7");
		s.close();
	}

	// ---------- 3) 表结构不变量 ----------
	check_schema_has_no_content_columns();

	// ---------- 3.5) 存储结构版本与迁移 ----------
	check_schema_version_migration();

	// ---------- 4) run_log：能看出「昨天其实没在跑」----------
	{
		kc::Store s;
		check(s.open(db), "开库做 run_log 测试");

		check(s.begin_run("2026-09-27 09:00:00", "v0"), "记录一次运行开始");
		check(s.end_run("2026-09-27 18:30:00", ""), "记录这次运行正常结束");

		check(s.begin_run("2026-09-28 10:00:00", "v0"), "记录第二次运行开始");
		// 故意不调 end_run —— 模拟被强杀/断电

		check(s.begin_run("2026-09-28 11:00:00", "v0"), "记录第三次运行开始");
		check(s.end_run("2026-09-28 12:00:00", "手动退出"), "记录第三次结束");

		std::vector<std::pair<std::string, std::string>> runs;
		check(s.recent_runs(5, &runs), "读最近几次运行");
		check(runs.size() == 3, "有 3 条运行记录");
		// 最新的排在最前
		check(!runs.empty() && runs[0].first == "2026-09-28 11:00:00", "最新一条排在最前");
		bool found_unfinished = false;
		for (const auto &r : runs) {
			if (r.first == "2026-09-28 10:00:00" && r.second.empty()) {
				found_unfinished = true;
			}
		}
		check(found_unfinished, "没正常结束的那次 ended_at 为空（可据此发现异常退出）");

		check(!s.end_run("2026-09-28 13:00:00", ""), "没有进行中的 run 时 end_run 失败（不假装成功）");

		s.close();
	}

	// ---------- 5) 空值边界 ----------
	{
		kc::Store s;
		check(s.open(db), "开库做边界测试");
		int64_t total = 0;
		std::vector<std::pair<std::string, int64_t>> by_key;
		check(s.query_day("1999-01-01", &total, &by_key), "查一个没有任何数据的日子");
		check(total == 0 && by_key.empty(), "空日返回 0 与空列表，而不是报错");
		check(s.commit({}), "提交空批次是成功的空操作");
		s.close();
	}

	printf("\n===== 数据一览 =====\n");
	dump_day("2026-09-27");
	dump_day("2026-09-28");

	printf("\n%s（失败 %d 项）\n", g_failed == 0 ? "全部通过 ✅" : "有失败 ❌", g_failed);

	// 清掉测试库，别污染仓库
	remove_db_files(db);
	return g_failed == 0 ? 0 : 1;
}
