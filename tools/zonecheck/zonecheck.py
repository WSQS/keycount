#!/usr/bin/env python3
"""zonecheck —— 区域标记的只读检查器（`human` / `ai` / `legacy`）。

机制（照 arcsopho 的 cpp_playground，简化到 keycount 够用的程度）：

    标记成对、独立成行：``prefix >>> zone:human|ai`` … ``prefix <<<``
    配对**纯靠栈**（没有 id），允许嵌套；未标注 = ``legacy``；标记行本身不属于任何区域。

三个子命令：
    check   扫描/检查，报解析错误（退出码 1 = 有错）
    stats   每文件计数 + 区域 + 未标注区间（给编辑器上色用）
    judge   判「建议的内容」：基线=磁盘现状，待判=--new/stdin → allow / deny + 一句人话理由

约定：
- 只读，从不改文件。
- 零第三方依赖；用 ``uv run --no-project python tools/zonecheck/zonecheck.py`` 跑。
- **`exclude` 是安全面**：命中 exclude / generated 或不在 include 的路径，`judge` 一律 allow
  （"未纳入区域检查范围"）。往 exclude 里加东西 = 让那块地方**没有区域约束**，是有意识的决定。
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys

DEFAULTS = {
    "schema": 1,
    "prefixByExt": {},
    "defaultPrefix": "//",
    "include": [],
    "exclude": [],
    "generated": [],
    "defaultZone": "legacy",
    "defaultZoneByFile": {},
    "policy": {"crossZone": "error", "humanTouch": "error", "markerEdit": "error", "unmarkedTouch": "warn"},
}

ZONES = ("human", "ai")


# ---------------------------------------------------------------- 配置 / 路径

def find_root(start=None):
    """从 start（默认 cwd）向上找最近的含 .zonecheck.json 的目录。找不到返回 start。"""
    d = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(d, ".zonecheck.json")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.abspath(start or os.getcwd())
        d = parent


def load_config(root):
    cfg = dict(DEFAULTS)
    cfg["policy"] = dict(DEFAULTS["policy"])
    p = os.path.join(root, ".zonecheck.json")
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as f:
            loaded = json.load(f)
        for k, v in loaded.items():
            if k == "policy" and isinstance(v, dict):
                cfg["policy"].update(v)
            else:
                cfg[k] = v
    return cfg


def _glob_to_re(pat):
    pat = pat.replace("\\", "/")
    out = ["^"]
    i, n = 0, len(pat)
    while i < n:
        c = pat[i]
        if c == "*":
            if i + 1 < n and pat[i + 1] == "*":
                if i + 2 < n and pat[i + 2] == "/":
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        out.append(re.escape(c))
        i += 1
    out.append("$")
    return re.compile("".join(out))


def _any_match(rel, pats):
    return any(_glob_to_re(p).match(rel) for p in pats)


def covered(rel, cfg):
    """这个仓库相对路径会不会被区域纪律命中（include 命中 && 未被 exclude/generated 排除）。"""
    rel = rel.replace("\\", "/")
    if not _any_match(rel, cfg.get("include", [])):
        return False
    if _any_match(rel, cfg.get("exclude", [])):
        return False
    if _any_match(rel, cfg.get("generated", [])):
        return False
    return True


def prefix_for(rel, cfg):
    ext = os.path.splitext(rel)[1].lower()
    return cfg.get("prefixByExt", {}).get(ext, cfg.get("defaultPrefix", "//"))


# ---------------------------------------------------------------- 解析

def parse_text(text, prefix):
    """把一个文件的内容解析成区域。

    返回 dict：
      base:     "legacy" / "human" / "ai" —— 未标注行归谁。**整文件标记**（写在**第一行**的
                `prefix zone:human|ai`，不带 `>>>`）会改写它；否则是 legacy。
      errors:   [{line, code, message}]
      warnings: [{line, code, message}]（目前只有 file-marker-not-first-line）
      regions:  [{zone, begin, end, depth}]（begin/end 不含标记行）
      counts:   {human, ai, legacy, markers}
      unmarked: [[a, b]] （连续的 legacy 内容行范围；**不含标记行**）
    """
    lines = text.splitlines()
    p = re.escape(prefix)
    filemark = re.compile(r"^\s*" + p + r"\s*zone:(human|ai)\s*(?:-->)?\s*$")
    bgn = re.compile(r"^\s*" + p + r"\s*>>>\s*zone:(human|ai)\s*(?:-->)?\s*$")
    end = re.compile(r"^\s*" + p + r"\s*<<<\s*(?:-->)?\s*$")
    part_bgn = re.compile(r"^\s*" + p + r"\s*>>>")
    part_end = re.compile(r"^\s*" + p + r"\s*<<<")
    zone_val = re.compile(r"zone:\s*([A-Za-z_][A-Za-z0-9_]*)")

    errors, warnings, regions, kinds = [], [], [], []
    stack = []  # [{zone, line}]
    base = "legacy"

    for idx, line in enumerate(lines, start=1):
        if filemark.match(line):
            if idx == 1:
                # 整文件标记：定 base zone，本身算一行标记
                kinds.append("marker")
                base = filemark.match(line).group(1)
            else:
                # 位置不对：当普通注释，但**要出声** —— 否则就是“你写了、它没生效”
                kinds.append(stack[-1]["zone"] if stack else base)
                warnings.append({"line": idx, "code": "file-marker-not-first-line",
                                 "message": "整文件标记（`zone:human|ai`，不带 `>>>`）只有写在**第一行**才算数；这一行被当普通注释了"})
            continue
        if bgn.match(line):
            kinds.append("marker")
            stack.append({"zone": bgn.match(line).group(1), "line": idx})
            continue
        if end.match(line):
            kinds.append("marker")
            if not stack:
                errors.append({"line": idx, "code": "unpaired-end", "message": "结束标记没有对应的开始标记"})
            else:
                top = stack.pop()
                regions.append({"zone": top["zone"], "begin": top["line"] + 1, "end": idx - 1, "depth": len(stack)})
            continue
        if part_bgn.match(line):
            kinds.append("marker")
            zv = zone_val.search(line)
            if zv and zv.group(1) not in ZONES:
                errors.append({"line": idx, "code": "unknown-zone",
                               "message": f"zone 只认 human / ai，这里写的是 {zv.group(1)!r}"})
            else:
                errors.append({"line": idx, "code": "bad-format",
                               "message": "开始标记必须正好是 `>>> zone:human|ai`，不能有多余内容"})
            continue
        if part_end.match(line):
            kinds.append("marker")
            errors.append({"line": idx, "code": "bad-format",
                           "message": "结束标记必须正好是 `<<<`，不能重复类型或写别的东西"})
            continue
        kinds.append(stack[-1]["zone"] if stack else base)

    for top in stack:
        errors.append({"line": top["line"], "code": "unpaired-begin",
                       "message": f"开始标记（{top['zone']}）没有对应的 `<<<`"})

    counts = {"human": 0, "ai": 0, "legacy": 0, "markers": 0}
    for k in kinds:
        if k == "marker":
            counts["markers"] += 1
        else:
            counts[k] += 1

    unmarked, run_start = [], None
    for i, k in enumerate(kinds, start=1):
        if k == "legacy":
            if run_start is None:
                run_start = i
        else:
            if run_start is not None:
                unmarked.append([run_start, i - 1])
                run_start = None
    if run_start is not None:
        unmarked.append([run_start, len(kinds)])

    return {"base": base, "errors": errors, "warnings": warnings,
            "regions": regions, "counts": counts, "unmarked": unmarked}


# ---------------------------------------------------------------- 收集文件

def iter_covered_files(root, cfg, paths=None):
    if paths:
        for p in paths:
            rel = os.path.relpath(os.path.abspath(p), root).replace("\\", "/")
            if covered(rel, cfg):
                yield rel
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace("\\", "/")
            if covered(rel, cfg):
                yield rel


def read_text(path):
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


# ---------------------------------------------------------------- 子命令

def do_check(root, cfg, paths, as_json):
    errors, warnings = [], []
    for rel in iter_covered_files(root, cfg, paths):
        text = read_text(os.path.join(root, rel))
        if text is None:
            continue
        r = parse_text(text, prefix_for(rel, cfg))
        for e in r["errors"]:
            errors.append({"path": rel, **e})
        for w in r["warnings"]:
            warnings.append({"path": rel, **w})
    if as_json:
        print(json.dumps({"schema": 1, "ok": not errors, "errors": errors, "warnings": warnings},
                         ensure_ascii=False, indent=2))
    else:
        for w in warnings:
            print(f"{w['path']}:{w['line']}: [warn/{w['code']}] {w['message']}")
        for e in errors:
            print(f"{e['path']}:{e['line']}: [{e['code']}] {e['message']}")
        print(f"zonecheck: {len(errors)} 个错误 / {len(warnings)} 个警告")
    return 1 if errors else 0


def do_stats(root, cfg, paths, as_json):
    files, totals = [], {"files": 0, "human": 0, "ai": 0, "legacy": 0, "regions": 0}
    for rel in iter_covered_files(root, cfg, paths):
        text = read_text(os.path.join(root, rel))
        if text is None:
            continue
        r = parse_text(text, prefix_for(rel, cfg))
        totals["files"] += 1
        for k in ("human", "ai", "legacy"):
            totals[k] += r["counts"][k]
        totals["regions"] += len(r["regions"])
        files.append({
            "path": rel,
            "covered": True,
            "base": r["base"],
            "counts": r["counts"],
            "regions": r["regions"],
            "unmarked": r["unmarked"],
            "errors": r["errors"],
            "warnings": r["warnings"],
        })
    out = {"schema": 1, "root": root.replace("\\", "/"), "totals": totals, "files": files}
    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print(f"zonecheck stats: {totals['files']} 文件  human={totals['human']} ai={totals['ai']} "
              f"legacy={totals['legacy']} regions={totals['regions']}")
    return 0


def _severity(code, cfg):
    key = {"human-touch": "humanTouch", "marker-edit": "markerEdit",
           "cross-zone": "crossZone", "unmarked-touch": "unmarkedTouch"}[code]
    return cfg.get("policy", {}).get(key, "off")


def _touched_zones(parsed, ranges):
    """ranges 是 1-based [[a,b]]；返回 (zones set, legacy_touched bool)。

    逐行取**最内层**区域（depth 最大）的归属；没有任何区域覆盖时归文件的 `base`。
    这样 “base=human 的文件里切出一块 ai” 就能正确判成“只在 ai 区改动”。
    """
    zones, legacy = set(), False
    regions = parsed["regions"]
    base = parsed.get("base", "legacy")
    for a, b in ranges:
        for ln in range(a, b + 1):
            best = None
            for rg in regions:
                if rg["begin"] <= ln <= rg["end"] and (best is None or rg["depth"] > best["depth"]):
                    best = rg
            z = best["zone"] if best else base
            if z == "legacy":
                legacy = True
            else:
                zones.add(z)
    return zones, legacy


def judge(root, cfg, rel, new_text, actor, use_policy):
    """判：基线=磁盘，待判=new_text。返回 (result_dict, exit_code)。"""
    base_text = read_text(os.path.join(root, rel))
    if not covered(rel, cfg):
        res = {"schema": 1, "from": "disk", "to": "proposed", "actor": actor, "decision": "allow",
               "reason": "该路径未纳入区域检查范围（不在 include，或命中 exclude/generated）",
               "violations": []}
        return res, 0
    base_text = base_text or ""
    prefix = prefix_for(rel, cfg)
    if base_text == new_text:
        res = {"schema": 1, "from": "disk", "to": "proposed", "actor": actor, "decision": "allow",
               "reason": "与磁盘内容零改动", "violations": []}
        return res, 0

    base = parse_text(base_text, prefix)
    prop = parse_text(new_text, prefix)
    base_lines, new_lines = base_text.splitlines(), new_text.splitlines()

    # 标记行有没有被改动
    def marker_lines(t):
        out = []
        for i, ln in enumerate(t.splitlines(), start=1):
            if i == 1 and re.match(r"^\s*" + re.escape(prefix) + r"\s*zone:(human|ai)\s*(?:-->)?\s*$", ln):
                out.append(ln.strip())   # 整文件标记
            elif re.match(r"^\s*" + re.escape(prefix) + r"\s*(>>>\s*zone:(human|ai)|<<<)\s*(?:-->)?\s*$", ln):
                out.append(ln.strip())
        return sorted(out)

    markers_changed = marker_lines(base_text) != marker_lines(new_text)

    sm = difflib.SequenceMatcher(a=base_lines, b=new_lines, autojunk=False)
    touched_base, touched_new = [], []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        if i2 > i1:
            touched_base.append([i1 + 1, i2])
        if j2 > j1:
            touched_new.append([j1 + 1, j2])

    zones_b, legacy_b = _touched_zones(base, touched_base)
    zones_n, legacy_n = _touched_zones(prop, touched_new)
    zones = zones_b | zones_n
    legacy_touched = legacy_b or legacy_n

    violations = []

    def add(code, message):
        sev = _severity(code, cfg)
        if sev == "off":
            return
        violations.append({"code": code, "rule": "policy." + code, "severity": sev,
                           "message": f"[{sev}] {message}"})

    if actor == "ai" and markers_changed:
        add("marker-edit", f"{rel}：改动动了区域标记行。标记只由人写。")
    if actor == "ai" and "human" in zones:
        add("human-touch",
            f"{rel}：actor=ai 的改动碰到了 human 区。human 区只能由人改 —— "
            f"要么把改动挪到 ai 区/未标注区，要么请人自己改这一段。")
    if "human" in zones and "ai" in zones:
        add("cross-zone", f"{rel}：同一次改动同时碰了 human 与 ai 区，请拆开。")
    if legacy_touched:
        add("unmarked-touch", f"{rel}：改动落在未标注（legacy）行上。")

    deny = any(v["severity"] == "error" for v in violations)
    decision = "deny" if deny else "allow"
    if not violations:
        reason = "未碰任何受约束区域"
    else:
        reason = "；".join(v["message"] for v in violations if v["severity"] == "error") or \
                 "；".join(v["message"] for v in violations)
    res = {"schema": 1, "from": "disk", "to": "proposed", "actor": actor,
           "decision": decision, "reason": reason, "violations": violations,
           "files": [{"path": rel, "touchedZones": sorted(zones), "touchedUnmarked": legacy_touched}]}
    code = 1 if (deny and use_policy) else 0
    return res, code


# ---------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(prog="zonecheck", description="区域标记的只读检查器")
    ap.add_argument("--root", help="工程根（默认从 cwd 向上找 .zonecheck.json）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("check", "stats"):
        sp = sub.add_parser(name)
        sp.add_argument("paths", nargs="*")
        sp.add_argument("--json", action="store_true")

    spj = sub.add_parser("judge")
    spj.add_argument("--path", required=True, help="仓库相对路径（基线）")
    spj.add_argument("--new", help="建议内容的文件；不给则读 stdin")
    spj.add_argument("--actor", choices=["ai", "human"], default="human")
    spj.add_argument("--policy", action="store_true", help="带上才按 policy 决定退出码")
    spj.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    root = os.path.abspath(args.root) if args.root else find_root()
    cfg = load_config(root)

    if args.cmd == "check":
        return do_check(root, cfg, args.paths, args.json)
    if args.cmd == "stats":
        return do_stats(root, cfg, args.paths, args.json)
    if args.cmd == "judge":
        if args.new:
            new_text = read_text(args.new)
            if new_text is None:
                print(f"zonecheck: 读不到 --new 文件：{args.new}", file=sys.stderr)
                return 2
        else:
            new_text = sys.stdin.read()
        res, code = judge(root, cfg, args.path.replace("\\", "/"), new_text, args.actor, args.policy)
        if args.json:
            print(json.dumps(res, ensure_ascii=False, indent=2))
        else:
            print(("ALLOW  " if res["decision"] == "allow" else "DENY   ") + res["reason"])
        return code
    return 2


if __name__ == "__main__":
    sys.exit(main())
