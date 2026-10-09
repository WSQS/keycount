// kc_store.h —— 按 (day, hour, key) 分桶的计数存储
//
// 跟 kc_hook 一样，这一份刻意不依赖 Godot：只用 C++ + SQLite，
// 这样独立 exe、GDExtension、以后的引擎模块能共用同一份实现。
//
// 只存计数，不存按键顺序、不存字符、不存窗口标题。
// 一旦存了有序按键流，就等于把你的密码和聊天记录存下来了。
#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

struct sqlite3;
struct sqlite3_stmt;

namespace kc {

// 一次要写入的增量。day 形如 "2026-09-28"，hour 是本地时的 0..23。
struct Row {
	std::string day;
	int hour = 0;
	std::string key;
	int64_t delta = 1;
};

class Store {
public:
	Store() = default;
	~Store();

	Store(const Store &) = delete;
	Store &operator=(const Store &) = delete;

	// 打开（不存在则建表）。开 WAL 以便崩溃后能恢复、
	// 也允许外部工具在宠物运行时并发读。
	bool open(const std::string &path);
	void close();
	bool is_open() const;

	// 把一批增量在**一个事务**里写进去。同一天的同一个键会累加。
	// 返回是否成功；失败原因见 last_error()。
	bool commit(const std::vector<Row> &rows);

	// 某天的总次数 + 各键次数（按次数降序）
	bool query_day(const std::string &day, int64_t *total_out,
			std::vector<std::pair<std::string, int64_t>> *by_key_out);

	// 某天 24 小时分布（数组长度固定 24）
	bool query_hours(const std::string &day, std::vector<int64_t> *hours_out);

	// [from, to] 闭区间内每天的总数，按日期升序。
	// 没有数据的那天**不会**出现在结果里（调用方自己补 0，这样才能看出「那天没跑」）。
	bool query_days(const std::string &from, const std::string &to,
			std::vector<std::pair<std::string, int64_t>> *out);

	// 某个键在某天某个小时里的次数（做调试/核对用）
	bool query_bucket(const std::string &day, int hour, const std::string &key, int64_t *out);

	// ---- run_log：用来发现「昨天其实没在跑」----
	bool begin_run(const std::string &started_at, const std::string &version);
	// 结束最近一次运行。时间字符串由调用方给（本地时区格式化），
	// 存储层不负责时区/格式化。note 可为空。
	bool end_run(const std::string &ended_at, const std::string &note);
	// 最近 n 次运行：started_at → ended_at（空字符串表示那次没正常结束，比如被强杀或断电）
	bool recent_runs(int limit, std::vector<std::pair<std::string, std::string>> *out);

	// 给上层包装器用的：报告它自己发现的参数错误，
	// 让 last_error() 仍是唯一的错误出口（错误不许静默消失）
	void note_error(const std::string &msg) { last_error_ = msg; }

	// 所有数据里最早/最晚的一天，用来判断库是不是空的
	bool day_range(std::string *first_out, std::string *last_out);

	const std::string &last_error() const { return last_error_; }

	// 存储结构的版本（SQLite 内建的 PRAGMA user_version）。它和**发布版本号是两件事**：
	// 发布号天天变，结构几个月才动一次；合成一个号的后果，要么每次发版都像"要迁移"，
	// 要么结构真变了而发布号没动 ⇒ 静默写坏用户的计数历史。
	// 库比本程序新时 open() 会失败（拒绝按旧结构往上写）。
	int schema_version() const { return schema_version_; }

private:
	bool exec(const char *sql);
	bool prepare(const char *sql, sqlite3_stmt **stmt_out);
	// 读一个整数（PRAGMA、COUNT 这类）
	bool scalar_int(const char *sql, int *out);
	// 失败时的统一收尾：把连接关掉，保证 is_open() 和 open() 的返回值一致
	// （不给调用方留下“打开失败但还是 is_open()==true”的半开状态）
	bool abort_open() {
		close();
		return false;
	}

	sqlite3 *db_ = nullptr;
	int64_t current_run_id_ = 0;
	int schema_version_ = 0;
	std::string last_error_;
};

} // namespace kc
