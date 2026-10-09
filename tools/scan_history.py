#!/usr/bin/env python3
"""开源卫生检查：扫**全部 git 对象**（含不可达对象）里不该出现的东西。

为什么扫「全部对象」而不是「某个提交」：2026-10-09 清理历史时踩到两个坑 ——
  1) `git filter-repo --path <具体路径>` 漏掉了重命名之前的路径（evidence/ → agent-test/）；
  2) `git commit --amend` 掉的旧提交仍被 reflog 保活，`git fsck --unreachable` 还看不到它，
     而那条提交信息里恰好写着要清理的敏感串。
只扫 HEAD、或只扫可达对象，这两类都会漏 ⇒ 这里用 `--batch-all-objects`。

规则刻意写成**形状**而不是具体词：本机用户名、自建服务的域名这些都靠形状拦，
这样仓库里这份文件本身不含任何敏感串。项目专属词表放
`tools/leak-patterns.local.txt`（.gitignore 挡住；每行一条 Python 正则，`#` 开头忽略）。

用法：uv run --no-project python tools/scan_history.py     （仓库任意位置）
退出码：0 = 干净；1 = 有问题；2 = 自身出错（**不许当成通过**）
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY_SNIFF = 8192  # 前 8KB 有 NUL 就当二进制，跳过文本规则

# 本仓库允许出现的域名（第三方源码里引用的官方站点）。形状规则见下。
SELF_HOSTED = (
    r"https?://(gitlab|jenkins|jira|confluence|nexus|artifactory|gitea|gerrit)\."
    r"[A-Za-z0-9-]+\.[A-Za-z]{2,}"
)

# 通用规则：不含任何真实敏感串
GENERIC: list[tuple[str, str]] = [
    ("GitHub PAT", r"ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"),
    ("API key 形态", r"\bsk-[A-Za-z0-9]{20,}"),
    ("AWS key", r"\bAKIA[0-9A-Z]{16}\b"),
    ("私钥", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("自建服务域名", SELF_HOSTED),
    # 绝对 Windows 用户路径（`<user>` 占位、`...` 省略写法除外）
    ("绝对用户路径", r"[A-Za-z]:[\\/]Users[\\/](?!<user>|\.\.\.)[A-Za-z0-9_][A-Za-z0-9._-]*"),
    ("邮箱", r"[A-Za-z0-9._%+-]+@(?!github\.com|users\.noreply\.github\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
]


def run(cmd: list[str], **kw) -> bytes:
    return subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, check=True, **kw).stdout


def load_patterns() -> list[tuple[str, re.Pattern[str]]]:
    pats = [(name, re.compile(rx)) for name, rx in GENERIC]
    local = ROOT / "tools" / "leak-patterns.local.txt"
    if local.is_file():
        for i, line in enumerate(local.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                pats.append((f"local:{local.name}:{i}", re.compile(line)))
            except re.error as e:
                raise SystemExit(f"tools/leak-patterns.local.txt 第 {i} 行不是合法正则：{e}")
    return pats


def sha_to_path() -> dict[str, str]:
    out: dict[str, str] = {}
    for line in run(["git", "rev-list", "--all", "--objects"]).decode("utf-8", "replace").splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            out.setdefault(parts[0], parts[1])
    return out


def main() -> int:
    pats = load_patterns()
    paths = sha_to_path()
    commits = run(["git", "rev-list", "--all", "--count"]).decode().strip()

    print(f"########## 历史卫生（全部 git 对象；{commits} 个提交）")
    problems: list[str] = []
    binary_skipped = 0
    blobs = 0

    proc = subprocess.Popen(
        ["git", "cat-file", "--batch-all-objects", "--batch"],
        cwd=ROOT, stdout=subprocess.PIPE,
    )
    assert proc.stdout is not None
    while True:
        header = proc.stdout.readline()
        if not header:
            break
        try:
            sha, otype, size = header.split()
        except ValueError:
            problems.append(f"无法解析 cat-file 输出头：{header!r}")
            break
        data = proc.stdout.read(int(size))
        proc.stdout.read(1)  # 对象内容后的换行
        if otype != b"blob":
            continue
        blobs += 1
        sha_s = sha.decode()
        where = paths.get(sha_s, f"<不可达对象 {sha_s[:12]}>")

        if data[:64].startswith(b"\x89PNG"):
            problems.append(f"PNG 二进制：{where}")
            continue
        if b"\x00" in data[:BINARY_SNIFF]:
            binary_skipped += 1
            continue  # 二进制内容不做文本规则（避免第三方源码里的合法串误报）

        text = data.decode("utf-8", "replace")
        for name, rx in pats:
            m = rx.search(text)
            if m:
                got = sorted({x.group(0) for x in rx.finditer(text)})[:3]
                problems.append(f"[{name}] {where}  ← {', '.join(got)}")

    # 提交信息也扫（amend 掉的旧提交就是栽在这里）
    msgs = subprocess.run(
        ["git", "log", "--all", "--format=%h %s%n%b"], cwd=ROOT,
        stdout=subprocess.PIPE, check=True,
    ).stdout.decode("utf-8", "replace")
    for name, rx in pats:
        for m in rx.finditer(msgs):
            problems.append(f"[{name}] 提交信息里命中 ← {m.group(0)}")

    # 二进制不得入库
    tracked = run(["git", "ls-files"]).decode("utf-8", "replace").splitlines()
    bins = [p for p in tracked if re.search(r"\.(exe|dll|pdb|lib|o|obj|so|dylib)$", p, re.I)]

    if problems:
        print(f"  FAIL   命中 {len(problems)} 处（规则 {len(pats)} 条）")
        for p in problems[:60]:
            print(f"         {p}")
        if len(problems) > 60:
            print(f"         …（还有 {len(problems) - 60} 处）")
    else:
        print(f"  PASS   无敏感串、无 PNG（规则 {len(pats)} 条；扫了 {blobs} 个 blob，"
              f"其中 {binary_skipped} 个二进制被跳过）")

    if bins:
        print(f"  FAIL   跟踪文件里有二进制（{len(bins)} 个）")
        for p in bins[:10]:
            print(f"         {p}")
    else:
        print("  PASS   跟踪文件里无二进制（构建产物由 CI 出，不入库）")

    ok = not problems and not bins
    print()
    print("########## 历史卫生: 全部通过 ✅" if ok else "########## 历史卫生: 有问题 ❌")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        # 自身出错必须是 2：绝不能被当成「干净」
        print(f"!! 扫描器自身失败：{e}", file=sys.stderr)
        sys.exit(2)
