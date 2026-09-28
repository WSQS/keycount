#!/usr/bin/env python3
"""keycount 命令行报表 —— 直接读宠物写的那个 SQLite 库。

宠物没在跑也能用（WAL 模式允许并发读）。

    uv run --no-project python tools/keycount.py today
    uv run --no-project python tools/keycount.py report 2026-09-28
    uv run --no-project python tools/keycount.py week
    uv run --no-project python tools/keycount.py runs

库路径默认是 Godot 的 user:// 目录，可用 --db 或环境变量 KC_DB 覆盖。
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = (
    Path(os.environ.get("APPDATA", Path.home()))
    / "Godot"
    / "app_userdata"
    / "keycount pet"
    / "keycount.db"
)

BAR_WIDTH = 34


def resolve_db(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    if os.environ.get("KC_DB"):
        return Path(os.environ["KC_DB"])
    return DEFAULT_DB


def connect(path: Path) -> sqlite3.Connection:
    if not path.exists():
        sys.exit(
            f"找不到库：{path}\n"
            "宠物至少成功运行过一次才会建库。可以用 --db 指定别的路径。"
        )
    # 只读 + 让 SQLite 自己等写锁，避免「宠物正在落盘」时读到一半报错
    uri = f"file:{path.as_posix()}?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=5.0)
    con.row_factory = sqlite3.Row
    return con


def day_total(con: sqlite3.Connection, day: str) -> int:
    row = con.execute(
        "SELECT COALESCE(SUM(count), 0) AS t FROM key_hourly WHERE day = ?", (day,)
    ).fetchone()
    return int(row["t"])


def top_keys(con: sqlite3.Connection, day: str, limit: int = 10):
    return con.execute(
        "SELECT key, SUM(count) AS c FROM key_hourly WHERE day = ? "
        "GROUP BY key ORDER BY c DESC, key ASC LIMIT ?",
        (day, limit),
    ).fetchall()


def hours(con: sqlite3.Connection, day: str) -> list[int]:
    out = [0] * 24
    for row in con.execute(
        "SELECT hour, SUM(count) AS c FROM key_hourly WHERE day = ? GROUP BY hour", (day,)
    ):
        out[int(row["hour"])] = int(row["c"])
    return out


def bar(value: int, peak: int, width: int = BAR_WIDTH) -> str:
    if peak <= 0:
        return ""
    n = max(1, round(value / peak * width)) if value > 0 else 0
    return "█" * n


def spark(values: list[int]) -> str:
    blocks = " ▁▂▃▄▅▆▇█"
    peak = max(values) if values else 0
    if peak <= 0:
        return ""
    return "".join(blocks[min(8, round(v / peak * 8))] if v > 0 else " " for v in values)


def hhmm(seconds_from_midnight: int) -> str:
    return f"{seconds_from_midnight // 3600:02d}:00"


def print_day(con: sqlite3.Connection, day: str, weekday_ok: bool = True) -> None:
    total = day_total(con, day)
    hs = hours(con, day)
    keys = top_keys(con, day)

    stamp = day
    try:
        d = dt.date.fromisoformat(day)
        stamp += "  " + "一二三四五六日"[d.weekday()]
    except ValueError:
        pass

    if total == 0 and not keys:
        print(f"{stamp}   没有数据（宠物那天没跑，或者还没落盘）")
        return

    active = [i for i, v in enumerate(hs) if v > 0]
    span = f"{hhmm(active[0] * 3600)}-{hhmm((active[-1] + 1) * 3600)}" if active else "无"
    busiest = max(range(24), key=lambda i: hs[i]) if active else None

    print(f"{stamp}   总计 {total:,} 下")
    line = f"  活跃时段 {span}"
    if busiest is not None:
        line += f"   最忙 {busiest:02d}:00（{hs[busiest]:,} 下）"
    print(line)
    print(f"  按小时 {spark(hs)}")
    print()

    if not keys:
        return
    peak = int(keys[0]["c"])
    for row in keys:
        c = int(row["c"])
        print(f"  {row['key']:<12} {c:>7,}  {bar(c, peak)}  {c / total * 100:5.1f}%")
    distinct = con.execute(
        "SELECT COUNT(DISTINCT key) AS n FROM key_hourly WHERE day = ?", (day,)
    ).fetchone()["n"]
    if distinct > len(keys):
        print(f"  …（那天一共用到 {distinct} 种键，上面只列了前 {len(keys)} 种）")


def cmd_today(con: sqlite3.Connection, args) -> None:
    day = args.day or dt.date.today().isoformat()
    print_day(con, day)


def cmd_report(con: sqlite3.Connection, args) -> None:
    print_day(con, args.day)


def cmd_week(con: sqlite3.Connection, args) -> None:
    end = dt.date.fromisoformat(args.day) if args.day else dt.date.today()
    days = [(end - dt.timedelta(days=i)).isoformat() for i in range(args.days - 1, -1, -1)]
    rows = [(d, day_total(con, d)) for d in days]
    peak = max((v for _, v in rows), default=0)
    grand = sum(v for _, v in rows)

    print(f"最近 {args.days} 天（{days[0]} → {days[-1]}）合计 {grand:,} 下")
    print(f"  按天 {spark([v for _, v in rows])}")
    print()
    for d, v in rows:
        mark = ""
        if v == 0:
            mark = "   ← 那天没有数据（宠物没跑？）"
        print(f"  {d}  {v:>8,}  {bar(v, peak, 24)}{mark}")

    # run_log 能区分「没敲键盘」和「没在跑」——只靠计数是分不出来的
    missing = [d for d, v in rows if v == 0]
    if missing:
        recovered = []
        for d, v in rows:
            if v > 0:
                continue
            r = con.execute(
                "SELECT COUNT(*) AS n FROM run_log WHERE started_at LIKE ?", (d + "%",)
            ).fetchone()
            if int(r["n"]) > 0:
                recovered.append(d)
        if recovered:
            print(
                "\n  注意：以下日子有运行记录但没敲一下键，是真的没敲："
                + "、".join(recovered)
            )


def cmd_runs(con: sqlite3.Connection, args) -> None:
    rows = con.execute(
        "SELECT id, started_at, ended_at, version, note FROM run_log ORDER BY id DESC LIMIT ?",
        (args.limit,),
    ).fetchall()
    if not rows:
        print("还没有运行记录")
        return
    print(f"最近 {len(rows)} 次运行（倒序）：")
    abnormal = 0
    for r in rows:
        end = r["ended_at"] or ""
        if end:
            print(f"  #{r['id']:<4} {r['started_at']}  →  {end}")
        else:
            abnormal += 1
            print(f"  #{r['id']:<4} {r['started_at']}  →  （没有正常结束：被强杀或断电）")
    if abnormal:
        # 最多丢 FLUSH_INTERVAL(10 秒) 的数据，这是设计里写明的取舍
        print(f"\n  其中 {abnormal} 次没有正常结束 —— 这些运行最后一次落盘之后的按键会丢（最多 10 秒）")


def main() -> None:
    p = argparse.ArgumentParser(description="keycount 报表（直接读宠物写的 SQLite 库）")
    p.add_argument("--db", help="库文件路径（默认 Godot 的 user:// 目录）")
    sub = p.add_subparsers(dest="cmd", required=True)

    t = sub.add_parser("today", help="今天")
    t.add_argument("day", nargs="?", help="覆盖日期 YYYY-MM-DD")
    t.set_defaults(func=cmd_today)

    r = sub.add_parser("report", help="指定某天")
    r.add_argument("day", help="日期 YYYY-MM-DD")
    r.set_defaults(func=cmd_report)

    w = sub.add_parser("week", help="最近若干天")
    w.add_argument("--days", type=int, default=7)
    w.add_argument("--day", help="以这天为终点，默认今天")
    w.set_defaults(func=cmd_week)

    u = sub.add_parser("runs", help="运行记录（能看出有没有没正常结束）")
    u.add_argument("--limit", type=int, default=10)
    u.set_defaults(func=cmd_runs)

    args = p.parse_args()
    db = resolve_db(args.db)
    args.func(connect(db), args)


if __name__ == "__main__":
    main()
