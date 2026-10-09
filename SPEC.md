# keycount — 桌宠（形态已从 daemon 改为桌宠）

一只住在桌面上的宠物，顺便把你「今天敲了多少下键盘、现在打字多快」表演出来。
本地存储，不外传，历史数据只存计数不存内容。

## 架构：两个进程

```
┌─ collector（无界面，常驻）──────────┐        ┌─ pet（图形进程）──────────┐
│  WH_KEYBOARD_LL 全局钩子            │  IPC   │  透明置顶窗口 + 动画      │
│  → 归一化键名                        │ ─────► │  宠物状态机              │
│  → SQLite 按 (day,hour,key) 聚合    │ 每秒1次 │  拖拽 / 托盘 / 点它看报表 │
└────────────────────────────────────┘        └──────────────────────────┘
```

**为什么拆开：** 钩子那半已经在你机器上验证过（见下），是整条链路里最不该反复重写的东西；
图形那半是最可能要换技术栈的。拆开后换宠物渲染不用碰采集器，宠物关掉了计数也照样不断。

### ⚠️ 架构修订：双进程降级为可选

查了参考实现之后（见下一节），这个双进程拆分**不是必须的**。ayangweb/BongoCat 22k star、MIT、跑三个平台，
用的是**单进程**：Rust 侧持有输入监听，把窗口隐藏掉不等于进程退出，所以「关掉宠物就停止计数」这个担心
在单进程里同样不成立。

单进程对我们够用：Rust 侧同时管钩子、SQLite 聚合和窗口；Vue 侧只负责画猫。
代价是 `keycount today` 这种终端查询要么做成同一个二进制的子命令，要么以后单独开个小 CLI 直读同一个 db 文件。

什么时候值得回到双进程：你希望**宠物彻底退出时仍然在计数**，或者以后要把宠物渲染整个换掉而不重启采集器。
先按单进程做，真疼了再拆。

## 参考实现：Bongo Cat 是三个不同的项目

| 项目 | 技术栈 | 说明 |
|---|---|---|
| **Bongo Cat Mver**（Windows 原版，MMmmmoko） | C++ 主体 + C# WPF 设置界面 + Live2D Cubism | MIT，前身 `kuroni/bongocat-osu`（C++/SFML）。仓库源码停在 v0.1.4 左右，后续版本未同步开源。网上有文章说它是 Electron+Canvas，**是错的**。 |
| **ayangweb/BongoCat** v2.0.0（23,660 star / 1,160 fork，MIT） | **纯 Rust workspace，20 个 crate，edition 2024，rust-version 1.97。没有 Tauri、没有 Vue、没有任何 JS。** Windows 覆盖层用 `windows` 0.62.2 crate 的 **Direct3D11 + DirectComposition + DXGI**；macOS 用 Metal + CAMetalLayer + NSPanel；设置界面用 **GPUI**（`gpui-kit` 0.7.0）；Live2D 用 **vendor 进来的 Cubism Native SDK 5-r.5**（`vendor/cubism/5-r.5/Core/dll/windows/x86_64/Live2DCubismCore.dll`），FFI 层是 `crates/bongocat-live2d` + `tools/cubism-bindgen`；托盘 `muda`、全局热键 `global-hotkey`、手柄用作者自己的 `gilrs` fork。**存储用 `atomic-write-file` 原子写文件，不是 SQLite。** |
| **xrr2016/BongoCat** | 纯 C × SDL3 × OpenGL × Live2D | 另一个重写版 |

> ⚠️ **中文资料（DeepWiki、掘金/腾讯云博客）里说的「Tauri v2 + Vue 3 + Pinia + live2d web SDK」是它的 v1 架构，现在已经不是了。**
> 只有直接读 master 的 `Cargo.toml` / `crates/` 才算数。这条教训记在这里：搜出来的二手技术栈描述会过期。
>
> 它的 `docs/adr/` 有 **74 篇 ADR**，`docs/phase-0/` 是一整套技术 spike 报告
> （`input-windows-spike.md`、`overlay-windows`、`cubism-core-r5-probe.md`、`cubism-sdk-source-and-license.md`）。
> 想自己写原生透明覆盖层，这些是现成的路书。

四个实现里**没有一个用 Electron**，全部是「原生渲染 + Live2D」。

### 跟我们的差别（重要）

它的 README 明写「**绝不收集任何用户数据**」「支持离线运行」。
而我们这个功能的核心就是**把击键落盘**。这两件事立场相反 —— 意味着：

1. 这个功能不可能被上游接受，只能是你自己的私有 fork；
2. fork 之后不能再说「跟上游保持一致」，要接受长期分叉。

好处是：**Windows 上最难的那几块它已经解完了** —— 透明置顶覆盖层（D3D11+DirectComposition）、
Live2D Cubism 原生 FFI 绑定、全局输入捕获、托盘、开机自启（`auto-launch`）、打包与更新。
我们真正要写的只是「按键 → 归一化 → 聚合入库 → 报表 → 驱动状态」。

素材授权：它把 Cubism Native SDK 的 `LICENSE.md` / `NOTICE.md` 一起 vendor 了，并且写了
`docs/phase-0/cubism-sdk-source-and-license.md` 和 `dependency-license-inventory.md`，**这是我们要照抄的做法**。
模型另有来源：[Awesome-BongoCat](https://github.com/ayangweb/Awesome-BongoCat)——每个模型的授权各不相同，要逐个看。

## 已实测确认的事实（本机 Windows 11 build 26200）

| 栈 | 全局钩子 | 实测证据 | 产物 |
|---|---|---|---|
| Python + pynput 1.8.2 | ✅ | 4 秒 29 个事件，直接给键名（`Key.enter`/`Key.space`/字母） | 需 PyInstaller |
| C# WH_KEYBOARD_LL，纯 P/Invoke | ✅ | 7 个 keydown，钩子句柄非 0 | 单文件 exe **164KB** |
| Node uiohook-napi 1.5.5 | ✅ | 7 个 keydown，keycode 2/3/4/28/30/46/48 = `1 2 3 Enter a c b` | — |

Node 那条我一度判为有风险（「Node 25 = ABI 141，预编译不覆盖」）——**这个判断是错的**：
它是 napi-rs 模块，N-API ABI 稳定，预编译产物在 Node 25 上加载并收到按键均正常。

验证方式：程序自己弹窗口夺焦，用 `SendKeys` 往**它自己**里打字（`agent-test/inject.ps1`），
没有向其他任何窗口注入按键。证据脚本在 `agent-test/`。

### 与栈无关的硬限制

钩子看到的是**物理按键**，不是字符。拼音输入法打「你好」记为 `n i h a o` 五下。
拿中文字符要走 TSF/UI Automation，那会读到你输入的正文 —— 本项目不做。

## Godot 路线的实测结果（2026-09-28，本机 stock Godot 4.7.2 Steam 版）

做了个最小测试工程 `agent-test/spike-godot/`：420×420、borderless、always_on_top、transparent、
per_pixel_transparency/allowed，画一个会呼吸的圆，然后全屏截图对比。

| 渲染器 | 结果 |
|---|---|
| **Vulkan / Forward+（默认）** | ❌ **窗口渲染成一块 420×420 的纯黑方块**，桌面被完全遮住，只有圆是亮的。这正是社区报告的 NVIDIA + Vulkan present-method 问题，在 RTX 4060 Laptop + Windows 11 26200 + 驱动 566.36 上复现。 |
| **OpenGL3 / Compatibility** | ✅ 透明正常：圆浮在桌面之上，四角能看到后面的编辑器文字和终端。 |

→ 这台机器上做透明桌宠**必须用 Compatibility 渲染器**（或去 NVIDIA 控制面板把 Vulkan present method 改成
Native —— 那是机器级设置，会影响别的程序）。
（当时两张对照截图未随仓库发布：原图是整屏截图，含作者的个人桌面信息。
实验工程本身在 `agent-test/spike-godot/`，换渲染器重跑就能自己看到。）

### 全局按键：实测不合格

同一工程里 `_input()` 记录所有按键。日志（`run-vulkan.log`）：

```
3.27 KEY_RECEIVED E (total=1)  focused=true
7.23 ALIVE fps=144 keys=5 focused=false      ← 从这里开始失去焦点
18.29 ALIVE fps=143 keys=5 focused=false     ← 接下来 11 秒里 0 个按键事件
```

期间往**另一个窗口**里打了 7 下键，Godot 一个都没收到。
**Godot 拿不到非焦点的全局按键**，这是引擎输入模型决定的，不是配置问题。
只有两条出路：外挂一个采集器进程，或在引擎里加原生钩子。

其他已知缺口：托盘图标无内置 API；开机自启无 API；Windows 下点击穿透必须自己设
`WS_EX_LAYERED|WS_EX_TRANSPARENT`（内置 `mouse_passthrough_polygon` 在 Windows 上**不**穿透到别的应用）。

### 作者的 Godot 底子（这条最重）

作者本机那份 Godot **不是 stock 4.7.2**，而是一个内部自用的 fork（公司项目：仓库地址、版本号、
模块名都不便公开），`develop` 分支、带若干非官方模块、有自编译的编辑器产物。

含义：全局钩子 / 点击穿透 / 托盘都可以作为**原生模块**加进 fork（引擎源码就在手边，
`platform/windows/display_server_windows.cpp` 之类想读就读），自定义导出模板还能压体积。
这条把 Godot 从「系统集成最麻烦」变成「系统集成自己就能改」。

**不影响本仓库的可复现性**：宠物跑的是 **stock Godot 4.7.2（Steam 版）**，
本节的实测结论都在 stock 上做的；fork 只在「必要时能改引擎」这条上有分量。

## 数据模型

SQLite，单文件 `keycount.db`。

```sql
CREATE TABLE key_hourly (
  day   TEXT    NOT NULL,   -- 'YYYY-MM-DD' 本地时区
  hour  INTEGER NOT NULL,   -- 0..23
  key   TEXT    NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, hour, key)
) WITHOUT ROWID;

CREATE TABLE run_log (          -- 用来发现「昨天其实没在跑」
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT NOT NULL,
  ended_at   TEXT,              -- NULL = 那次没正常结束（被强杀/断电）
  version    TEXT NOT NULL,
  note       TEXT
);
```

> 比早期草案多了一个 `id`：`end_run` 要能定位「当前那次」才能回填 `ended_at`。
> `ended_at` 为空不是脏数据，它是**刻意的信号** —— 命令行报表靠它把「那天没敲键盘」
> 和「那天没在跑」区分开。只靠计数是分不出这两件事的。

**只存计数。不存按键顺序、不存字符、不存窗口标题。** 一旦存了有序按键流，就等于存了你的密码。

键名归一化：字母数字按基准键位记小写（`Shift+A` 记 `a`，不分裂成两行）；
命名键 `enter` `space` `tab` `backspace` `esc` `delete` `up/down/left/right`；
修饰键 `shift` `ctrl` `alt` `win`（左右不区分）；其余 `<scancode:0xXX>`。

## collector ↔ pet 的 IPC 契约

宠物不该自己去读数据库（那会把存储格式焊死在图形进程里）。collector 每秒推一帧状态：

```json
{ "ts": 1790582775,
  "today_total": 8431,
  "kpm": 213,              // 最近 30 秒每分钟击键数
  "kpm_peak": 480,
  "idle_sec": 12,          // 距上一次按键多少秒
  "top_keys": [["space",1204],["a",788]],
  "collector_ok": true }
```

传输用 Windows 命名管道（`\\.\pipe\keycount`），只监听本机。collector 挂了的话 pet 必须
能看出来（`collector_ok:false`）并表现出「茫然」状态，**不许假装数据还在更新**。

## 宠物状态机

由 `kpm` 和 `idle_sec` 驱动，这是「桌宠」与「一个会动的贴图」的区别：

| 状态 | 触发条件 | 表现 |
|---|---|---|
| `idle` | `idle_sec < 60` | 呼吸、偶尔眨眼 |
| `typing` | `kpm > 0` | 精神起来，动作频率随 `kpm` 线性加快 |
| `excited` | `kpm > 400` 持续 5 秒 | 兴奋动作 + 粒子 |
| `sleepy` | `idle_sec > 180` | 打瞌睡（音效可选） |
| `rest_remind` | 连续活跃 > 50 分钟 | 提醒休息，点它才消失 |
| `lost` | `collector_ok == false` | 茫然状态，明确表示数据断了 |

交互：左键拖动移动；单击弹出今日总数 + Top 10 键；右键出托盘菜单（看报表 / 暂停采集 / 退出）。
`rest_remind` 和托盘菜单是 v1，不在 v0。

## 拖动：不能用 `event.relative` 累加（实测 2026-09-30）

`pet/pet.gd` 原本是 `window_set_position(window_get_position() + event.relative)`。
**看起来完全正确，实测每帧只跟 ~30%，而且约一半的帧在往后跳** —— 手感就是「跟不上 + 来回闪」。

| 拖法（合成真实鼠标，按住左键连续拖） | 旧实现跟随比 | 旧实现反向跳 | 旧实现最大跟踪误差 |
|---|---|---|---|
| 1px / 1ms | 30% | — | **-281px**（线性累积） |
| 3px / 3ms | 28% | 45% 的帧，最大反向 21px | — |
| 10px / 10ms | 39% | 0% | — |
| 10px / 40ms（旧判据用的形态） | **100%** | 0% | 0px ← 所以旧判据抓不住 |

**原因（源码级）**：`platform/windows/display_server_windows.cpp` 里，`WM_MOUSEMOVE` 的
`GET_X_LPARAM(lParam)` 是**客户区坐标**，Godot 的 `relative` 就是「本次客户区坐标 − 上次客户区坐标」
（`mm->set_relative(mm->get_position() - Vector2(old_x, old_y))`）。而**我们正在移动自己所在的那个窗口**，
客户区坐标基准跟着平移。Godot 的补正（`window_set_position()` 末尾调 `_update_real_mouse_position()`，
用 `GetCursorPos` + `ScreenToClient` 回写 `old_x/old_y`）读的是**移动之后**的光标位置，
而消息队列里还排着**按移动前基准生成**的 `WM_MOUSEMOVE`；两者一撞，
算出的 `relative` ≈ 真实位移 − 上次窗口位移 ⇒ 变成 ~0 甚至反向。
跟随比随速度下降，还伴 **~170ms 的卡顿**（窗口不动，然后猛跳一下）。

**解法：用绝对坐标，不要 `relative`。** 按下时记 「抓取点」偏移，移动时直接把窗口摆到「光标 − 偏移」：

```gdscript
_drag_offset = DisplayServer.mouse_get_position() - DisplayServer.window_get_position()
DisplayServer.window_set_position(DisplayServer.mouse_get_position() - _drag_offset)
```

绝对目标与坐标基准无关：即使某条陈旧消息多触发一次移动，也只是把窗口摆到**同一个正确目标**上。
（`mouse_get_position()` 与 `window_get_position()` 都减同一个 `_get_screens_origin()`，相减口径一致，
多显示器也不会错。）

**改后实测（同参数）**：跟随比 100–102%，反向帧 0，最大跟踪误差 7–10px（≈ 一帧的位移），
最长更新间隔 171ms → 13.7ms。

**判据**：`powershell -File agent-test/drag-test.ps1`。它先把窗口摆到固定位置、检查光标真的落在
宠物圆心上（避免「根本没开始拖」被当成通过），然后**连续**拖 1px/1ms × 300 步，
断言 `|窗口位移 − 光标位移| ≤ 5px`，退出码非 0 即失败。
已反向验证过（一个不会红的判据等于没有）：退回旧实现时它打印 `73% ❌`，改回新实现 100% ✅。

## 导出（release）：已跑通，外加一个静默坑（实测 2026-10-09）

**结论：导出版能跑，五条关键性质都实测通过。**

| 项 | 实测结果 |
|---|---|
| 产物 | `dist/keycount.exe`（104MB 模板 + **12KB 内嵌 pck**）+ `keycount.windows.template_release.x86_64.dll`（同级） |
| 扩展加载 | `hook.start() -> true`；`set_no_activate -> true`、`ex_style : noactivate=1 toolwindow=1` |
| 透明 | ⚠️ **默认启动会变黑方块**（实测见下）：裸启动起 `Vulkan - Forward+`，四角像素挪窗前 82.5% 不同、挪前平均亮度 **0**（纯黑）；加 `override.cfg` 或 `--rendering-driver opengl3` 后：`OpenGL API 3.3 - Compatibility`，四角 **0%** 不同、亮度 42 ⇒ 透明正常 |
| **不抢焦点** | `fg2.ps1` → `hwndFocus` 是别的窗口；日志 `prev_foreground=0x11611F8 ≠ hwnd`、`第一帧 restore_prev_foreground -> true`、`focused=false`、`input_keys=0` ⇒ **启动器在导出版里同样必需且有效** |
| DB 路径 | 与开发版**同一个** `user://keycount.db`（日志：「库里已有 4041 下」，同一次运行涨到 4148） |
| 钩子 / 不翻倍 | 109 条 KEY 行 ↔ 总数 +107（≈1:1，不是 2:1） |
| 单实例 | 再起一个 → 进程数仍 1（第二个自己退） |

导出形状（`pet/export_presets.cfg` 已入库；`packaging/` 是随包分发的启动器与说明）：

```
dist/
  keycount.exe              ← 双击 = 像普通应用（启动那一下会抢焦点）
  keycount.windows.template_release.x86_64.dll
  start.cmd / start.ps1     ← 双击 / 自启：把键盘还给原来那个窗口
  README.txt                ← 隐私 / 杀软 / 用法
```

### 坑：release dll 旧了会「静默不加载」——一条报错都没有

实测：`template_release.dll`（编于 09-29 16:05）比 `gdext/src/kc_window.cpp`（09-29 22:47）、
`kc_module.cpp`（09-30 09:00）都旧 ⇒ 拿它做 release 导出后，导出版里
**`pet.gd` 直接解析失败（`Could not find type "KeyCountGuard"`），而引擎连一条
`Error loading extension` 都不打**（全量 stdout 15 行、`godot.log` 一致，零 error/warning）。

排查路线上值得记住的两点：

- **同一套布局下 debug 导出能加载、release 不能** ⇒ 一次就把范围缩到「模板 or dll」，重编 dll 即定位。
- 摆文件没用：三种清单位置（根 / `.godot/` / `godot/`）× 两种 dll 位置全试过 ——
  **清单读得到、dll 就在同级，仍然静默不加载**。真正能回答「加载了没」的判据是
  让导出版自己说（探针场景里 `ClassDB.class_exists("KeyCountGuard")`）。

**为什么会发生**：nook 的 `bin/kctest` 只编 `template_debug`，日常（编辑器跑宠物）也只用 debug 模板 +
debug dll ⇒ **release 这条链从来没被碰过**。所以 CI 必须 debug + release **两个 target 都编**。

### 三个附带的实测细节

- **`rendering_method` 读回来是 `forward_plus`**（工程里写的是 `gl_compatibility`），
  但截图证明透明正常 ⇒ 这个读回值有误导性（运行期被规范化）。**不影响发布**。
- 导出模板在这台机器上来自 **Steam 安装目录**的 `editor_data/export_templates/4.7.2.stable/`，
  不是 `%APPDATA%`。CI 得自己准备（官方 tpz 1.28GB，或用 Range 只取 windows 成员 ~100MB）。
- 导出目录里可以直接跑 `keycount.exe --headless --verbose`：导出版照样接受引擎命令行，
  是排查「扩展没加载」最快的手段。

### 日志口径（2026-10-09 改）

- 落点改 `user://run.log`（原来写 `res://run.log` = 工程/exe 旁边；装进 `Program Files` 时会静默写不出）。
- **1MB 上限 + 轮转**（保留 1 份 `run.log.1`）：不轮转时实测长到过 **80MB**。
  日志是**诊断**用的，不是数据——计数在 SQLite 库里，轮转永远不碰它。
- **逐键行只在 debug 构建里写**（`OS.is_debug_build()`）：发布版不留「带时间序的按键流水」，
  只写启动 / 落盘 / ALIVE 这些状态行。开发期判据（SKILL 里「9 条 KEY 行」）照旧。

**判据**：`pet/export_presets.cfg` + 导出命令；然后按上表逐条验 —— 扩展加载看 `user://run.log` 的
`hook.start() -> true`，不抢焦点看 `agent-test/fg2.ps1`，DB 看 `tools/keycount.py today`。

### 坑：导出版里工程设置的渲染器**不生效** ⇒ 黑方块（实测 2026-10-09）

先把事实摆全（全部实测，不是推测）：

| 实测项 | 结果 |
|---|---|
| `pet/project.godot` | `renderer/rendering_method="gl_compatibility"` ✅ |
| 导出包里 `project.binary` | **字节级确认含 `rendering_method` 且值就是 `gl_compatibility`**（不是 `.mobile` 变体）✅ |
| 裸启动导出版 | `Vulkan 1.3.289 - Forward+` + 四角像素挪窗前 82.5% 不同、平均亮度 **0** ⇒ **黑方块** ❌ |
| 运行时 `ProjectSettings.get_setting("rendering/renderer/rendering_method")` | **`forward_plus`**（不是包里的值）|
| 旁边放 `override.cfg`（同一个键）| `OpenGL API 3.3.0 - Compatibility` + 四角 0% 不同、亮度 42 ⇒ 透明 ✅ |
| 启动器传 `--rendering-driver opengl3` | 同上 ✅ |
| 导出时传 `--rendering-method gl_compatibility` | **仍然 Vulkan**（不管用）❌ |

结论：**包里的配置是对的，但导出版（embedded pck）启动时没采用它**（运行时看到的是默认值
`forward_plus`）。引擎内部确切原因未定位（`rendering_method` 在 `main.cpp` 里被读的位置很早，
而 `override.cfg` 这种**外部**文件能生效——两者区别就在这里）。

⇒ 发版时两条一起上（已写进 `packaging/`）：

1. 随包放 **`override.cfg`**（内容就一行 `renderer/rendering_method="gl_compatibility"`）——
   这是让「双击 exe」也正常的唯一办法；build.yml 里还断言了它必须在 dist/ 里。
2. 启动器 **`--rendering-driver opengl3`**（与开发期 `run-pet.ps1` 的做法一致）。

**为什么会一直没发现**：开发期一直用启动器（传了 driver），所以从来没碰到过；
而首次发布流程时我用**肉眼看截图**下了“透明正常”的结论 —— 后来用像素测量才推翻。

**判据**：`powershell -File agent-test/transparency-test.ps1 [-Proc <进程名>]`
（挪窗 + 四角像素对比；退出码 0=透明 / 1=黑方块 / 2=找不到窗口）。
这条**CI 断言不了**（要真实桌面），已写进 release 说明里的手验清单第 1 条。

## 版本管理（2026-10-09 定案）

### 三种「版本」分开走

| 类别 | 回答什么 | 载体 | 变化频率 |
|---|---|---|---|
| **发布版本** | 用户/依赖者看：`v0.1.20261009` | git tag（唯一事实源） | 每天 |
| **应用自报版本** | 「这些计数是哪个版本写的」（诊断） | `keycount/version` → 日志 + `run_log.version` | 每次发版 |
| **存储结构版本** | 数据能不能被这个程序安全读写 | `PRAGMA user_version` | 几个月一次 |

**为什么不能混**：发布号天天变、结构几个月才动、自报版本每次都要变但**不值得改代码**。
混在一起最坏的后果：结构悄悄变了而发布号没动 ⇒ **静默写坏用户的计数历史**（用户已经积累了几千下）。

### 方案 F：`vMAJOR.MINOR.YYYYMMDD`

- PATCH 用日期（`v0.1.20261009`）⇒ 发得再勤也不用想号，且**单调递增**（semver 合法，
  `0.1.20261010 > 0.1.20261009`）。不用 `0.1.0_1009` 这种写法：非 semver、排序歧义
  （`0.1.0_1010` 和 `0.1.1_1009` 谁新？）。
- `0.x` 阶段：破坏性变更（结构/键名/口径）进 MINOR（`0.2.*`）；预发布用 `-rc.N`。
- **push 到 main 的构建不是发布**：artifact 名用 `sha-<7位>`，不占版本号。

### 注入链（唯一事实源 = tag）

| 落到哪 | 谁写 | 用途 |
|---|---|---|
| `pet/project.godot` 的 `[keycount] version` | CI `sed`（只改工作区，不提交） | 开发/本地跑（实测读它 ✔） |
| `dist/override.cfg` 的 `[keycount] version` | CI | **导出版读它**（实测 ✔） |
| preset 的 `product_version` / `file_version` | CI | exe 属性页（实测 `ProductVersion=v0.1.20261009`、`FileVersion=0.1.1009.0`） |
| zip 名 / `README.txt` | CI | 用户一眼看到版本 |
| `run_log.version` | 宠物自己（读 `keycount/version`） | 数据溯源 |

### 三个实测的坑（都踩过）

1. **`project.godot` 的注释里不能出现等号**。实测 4.7.2 会报
   `Error parsing ...: Expected value, got 'ERROR' File might be corrupted`，**整个项目加载不了**
   （注释是否以 `#` 开头都一样）。判据：build 工作流里有一条直接跑一次 Godot 抳这个错。
   （我当时就是因为这个把宠物搞成“无日志、不开库”，查了好几轮。）
2. **`application/config/version` 读出来是空串**（`has_setting=true`，但值被当成内置默认）
   ⇒ 换自己的键 `keycount/version`。
3. **导出版读不到 pck 里的自定义键**（实测：注入后 exe 里有那个串，但运行时拿到默认值）
   ⇒ 版本号也走 `override.cfg`。**结论：导出版要用的配置放 exe 旁边最可靠**（与渲染器那次同一条结论）。

### 存储结构版本（与发布号解耦）

- 存在 SQLite 内建的 `PRAGMA user_version`（跟事务一起提交，无额外依赖）。
- `open()`：先读；**比程序新就拒绝打开**（“请升级程序”，不给旧结构写坏数据的机会）；
  否则在同**一个事务**里建表 + 写版本号。以后改结构就加 `if (found < N+1) { 迁移 }`。
- 断言在 `native/test_store.cpp`（现 52 条）：旧库自动升级且数据还在 / 库比程序新时拒绝打开
  且**不留半开状态**——最后这条当时真抓到一个 bug（`open()` 失败却没关连接）。
- 本机用户的真库已从 `user_version=0` 迁到 `1`：计数一条没少（5684 下 ✔）。

**判据**：`native/test_store.exe`（52 条断言）；`godot --headless --quit-after 10 --path pet`
的输出里不得有 `Error parsing`；发布时看 `user://run.log` 首行的版本号是否等于 tag。

## native/ 平台核心：已实现并验证

`native/kc_hook.h` / `kc_hook.cpp` / `test_hook.cpp` —— **不依赖 Godot 的纯 C++**（只用 Win32 + 
标准库）。三条接线路（独立 exe / GDExtension / 引擎模块）共用这一份，所以「选哪条接线」不阻塞核心。

### 验证结果（实测，2026-09-28）

```
test_hook.exe --selftest        →  25 通过，0 失败
test_hook.exe 12  （窗口无焦点）  →  按下 9 下，抬起 9 下，丢弃 0 条，不同键 9 个
                                     shift a b c space 1 backspace enter tab
```
对照：注入目标窗口同时收到文本 `Abc`。**钩子进程全程没有焦点，9 下全抓到。**

### 两个设计决定（都是被实测逼出来的）

**1. 键名以 vkCode 为主，扫描码只做兜底。**
第一版只按扫描码查表，实测发现 `SendKeys`/`SendInput` 造出来的合成事件 **scancode = 0x00**，
于是键名退化成一片 `sc00`。真实硬件按键的扫描码是正常的（`j → 0x24`），但**远控、KVM、
键位重映射工具同样可能不发扫描码** —— 只有 vk 可靠。vk 唯一不能区分的两处（主回车 vs 小键盘回车）
用 `extended` 标志补。

**2. 钩子跑在自己的线程 + 自己的消息循环上。**
低层钩子由「安装它的线程」派发，借用 Godot 主循环的话，Godot 一卡帧就会漏键。
钩子回调里只入队，绝不做日志/磁盘/回调用户代码 —— 超 `LowLevelHooksTimeout`（默认 300ms）
会被 Windows **静默摘钩**，而且不会报错。队列满时计数 `hook_dropped()`，不静默丢。

## GDExtension 接线：已跑通（2026-09-28）

| 产物 | 说明 |
|---|---|
| `gdext/` | 扩展源码（`SConstruct` + `src/kc_{hook_ext,window,store_ext,guard}.{h,cpp}` + `src/kc_module.cpp`），构建：`scons platform=windows target=template_debug api_version=4.7` |
| `gdext/bin/*.dll` | `keycount.windows.template_debug/release.x86_64.dll`，约 350-370KB |
| `pet/` | Godot 工程（`project.godot` / `main.tscn` / `pet.gd`），扩展装在 `pet/addons/keycount/` |
| `agent-test/run-pet.ps1` | **启动器 —— 必须用它启动**，原因见下 |

### 实测证据

```
hwnd=0x30D0170  prev_foreground=0xA03BA  foreground=0x30D0170
第一帧 restore_prev_foreground -> true
ALIVE ... focused=false focus_true_frames=0 input_keys=0 dropped=0   ← 全程如此
```

期间用 `GetGUIThreadInfo` 查过：`hwndFocus=0xA03BA`（浏览器）—— **键盘始终没落到宠物手里**，
而钩子照样抓到 9 下注入按键 + 真实硬件按键，`dropped=0`。
（原来这里有一张对照截图：圆浮在桌面上，后面编辑器文字清晰到圆的边缘。
因原图含个人桌面信息未随仓库发布；重跑 `agent-test\run-pet.ps1` 就能自己看。）

### 抢焦点这件事打了三仗（记下来，别再踩）

1. **`Window.FLAG_NO_FOCUS` 运行时 `set_flag` 无效** —— 窗口已经激活过了，补设不会把焦点还回去。
2. **工程设置 `display/window/size/no_focus=true` 也没用** —— 实测 `ex_style 之前 : noactivate=0`，
   Godot 建窗口时根本没带上 `WS_EX_NOACTIVATE`。
3. **在扩展里读「前置窗口」永远读到自己** —— Godot 在 GDExtension 初始化**之前**就创建并激活了主窗口，
   日志里 `prev_foreground == hwnd` 就是这个缘故。

**最终解法：**启动器在拉起宠物之前记下真实的前置 HWND，用环境变量 `KC_PREV_FOREGROUND` 传进去；
宠物启动后 2.5 秒内一旦发现自己握前台，就调 `SetForegroundWindow` 还回去
（此时是以「当前前台进程」的身份调用，Windows 才允许）。

### 另外两条实测到的坑

- **Vulkan 下透明窗口是黑方块**，必须 `renderer/rendering_method="gl_compatibility"`。
- **Godot 默认字体不含中文字形**，所以占位宠物上先用 ASCII 文字；
  要显示中文必须自带字体（Noto Sans SC 之类，做子集更小）。
- 直接跑工程不会加载 GDExtension：必须先过一次导入（`godot --headless --editor --quit --path pet`）
  生成 `.godot/extension_list.cfg`。

## 落盘：已跑通（2026-09-28）

底层是**真 SQLite**（3.53.4 amalgamation，编进扩展，见 `thirdparty/sqlite/PIN.txt`）。
不自己发明文件格式的理由：崩溃安全（WAL）、事务、以及「宠物没跑时外部工具也能查库」——
这三件事 SQLite 已经替我们测了十几年。

| 文件 | 职责 |
|---|---|
| `thirdparty/sqlite/` | SQLite amalgamation，版本固定记录在 PIN.txt |
| `native/kc_store.h/.cpp` | 存储层，**不依赖 Godot**（分层同 kc_hook） |
| `native/test_store.cpp` + `build_store.sh` | 独立验证：39 条断言，不需要 Godot 也不需要宠物在跑 |
| `gdext/` → `KeyCountStore` | 薄包装，把 kc_store 暴露给 GDScript |
| `tools/keycount.py` | 命令行报表，直读同一个库 |

### 职责划分（刻意这样切）

扩展只负责「可靠写进去 / 查得回来」。**什么算一天、哪个小时、多久 flush 一次，全在 GDScript**：
那些是业务口径，改口径不该重编扩展。

### 写入策略与代价

- 攒到 **10 秒**或 **200 下** 就落一次盘（一个事务写完一批）
- **落盘失败不清空待写数据** —— 留在内存里下次重试，并在日志里报错。静默丢数据比报错严重得多
- 库不可用时宠物变红并显示 `DB UNAVAILABLE`，**不假装一切正常**
- 查询接口一律返回 `{ok: bool, ...}`，让调用方能区分「真的是 0」与「查询失败」
- 代价：**被强杀/断电最多丢 10 秒的按键**。这是明写的取舍，也是为什么需要
  `run_log.ended_at IS NULL` 这个信号

### 实测验收

```
第一次运行  → 已落盘 8 个桶 / 已记录本次运行结束
第二次启动  → 2026-09-28 库里已有 40 下（15 种键）      ← 数字续上了，没归零
强杀后启动  → 注意：上一次运行没有正常结束（17:16:03），可能是被强杀或断电
命令行      → 总计 40 下 / 按小时分布 / Top 10 键带百分比
```

`test_store.exe` 里有两条刻意的不变量断言：
1. **表里永远不能出现内容类列** —— 逐列比对 `day/hour/key/count`，再反向断言列名里没有
   `text/seq/order/title/window/clip` 之类的词。一旦出现有序按键流，就等于存下了密码。
2. **用独立的 sqlite3 连接打开库** —— 证明它真的是标准 SQLite 文件，外部工具读得进。

## 命令接口

```
# 启动宠物（必须用启动器，见「抢焦点这件事打了三仗」）
powershell -File agent-test/run-pet.ps1

# 命令行报表（直读同一个库，宠物没跑也能用）
uv run --no-project python tools/keycount.py today
uv run --no-project python tools/keycount.py report 2026-09-27
uv run --no-project python tools/keycount.py week
uv run --no-project python tools/keycount.py runs   # 能看出有没有没正常结束的运行
```

库位置：`%APPDATA%\Godot\app_userdata\keycount pet\keycount.db`（Godot 的 `user://`）。
`tools/keycount.py` 可用 `--db` 或环境变量 `KC_DB` 指向别处。

## 分阶段

- ~~**v0** collector 跑通：钩子 → SQLite → 终端查询可用~~ ✅
- ~~**v1** pet 骨架：透明置顶窗口 + 占位几何体 + 状态机 + 拖动~~ ✅（落盘也已并入）
- **v2** 点击穿透（现在整个 380×380 方框挡鼠标）+ 托盘图标 + 开机自启 + 中文字体
- **v3** 换成真素材（精灵图或 Live2D）；点宠物弹出今日/本周报表
- **不做**：鼠标计数、窗口标题、按键回放、云同步、读取输入正文。
