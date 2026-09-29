keycount — 桌面宠物 + 每日键盘计数

一只住在桌面上的宠物，顺便把你「今天敲了多少下键盘、分别是哪些键、现在打多快」表演出来。
本地存储，不外传，**只存计数不存内容**。

形态演进过两次：最初想做命令行 daemon → 改成桌宠 → 技术栈定为 **原生 Godot 4.7.2 + 自写 GDExtension**。
所有决策依据和实测数据都在 [`SPEC.md`](SPEC.md)，那份文件比这份 README 详细。

## 现状（v0：链路已跑通并验证）

| 能力 | 状态 |
|---|---|
| 透明 / 置顶 / 无边框窗口浮在桌面 | ✅ 实测截图 `shots/crop-final.png` |
| 全局键盘钩子（**非焦点**也能抓） | ✅ `dropped=0` |
| 键名归一化（`Shift+A` → `a`） | ✅ 自检 25/25 |
| **不抢键盘焦点** | ✅ `focus_true_frames=0`、`input_keys=0`，`hwndFocus` 始终是别的窗口 |
| 宠物状态机（idle / typing / excited / sleepy） | ✅ 由实时 KPM 驱动 |
| **统计落盘**（真 SQLite，崩溃安全 WAL） | ✅ 重启不归零；强杀能被发现 |
| 命令行报表 | ✅ `tools/keycount.py`（直读同一个库） |
| 点击穿透 | ❌ 扩展里写好了，宠物还没调用 |
| 真素材 / 动画 | ❌ 现在是个占位圆 |
| 托盘图标 / 开机自启 / 中文字体 | ❌ 都没有 |

## 结构

```
native/          平台核心，不依赖 Godot
  kc_hook.h/.cpp   全局钩子：自己的线程 + 自己的消息循环
  kc_store.h/.cpp  计数存储：SQLite，按 (day,hour,key) 分桶
  test_hook.cpp    钩子验证（--selftest / 实机抓键）
  test_store.cpp   存储验证（39 条断言，不需要 Godot）
  build_store.sh   编存储验证 exe
thirdparty/
  sqlite/          SQLite amalgamation 3.53.4 + 版本固定记录 PIN.txt
gdext/           GDExtension 接线层
  src/kc_hook_ext.*     KeyCountHook（native 钩子的接线）
  src/kc_window.*       KeyCountWindow（Win32 窗口样式）
  src/kc_store_ext.*    KeyCountStore（SQLite 接线）
  src/kc_guard.*        KeyCountGuard（单实例锁）
  src/kc_module.cpp     库初始化（注册上面四个类）
  SConstruct            构建脚本（含 sqlite3.c）
  api/                  从本机 Godot dump 出来的 extension_api.json
tools/
  keycount.py      命令行报表（Python 自带 sqlite3，不需要编东西）
  zonecheck/       区域标记（human / ai）的只读检查器（stdlib，uv run --no-project python）
.zonecheck.json   区域标记的配置（include/exclude/defaultZone/policy）
.clang-format     C/C++ 风格（反推自现有代码；保存时格式化用）
pet/             Godot 工程
  project.godot         透明置顶 + no_focus + gl_compatibility
  pet.gd                占位宠物 + 状态机 + 落盘口径（什么算一天/flush 频率）
  addons/keycount/      扩展的 .gdextension + 编好的 dll
agent-test/      运行/验证工具箱（可重跑；见 agent-test/README.md）
  run-pet.ps1           **启动器 —— 启动宠物必须用它**
  inject3.ps1           往自测窗口注入按键，验证全局抓键
  fg2.ps1               查「键盘到底在谁手上」（GetGUIThreadInfo）
  drag-test.ps1         模拟真实拖拽
  screenshot.ps1/crop2.ps1  截图与裁剪
  spike-godot/          Godot 透明窗口实测工程（Vulkan 黑方块 vs OpenGL 正常的原始证据）
SPEC.md          全部实测结论与踩坑记录
```

## 环境要求

- **Godot 4.7.2**（GDExtension 的 `api_version` 与 `compatibility_minimum` 都对准它）
- **scons** + **MSVC**（VS 2022 或 Build Tools）—— 编扩展用
- **MinGW g++**（可选）—— 只用来编 `native/` 的独立验证 exe
- `godot-cpp`（构建时自动需要，见下）

## 构建

```bash
# 1) godot-cpp：版本必须与 Godot 对齐（commit 见 gdext/GODOT_CPP_PIN.txt）
cd gdext
git clone --depth 1 https://github.com/godotengine/godot-cpp.git

# 2) 编扩展（sqlite3.c 也在这步一起编，首次会多花十几秒）
scons platform=windows target=template_debug   api_version=4.7 -j12
scons platform=windows target=template_release api_version=4.7 -j12
cp bin/*.dll ../pet/addons/keycount/bin/

# 3) 平台核心的独立验证（都不需要 Godot）
cd ../native
./build_store.sh && ./test_store.exe      # 存储：39 条断言

g++ -std=c++17 -O2 -Wall -Wextra -static -static-libgcc -static-libstdc++ \
    -o test_hook.exe kc_hook.cpp test_hook.cpp -luser32
./test_hook.exe --selftest                # 键名：25 条断言
```

## 运行

```powershell
# 首次需过一遍导入，否则 GDExtension 不会被加载（之后 run-pet.ps1 会自动做）
godot --headless --editor --quit --path pet

# 启动（必须用启动器 —— 它会记录「宠物出现之前谁持有键盘」，传给宠物用来把焦点还回去）
powershell -File agent-test/run-pet.ps1

# 看数据（宠物没在跑也能看；直读同一个 SQLite 库）
uv run --no-project python tools/keycount.py today
uv run --no-project python tools/keycount.py week
uv run --no-project python tools/keycount.py runs    # 能看出有没有没正常结束的运行
```

库在 `%APPDATA%\Godot\app_userdata\keycount pet\keycount.db`（Godot 的 `user://`）。

**为什么不能直接双击跑**：Godot 在 GDExtension 初始化**之前**就创建并激活了主窗口，
所以在扩展内部永远看不到「原来谁持有键盘」。只有启动器能在拉起宠物前那一瞬记下它。
少了这一步，宠物启动后会攥着 `hwndFocus`，你随手打的字会落进宠物里。
详见 `SPEC.md` 的「抢焦点这件事打了三仗」。

## 第三方依赖：两处刻意不同的处理

| 依赖 | 进仓库？ | 理由 |
|---|---|---|
| `godot-cpp` | ❌ 不进，只记 commit 在 `gdext/GODOT_CPP_PIN.txt` | 35MB 的仓库、自带构建系统，且**必须与 Godot 版本对齐**；进仓库只会让它慢慢漂移 |
| `thirdparty/sqlite/` | ✅ 进 | amalgamation 就三个文件、无构建系统依赖，编进去就完事；不进仓库反而让“换台机器就能编”这个前提消失 |

两处不一致是有意的，不是遗漏。

## 两条容易踩的坑

1. **渲染器必须是 `gl_compatibility`。** 本机实测 Vulkan/Forward+ 下透明窗口会渲染成**纯黑方块**，
   把桌面整个遮住（RTX 4060 Laptop + Win11 26200 + 驱动 566.36 复现）。
2. **Godot 默认字体不含中文字形。** 所以占位宠物上写的是 ASCII 文字；
   要显示中文得自带字体（Noto Sans SC 之类，做子集更小）。

## 已验证的环境

Windows 11 build 26200 · RTX 4060 Laptop · 驱动 566.36 · Godot 4.7.2.stable.steam · MSVC/VS 2022 · scons 4.8.1
