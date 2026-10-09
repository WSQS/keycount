// kc_store.cpp —— 基于 SQLite 的计数存储实现
#include "kc_store.h"

#include "sqlite3.h"

namespace {
// 当前存储结构版本（写在 SQLite 内建的 PRAGMA user_version 里，跟事务一起提交）。
// 0 = 本字段引入之前建的库（旧版用户手里的库）。
constexpr int kSchemaVersion = 1;

const char *kCreateKeyHourly =
		"CREATE TABLE IF NOT EXISTS key_hourly ("
		"  day   TEXT    NOT NULL," // 'YYYY-MM-DD' 本地时区
		"  hour  INTEGER NOT NULL," // 0..23 本地时区
		"  key   TEXT    NOT NULL," // 归一化键名，见 kc_hook.cpp
		"  count INTEGER NOT NULL,"
		"  PRIMARY KEY (day, hour, key)"
		") WITHOUT ROWID;";

const char *kCreateRunLog =
		"CREATE TABLE IF NOT EXISTS run_log ("
		"  id         INTEGER PRIMARY KEY AUTOINCREMENT,"
		"  started_at TEXT NOT NULL,"
		"  ended_at   TEXT," // NULL = 那次没正常结束（被强杀/断电）
		"  version    TEXT NOT NULL,"
		"  note       TEXT"
		");";
} // namespace

namespace kc {

Store::~Store() {
	close();
}

bool Store::exec(const char *sql) {
	char *errmsg = nullptr;
	if (sqlite3_exec(db_, sql, nullptr, nullptr, &errmsg) != SQLITE_OK) {
		last_error_ = (errmsg != nullptr) ? errmsg : "sqlite3_exec 失败";
		if (errmsg != nullptr) {
			sqlite3_free(errmsg);
		}
		return false;
	}
	if (errmsg != nullptr) {
		sqlite3_free(errmsg);
	}
	return true;
}

bool Store::prepare(const char *sql, sqlite3_stmt **stmt_out) {
	if (sqlite3_prepare_v2(db_, sql, -1, stmt_out, nullptr) != SQLITE_OK) {
		last_error_ = sqlite3_errmsg(db_);
		return false;
	}
	return true;
}

bool Store::scalar_int(const char *sql, int *out) {
	sqlite3_stmt *stmt = nullptr;
	if (!prepare(sql, &stmt)) {
		return false;
	}
	bool ok = false;
	if (sqlite3_step(stmt) == SQLITE_ROW) {
		*out = sqlite3_column_int(stmt, 0);
		ok = true;
	} else {
		last_error_ = sqlite3_errmsg(db_);
	}
	sqlite3_finalize(stmt);
	return ok;
}

bool Store::open(const std::string &path) {
	close();
	if (sqlite3_open_v2(path.c_str(), &db_,
			    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
			    nullptr) != SQLITE_OK) {
		last_error_ = (db_ != nullptr) ? sqlite3_errmsg(db_) : "sqlite3_open_v2 失败";
		if (db_ != nullptr) {
			sqlite3_close(db_);
			db_ = nullptr;
		}
		return false;
	}

	// WAL：崩溃/断电后能恢复到最后一个已提交事务；同时允许外部工具并发读
	if (!exec("PRAGMA journal_mode=WAL;")) {
		return abort_open();
	}
	// NORMAL 在 WAL 下仍然保证事务原子性，只在极端断电时可能丢最后若干事务
	if (!exec("PRAGMA synchronous=NORMAL;")) {
		return abort_open();
	}
	// 宠物在写、命令行在读的时候不要立刻报 SQLITE_BUSY
	if (!exec("PRAGMA busy_timeout=3000;")) {
		return abort_open();
	}
	// ---- 存储结构版本 ----
	// 先读：库比程序新时必须**拒绝**，绝不能按旧结构往上写。
	int found = 0;
	if (!scalar_int("PRAGMA user_version;", &found)) {
		return abort_open();
	}
	if (found > kSchemaVersion) {
		last_error_ = "库的存储结构版本是 " + std::to_string(found) + "，比本程序认识的 " +
				std::to_string(kSchemaVersion) + " 新；请升级程序（拒绝按旧结构写这个库）";
		return abort_open();
	}

	// 建表 + 记版本号放**同一个事务**：要么都成、要么都不成（不留半套结构）。
	// 以后改结构就在这里加 `if (found < 2) { ...迁移... }`，并补一条 test_store 断言。
	const std::string set_version = "PRAGMA user_version=" + std::to_string(kSchemaVersion) + ";";
	if (!exec("BEGIN IMMEDIATE;")) {
		return abort_open();
	}
	if (!exec(kCreateKeyHourly) || !exec(kCreateRunLog) || !exec(set_version.c_str())) {
		const std::string why = last_error_; // 先记下真正的失败原因，别被回滚覆盖
		exec("ROLLBACK;");
		last_error_ = why;
		return abort_open();
	}
	if (!exec("COMMIT;")) {
		return abort_open();
	}
	schema_version_ = kSchemaVersion;
	return true;
}

void Store::close() {
	if (db_ != nullptr) {
		sqlite3_close(db_);
		db_ = nullptr;
	}
	current_run_id_ = 0;
	schema_version_ = 0;
}

bool Store::is_open() const {
	return db_ != nullptr;
}

bool Store::commit(const std::vector<Row> &rows) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	if (rows.empty()) {
		return true;
	}
	if (!exec("BEGIN IMMEDIATE;")) {
		return false;
	}

	sqlite3_stmt *stmt = nullptr;
	if (!prepare(
			    "INSERT INTO key_hourly(day,hour,key,count) VALUES(?1,?2,?3,?4) "
			    "ON CONFLICT(day,hour,key) DO UPDATE SET count = count + excluded.count;",
			    &stmt)) {
		exec("ROLLBACK;");
		return false;
	}

	bool ok = true;
	for (const Row &r : rows) {
		sqlite3_bind_text(stmt, 1, r.day.c_str(), -1, SQLITE_STATIC);
		sqlite3_bind_int(stmt, 2, r.hour);
		sqlite3_bind_text(stmt, 3, r.key.c_str(), -1, SQLITE_STATIC);
		sqlite3_bind_int64(stmt, 4, r.delta);
		if (sqlite3_step(stmt) != SQLITE_DONE) {
			last_error_ = sqlite3_errmsg(db_);
			ok = false;
			break;
		}
		sqlite3_reset(stmt);
		sqlite3_clear_bindings(stmt);
	}
	sqlite3_finalize(stmt);

	if (!ok) {
		exec("ROLLBACK;");
		return false;
	}
	if (!exec("COMMIT;")) {
		exec("ROLLBACK;");
		return false;
	}
	return true;
}

bool Store::query_day(const std::string &day, int64_t *total_out,
		std::vector<std::pair<std::string, int64_t>> *by_key_out) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("SELECT key, SUM(count) FROM key_hourly WHERE day=?1 "
		     "GROUP BY key ORDER BY SUM(count) DESC, key ASC;",
			    &stmt)) {
		return false;
	}
	sqlite3_bind_text(stmt, 1, day.c_str(), -1, SQLITE_STATIC);
	int64_t total = 0;
	if (by_key_out != nullptr) {
		by_key_out->clear();
	}
	int rc = SQLITE_ROW;
	while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
		const char *k = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 0));
		const int64_t c = sqlite3_column_int64(stmt, 1);
		total += c;
		if (by_key_out != nullptr) {
			by_key_out->push_back({k != nullptr ? k : "", c});
		}
	}
	sqlite3_finalize(stmt);
	if (rc != SQLITE_DONE) {
		last_error_ = sqlite3_errmsg(db_);
		return false;
	}
	if (total_out != nullptr) {
		*total_out = total;
	}
	return true;
}

bool Store::query_hours(const std::string &day, std::vector<int64_t> *hours_out) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	if (hours_out != nullptr) {
		hours_out->assign(24, 0);
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("SELECT hour, SUM(count) FROM key_hourly WHERE day=?1 GROUP BY hour;", &stmt)) {
		return false;
	}
	sqlite3_bind_text(stmt, 1, day.c_str(), -1, SQLITE_STATIC);
	int rc = SQLITE_ROW;
	while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
		const int h = sqlite3_column_int(stmt, 0);
		const int64_t c = sqlite3_column_int64(stmt, 1);
		if (hours_out != nullptr && h >= 0 && h < 24) {
			(*hours_out)[h] = c;
		}
	}
	sqlite3_finalize(stmt);
	if (rc != SQLITE_DONE) {
		last_error_ = sqlite3_errmsg(db_);
		return false;
	}
	return true;
}

bool Store::query_days(const std::string &from, const std::string &to,
		std::vector<std::pair<std::string, int64_t>> *out) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("SELECT day, SUM(count) FROM key_hourly WHERE day>=?1 AND day<=?2 "
		     "GROUP BY day ORDER BY day ASC;",
			    &stmt)) {
		return false;
	}
	sqlite3_bind_text(stmt, 1, from.c_str(), -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, to.c_str(), -1, SQLITE_STATIC);
	if (out != nullptr) {
		out->clear();
	}
	int rc = SQLITE_ROW;
	while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
		const char *d = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 0));
		const int64_t c = sqlite3_column_int64(stmt, 1);
		if (out != nullptr) {
			out->push_back({d != nullptr ? d : "", c});
		}
	}
	sqlite3_finalize(stmt);
	if (rc != SQLITE_DONE) {
		last_error_ = sqlite3_errmsg(db_);
		return false;
	}
	return true;
}

bool Store::query_bucket(const std::string &day, int hour, const std::string &key, int64_t *out) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("SELECT count FROM key_hourly WHERE day=?1 AND hour=?2 AND key=?3;", &stmt)) {
		return false;
	}
	sqlite3_bind_text(stmt, 1, day.c_str(), -1, SQLITE_STATIC);
	sqlite3_bind_int(stmt, 2, hour);
	sqlite3_bind_text(stmt, 3, key.c_str(), -1, SQLITE_STATIC);
	int64_t v = 0;
	const int rc = sqlite3_step(stmt);
	if (rc == SQLITE_ROW) {
		v = sqlite3_column_int64(stmt, 0);
	} else if (rc != SQLITE_DONE) {
		last_error_ = sqlite3_errmsg(db_);
		sqlite3_finalize(stmt);
		return false;
	}
	sqlite3_finalize(stmt);
	if (out != nullptr) {
		*out = v;
	}
	return true;
}

bool Store::begin_run(const std::string &started_at, const std::string &version) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("INSERT INTO run_log(started_at, version) VALUES(?1, ?2);", &stmt)) {
		return false;
	}
	sqlite3_bind_text(stmt, 1, started_at.c_str(), -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, version.c_str(), -1, SQLITE_STATIC);
	const bool ok = (sqlite3_step(stmt) == SQLITE_DONE);
	if (!ok) {
		last_error_ = sqlite3_errmsg(db_);
	}
	sqlite3_finalize(stmt);
	if (ok) {
		current_run_id_ = sqlite3_last_insert_rowid(db_);
	}
	return ok;
}

bool Store::end_run(const std::string &ended_at, const std::string &note) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	if (current_run_id_ == 0) {
		last_error_ = "没有进行中的 run";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("UPDATE run_log SET ended_at=?1, note=?2 WHERE id=?3;", &stmt)) {
		return false;
	}
	sqlite3_bind_text(stmt, 1, ended_at.c_str(), -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, note.c_str(), -1, SQLITE_STATIC);
	sqlite3_bind_int64(stmt, 3, current_run_id_);
	const bool ok = (sqlite3_step(stmt) == SQLITE_DONE);
	if (!ok) {
		last_error_ = sqlite3_errmsg(db_);
	}
	sqlite3_finalize(stmt);
	if (ok) {
		current_run_id_ = 0;
	}
	return ok;
}

bool Store::recent_runs(int limit, std::vector<std::pair<std::string, std::string>> *out) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("SELECT started_at, COALESCE(ended_at,'') FROM run_log ORDER BY id DESC LIMIT ?1;", &stmt)) {
		return false;
	}
	sqlite3_bind_int(stmt, 1, limit);
	if (out != nullptr) {
		out->clear();
	}
	int rc = SQLITE_ROW;
	while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
		const char *s = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 0));
		const char *e = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 1));
		if (out != nullptr) {
			out->push_back({s != nullptr ? s : "", e != nullptr ? e : ""});
		}
	}
	sqlite3_finalize(stmt);
	if (rc != SQLITE_DONE) {
		last_error_ = sqlite3_errmsg(db_);
		return false;
	}
	return true;
}

bool Store::day_range(std::string *first_out, std::string *last_out) {
	if (db_ == nullptr) {
		last_error_ = "库没打开";
		return false;
	}
	sqlite3_stmt *stmt = nullptr;
	if (!prepare("SELECT MIN(day), MAX(day) FROM key_hourly;", &stmt)) {
		return false;
	}
	const int rc = sqlite3_step(stmt);
	if (rc == SQLITE_ROW) {
		const char *a = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 0));
		const char *b = reinterpret_cast<const char *>(sqlite3_column_text(stmt, 1));
		if (first_out != nullptr) {
			*first_out = (a != nullptr) ? a : "";
		}
		if (last_out != nullptr) {
			*last_out = (b != nullptr) ? b : "";
		}
	} else if (rc != SQLITE_DONE) {
		last_error_ = sqlite3_errmsg(db_);
		sqlite3_finalize(stmt);
		return false;
	}
	sqlite3_finalize(stmt);
	return true;
}

} // namespace kc
