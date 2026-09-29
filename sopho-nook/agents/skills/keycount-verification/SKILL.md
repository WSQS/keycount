---
name: keycount-verification
description: 在 keycount 仓库里改完东西后，怎么按层证明它真的还能用（核心自检 → 扩展编译 → 集成 → 不抢焦点 → 落盘 → 单实例）。Use when changing anything in this repo, before claiming a change works, or when a run of the pet behaves unexpectedly.
---

# 在这个仓库里怎么验（keycount 项目内）

第一事实源：仓库根 `SPEC.md`（每条结论都带实测数字）。本文件是**流程**；
硬条在 `../ROLE.md`。冲突时以 `SPEC.md` 的实测记录为准。

**核心纪律：分层验，不要一上来就开宠物。** 本项目的绝大部分逻辑不依赖 Godot，
所以大部分改动能在一秒内证完 —— 别把「开一次宠物、肉眼看一眼」当验收。

## 步骤

### 0. 判断你改了哪一层

| 改了 | 走哪几步 |
|---|---|
| `native/**`（钩子、存储、键名） | 1 |
| `gdext/**`（接线层、SConstruct） | 1 → 2 |
| `pet/**`（口径、状态机、窗口） | 1 → 2 → 3 → 4 → 5 |
| `sopho-nook/**` | 见 `sopho-nook/tools/criteria.sh` |

### 1. 核心自检（不需要 Godot，秒级）

```bash
native/build_store.sh && native/test_store.exe   # 存储：39 条断言
native/test_hook.exe --selftest                  # 键名：25 条断言
```

**判据**：两条都要以「全部通过 ✅（失败 0 项）」结尾，退出码 0。
注意 `test_store.exe` 必须在 `native/` 里跑（它在 CWD 建测试库）。

### 2. 扩展编译

```bash
cd gdext && scons platform=windows target=template_debug api_version=4.7 -j12
cp bin/*.dll ../pet/addons/keycount/bin/
```

**判据**：`exit=0`，日志里没有 ` error ` / `warning C`。
**注意**：忘了拷 dll 就是「改了没生效」——启动器会自动拷，但手动改完要自己记得。

### 3. 集成（必须用启动器）

```bash
powershell -File evidence/run-pet.ps1     # 或 Windows 上直接跑那一行
```

**不要直接跑 Godot**：Godot 在 GDExtension 初始化**之前**就创建并激活了主窗口，
所以扩展内部永远看不到「原来谁持有键盘」；少了启动器那一步，宠物会攥着你的键盘焦点。

**判据**：`pet/run.log` 里出现 `hook.start() -> true`、`库已打开`、
`ALIVE ... db=ok`，并且**没有** `!!` 开头的行。

### 4. 不抢焦点（这条最容易假通过）

```bash
powershell -File evidence/fg2.ps1
```

**判据**：输出的 `hwndFocus` **不能是** `keycount pet (DEBUG)`，
而且 `pet/run.log` 的 ALIVE 行里 `input_keys=0`。

为什么必须用 `fg2.ps1`：`GetForegroundWindow` 与 Godot 的 `has_focus()` 在这条链上都**不可信**
（实测过：前者会报成宠物、后者忽真忽假）。真正决定键盘去向的是 `GetGUIThreadInfo` 的 `hwndFocus`。

### 5. 全局抓键 + 落盘

```bash
powershell -File evidence/inject3.ps1          # 往自测窗口注入 9 下
uv run --no-project python tools/keycount.py today
```

**判据**：注入窗口自己收到 `Abc`；`run.log` 里出现 9 条 `KEY` 行；
库里今日总数**涨 9**（不是 18 —— 涨 18 就是单实例没守住，见下）。

落盘要**重启一次**再验一遍：第二次启动的日志里应有
`2026-xx-xx 库里已有 N 下`，也就是数字**没有归零**。这是「落盘」区别于「内存计数」的唯一证据。

### 6. 单实例（两个宠物会把每一下记两次）

```bash
# 宠物在跑时，绕过启动器直连 Godot
"$GODOT" --path pet --rendering-driver opengl3
```

**判据**：第二个进程的 stdout 打出
`keycount: 已经有一个宠物在跑，本进程退出（两个一起跑会让计数翻倍）`，且随后库不再多计。

启动器那层（`-Restart` / `-AllowMultiple`）是礼貌拦截，**真正的保证**是宠物自己拿的
命名内核互斥体（`KeyCountGuard`）—— 只拦前者的实现是不牢的。

## 已知的坑（都在 `SPEC.md` 里，别重踩）

- **透明窗口必须 `gl_compatibility`**：本机实测 Vulkan/Forward+ 下会渲染成纯黑方块，把桌面全遮住。
- **`display/window/size/no_focus` 无效**：实测 `ex_style` 里没有 `noactivate`。起作用的是启动器。
- **合成输入的 `scancode` 是 0**：所以键名归一化**以 vkCode 为主**、扫描码兜底。
- **PowerShell 里 `$null.Count` 也是 `$null`**：`$x -eq 0` 会判为假，重试循环被静默跳过。
  空管道结果赋给变量得到的是 `$null`，不是空数组 —— 函数要用 `return ,$arr` 兜住。
- **`.cmd` 必须纯 ASCII + LF**：cmd.exe 遇到「LF + 非 ASCII」会行错位，把真实代码行当命令跑。
