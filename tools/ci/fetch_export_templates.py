#!/usr/bin/env python3
"""把 Godot 官方导出模板里**只需要的 windows 部分**取出来，装到 Godot 认的位置。

为什么不用官方 tpz 整包：那是 1.28GB（全平台合集），而 Windows Desktop 导出只用
`windows_release_x86_64.exe`（约 100MB）。CI 上无所谓，但本地/窄带宽时差得很明显。

Godot 去哪找模板（源码 `EditorExportPlatform::find_export_template`）：
    <templates_dir>/<GODOT_VERSION_FULL_CONFIG>/<template_file_name>
`templates_dir` = `%APPDATA%\\Godot\\export_templates`（Windows）。
所以目录名必须与编辑器版本串严格一致，例如 `4.7.2.stable`。

用法：
    python tools/ci/fetch_export_templates.py --version 4.7.2 --dest "%APPDATA%\\Godot\\export_templates"
    python tools/ci/fetch_export_templates.py --version 4.7.2 --tpz 已下好的.tpz --dest ...
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

# 导出 release/前面那个 exe 以及 debug 对照，各带一个 console 变体
MEMBERS = [
    "windows_release_x86_64.exe",
    "windows_release_x86_64_console.exe",
    "windows_debug_x86_64.exe",
    "windows_debug_x86_64_console.exe",
]
URL = "https://github.com/godotengine/godot/releases/download/{v}-stable/Godot_v{v}-stable_export_templates.tpz"


def default_dest() -> Path:
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA") or str(Path.home() / "AppData/Roaming")
        return Path(appdata) / "Godot" / "export_templates"
    return Path.home() / ".local/share/godot/export_templates"


def main() -> int:
    # Windows 上 Python 的 stdout 默认是 cp1252，打印中文会 UnicodeEncodeError（CI 上实测炸过）。
    # 这里先自己兜底，workflow 里另外设了 PYTHONUTF8=1。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="例如 4.7.2")
    ap.add_argument("--tpz", help="已下好的 .tpz；不给就从 GitHub 下（1.28GB）")
    ap.add_argument("--dest", help=f"模板根目录，默认 {default_dest()}")
    ap.add_argument("--dir-name", help="模板目录名，默认 <version>.stable")
    args = ap.parse_args()

    dest_root = Path(args.dest) if args.dest else default_dest()
    dir_name = args.dir_name or f"{args.version}.stable"
    target = dest_root / dir_name
    target.mkdir(parents=True, exist_ok=True)

    tpz = Path(args.tpz) if args.tpz else Path.cwd() / f"Godot_v{args.version}-stable_export_templates.tpz"
    if not tpz.is_file():
        url = URL.format(v=args.version)
        print(f"下载 {url}")
        urllib.request.urlretrieve(url, tpz)  # noqa: S310 (固定的官方地址)
    print(f"使用 {tpz}（{tpz.stat().st_size / 1048576:.1f} MB）")

    with zipfile.ZipFile(tpz) as z:
        names = z.namelist()
        got = 0
        for base in MEMBERS:
            member = f"templates/{base}"
            if member not in names:
                print(f"  !! tpz 里没有 {member}（跳过）")
                continue
            with z.open(member) as src, open(target / base, "wb") as out:
                shutil.copyfileobj(src, out)
            got += 1
        # version.txt 是编辑器校验模板是否装好的依据，内容就是 <version>.stable
        with z.open("templates/version.txt") as src, open(target / "version.txt", "wb") as out:
            shutil.copyfileobj(src, out)
    print(f"已装 {got} 个模板 + version.txt → {target}")
    return 0 if got else 1


if __name__ == "__main__":
    sys.exit(main())
