# keycount 的 sopho-nook —— 这个仓库自己的一小角（目录 sopho-nook/）

```sh
sopho-nook/bin/nook                       # 「nook 进去」：无参数进选择列表，进去之后所有事都在 nvim 里做
sopho-nook/bin/nvim-local <文件>          # 直接打开某个文件（配置/状态/缓存全在 sopho-nook/.nvim/xdg）
sopho-nook/bin/pi-local                   # AI 侧：本项目的 pi（数据在 sopho-nook/.agent，"情况"在 sopho-nook/agents/skills）
sopho-nook/bin/kctest                     # 这个仓库真正的验证（native 自检 + 扩展编译 + 数据链路）
sopho-nook/bin/check-isolation --scope nvim -- <命令>  # 判据：证明它没写到工程外
```

**核心用法是“nook 进去”，不是“打开某个文件”。** 进 nvim 之后开文件用 `<leader>f`（同一个选择列表）、
跑验证用 `<leader>t`、问 pi 用 `<leader>a`、提交用 `<leader>g` —— 不必为了开另一个文件回到终端。

- **改动只落这一个文件夹**：仓库根不会多出 `bin/`、`.pi/`、`.nvim/`、`.agents/`，已有文件一个都不改
  （忽略规则在 `sopho-nook/.gitignore`，行尾规则在 `sopho-nook/.gitattributes`，都只作用于本目录）。
- 政策进 git：`bin/`、`nvim/`、`agents/`、`tools/`、`README.md`；
  数据不进 git：`.agent/`、`.nvim/xdg/`。
- Windows 侧：`bin\nvim-local.cmd`、`bin\pi-local.cmd`、`bin\kctest.cmd`（同一套设计，只是写法不同）。
- **model / provider 从哪来**：`bin/pi-local` 把 `PI_CODING_AGENT_DIR` 指到 `.agent/`，所以 pi 读的是
  `sopho-nook/.agent/models.json` + `settings.json`。前者是**指向全局 `~/.pi/agent/models.json` 的软链**
  （所以 profile 换了模型会自动跟过来），后者是本 nook 自己的一份拷贝。
  ⚠️ **建那个软链必须带 `MSYS=winsymlinks:nativestrict`** —— 否则 MSYS 的 `ln -s` 会静默拷一份普通文件
  （实测踩过；判据 ⑩ 盯这条）。
  ```sh
  MSYS=winsymlinks:nativestrict ln -sf /c/Users/<你>/.pi/agent/models.json "sopho-nook/.agent/models.json"
  ```
- **代价**：本项目技能（`agents/skills/**`）靠 `--skill` 显式加载 ⇒ 只有经 `bin/pi-local` 启动的会话才带上它；
  全局 `~/.agents/skills` 里的技能不受影响。

## 三条不变量

**轻量**（无框架、无常驻、通用件很小）· **可自定义**（规则由这个仓库自己定，写在 `agents/skills/` 与
`nvim/lua/kc/` 里）· **隔离**（数据与配置全在文件夹内，不碰全局，且有 `check-isolation` 为证）。

**明确不做**：工作台式 UI / 数据库 / hunk 接受 —— 这个 nook 只解决"在这个仓库里有一把顺手的编辑器和
一个知道本项目规矩的 pi"。

## 功能（每条都带"怎么验"）

| # | 功能 | 怎么验（照抄即可） | 状态 |
|---|---|---|---|
| 1 | **项目内 nvim**：init 与五个 XDG 目录全在 `sopho-nook/` 内 | `bin/check-isolation --scope nvim -- bin/nvim-local --headless +q` → 要 PASS；`bin/nvim-local --headless -c 'lua for _,k in ipairs({"config","data","state","cache","run"}) do io.write(k.."="..vim.fn.stdpath(k).."\n") end' +q` → 五条都要落在 nook 里 | 已验（本机 · Windows 11 · nvim v0.12.1；Windows 分支首次判据 ~3 秒（2026-09-29 裁 scope 后；之前是 60s+，因为宽名单里有两个 npm 树）） |
| 2 | **项目内 pi**：配置/会话/凭据落在 `.agent/` | `bin/check-isolation --scope pi -- bin/pi-local --version` → 要 PASS | 已验 |
| 3 | **本项目技能跟项目走**：`agents/skills/**` 由 `bin/pi-local` 用 `--skill` 显式加载 | 判据 ⑪（含"不加 `--skill` 就没有"的对照） | 已验 |
| 4 | **判据自证**：`check-isolation` 按平台**和 `--scope`（nvim/pi/all）**选快照集，并有**取景框**（`<nook>` 旁边不得出现同前缀兄弟项） | `bin/check-isolation --scope <nvim|pi|all> -- <任意命令>`；`--print-targets` 打印该 scope 扫哪些目录；Windows 侧**只能用 Git Bash 跑** | 已验（判据 ㉙） |
| 5 | **帮助页现算**：`<leader>?` 的清单从实际注册的映射算出来，不落一份硬编码 | 判据 ⑤（临时加一条映射必须立刻出现；没有 `kc:` 前缀的必须不出现） | 已验 |
| 6 | **路径只推导一处**：`kc/paths.lua`，其余模块一律 `require` 它 | 判据 ⑥（`:KcInfo` 对上 shell 推出来的） | 已验 |
| 7 | **`<leader>a` 的 pi 浮窗**：工程内 pi、Esc 单按转发/双按关闭 | 打开后按 `<Esc><Esc>` 关闭、`<Esc>` 打断；ESC 转发通道见 `kc/pi.lua` 的 `_send_esc` | **只验了"通道能送 0x1b"，真终端里没人看过**（同 note 那份的已知未验） |
| 8 | **`<leader>t` 验证菜单**：把本项目真正的验证命令做进浮窗 | 判据 ⑬（`bin/kctest` 与 `kc/run.lua` 是同一份清单） | 已验 |
| 9 | **数据不进 git** | `git -C sopho-nook check-ignore -v .agent .nvim/xdg` | 已验（判据 ⑨） |
| 10 | **行尾跨平台**：`.cmd` 锁 LF + 必须纯 ASCII | 判据 ⑦⑧ | 已验 |
| 11 | **改动只落一个文件夹** | 判据 ⑫（`sopho-nook/` **之外**不许出现未跟踪项） | 已验（判据 ⑫） |
| 12 | **「nook 进去」+ 文件选择列表**：`bin/nook` 无参数进列表，输入筛选、↑↓ 选、`<CR>` 打开；`<leader>f` 在 nvim 里开同一个列表 | 判据 ⑮–⑲（**候选集、排除规则、过滤全是纯函数**，所以能机械验）。候选集 = 仓库里被 git 跟踪的 + 未跟踪但没被忽略的，再排掉二进制与 vendored | 纯函数层已验；浮窗观感见“已知未验” |
| 13 | **列表跟着选中项滚**：候选比浮窗高时，↑↓ 移动会让列表一起滚，高亮不会掉出窗口 | 判据 ⑳（`layout()` 纯函数不变量）+ ㉑（headless 真开列表，下移 30 次后高亮仍在窗口内） | 已验 |
| 14 | **nook 自己的 Lua 热更**：`<leader>r` 重载 `nvim/lua/kc/**`，改完不必重启 nvim | 判据 ㉒（只清 `kc.*`、缓存真的清掉、键位重注册、**失败返回 false 不假装成功**） | 已验（改 `init.lua` 仍需重启，见下） |
| 15 | **外部改动自动重载**：pi（或任何外部进程）改了盘上的文件，nvim 缓冲区自己跟上 | 判据 ㉓（纯函数 `decide()` 的 5 种边界 + 真 `uv_fs_event`：干净自动重载、**脏缓冲区绝不覆盖**） | 已验（headless + 真文件）；真终端观感见“已知未验” |
| 16 | **subagent 工具**：把任务派给隔离子进程的专用 agent（scout / planner / reviewer / worker），支持单发 / 并行 / 链式 | 判据 ㉔（SDK `getActiveToolNames()` 真验注册）+ **端到端实跑**：父进程只开 `subagent`，`agent="scout"` 拿回`native/` 的文件清单（自己无读文件的工具，答案只能来自子进程） | 已验（单发）；并行/链式见“已知未验” |
| 17 | **C/C++ 的 LSP（clangd，零插件）**：补全 / 跳转定义 / hover，用 nvim 内建 LSP 客户端 | 判据 ㉕（纯函数候选解析 + **真起一个 clangd client**，确认 completion/definition 能力） | 已验（headless 起 client）；真终端按键见“已知未验” |
| 18 | **区域标记（human / ai）P1：只读检查器**：`.zonecheck.json` + `tools/zonecheck/`（仓库根）。标记成对、纯栈配对、可嵌套；`check` / `stats` / `judge` | 判据 ㉖（17 条单测 + 仓库 `check` 0 错且 covered>0 + **CLI `judge`：actor=ai 碰 human → deny/rc=1**） | P1 已验；P2（nvim 上色）/P3（门）见下 |
| 19 | **区域在编辑器里可见（P2）**：`:KcZoneStatus` / `:KcZoneCheck` / `:KcZoneJudge` / `:KcZoneRefresh` / `:KcZoneToggleLegacy`；区域上色 + sign + 行尾虚文本 | 判据 ㉗（`plan()` 的行映射/空区域/嵌套 + 真跑 `check`/`judge`/`refresh`） | 已验（headless）；真终端观感见“已知未验” |
| 20 | **C/C++ 保存时格式化**：`clang-format`（仓库根 `.clang-format`），`BufWritePre` 触发；`:KcFormat` 手动 | 判据 ㉘（候选解析 + 真跑 `:w` 格式化 + **标记不被弄坏**） | 已验；代价见“已知未验” |

## 这个项目在这个 nook 里加了什么

| 件 | 作用 |
|---|---|
| `bin/nook`（+ `.cmd`） | **「nook 进去」的入口**：无参数进选择列表（带参数就退 2，不静默忽略）；之后所有事都在 nvim 里做 |
| `nvim/lua/kc/picker.lua` | 文件选择列表。**候选集、排除规则、过滤是纯函数**（判据住在这里）；**列表跟着选中项滚**也是纯函数（`layout()`，判据 ⑳），浮窗只是界面，可以整个换掉。候选集**交给 git**：`ls-files --cached --others --exclude-standard` —— “什么是真文件、什么是生成物”由仓库既有的 `.gitignore` 说话，不在这里另堆一份日志名单（那种名单实测漂进了 18 条产物）；再排掉二进制/归档与 vendored（`thirdparty/sqlite/`） |
| `bin/kctest`（+ `.cmd`） | 这个仓库真正的验证：`test_store` 39 条断言、`test_hook --selftest` 25 条、`scons` 编译、命令行报表可读。证不了就 SKIP 并说明原因 |
| `nvim/lua/kc/run.lua` | `<leader>t` 的菜单：直接 argv（不经 shell 拼串），跑不了的**如实说原因**；每次跑先 kill 上一个 run 浮窗（复用会指向还活着的旧 job，等于骗人） |
| `nvim/lua/kc/float.lua` | 浮窗终端本体：pi / lazygit / 验证命令共用。登记表放 `_G`（不是 `vim.g`、不是模块局部变量）—— 热更后新代码才认得出旧进程 |
| `nvim/lua/kc/pi.lua` | `<leader>a` 调出工程内 pi；Esc 分工**不从 pi 手里拿走任何键** |
| `nvim/lua/kc/lazygit.lua` | `<leader>g`：cwd 固定在仓库根、开前先落盘、t 模式不注册任何键 |
| `nvim/lua/kc/help.lua` | `<leader>?` 现算的快捷键页 |
| `nvim/lua/kc/paths.lua` | nook / repo / 各子目录的路径**只在这里推导一次** |
| `nvim/lua/kc/reload.lua` | `<leader>r`：清掉 `package.loaded` 里的 `kc.*` 再 `setup()`，热更 nook 自己的 Lua。**失败如实报错、返回 false**；只认 `kc.*`，不碰内置与别的插件；**不重跑 `init.lua`**（改它仍要重启） |
| `nvim/lua/kc/watch.lua` | 外部改动自动重载：`uv_fs_event` 盯「已打开文件所在目录」→ 去抖 150ms → 纯函数 `decide()` 判决（干净=读盘；**脏缓冲=只警告不覆盖**；文件没了=保留缓冲）。状态放 `_G`，所以 `<leader>r` 之后 watch 逻辑也是新的 |
| `nvim/lua/kc/lsp.lua` | C/C++ 的 LSP：解析 clangd（PATH → VS 2022 → LLVM，且**实跑 `--version` 自检**才采用 —— VS 里 x64 与 ARM64 并存，ARM64 那份在 x64 上起不来）、`vim.lsp.config/enable` 零插件启动；编译参数走 `gdext/compile_commands.json` |
| `nvim/lua/kc/zone.lua` | 区域标记在编辑器里**可见**（软事：只上色/只提示，**从不拦人**）。`covered` 由检查器回答，自己不维护扩展名清单。纯函数 `plan()` 管“内容行 → extmark 行”的映射（判据 ㉗） |
| `nvim/lua/kc/format.lua` + **`.clang-format`（仓库根）** | C/C++ 保存时格式化（`BufWritePre`）。风格来自仓库根 `.clang-format`（**反推自现有代码**）。不用 clangd 的 formatting：`BufWritePre` 时 clangd 可能还没挂上。撞 VS 的 ARM64 `clang-format` 会在 spawn 时抛错 → 已 x64 优先 + 实跑自检 + **pcall**（格式化失败绝不阻断保存） |
| **`tools/zonecheck/`（仓库根，不是本 nook）** | 区域标记（human/ai）的只读检查器（stdlib Python，`uv run --no-project python`）。P1：标记解析 + `check`/`stats`/`judge`。目标 = **目的 A（保护）**：人标的 human 区，agent 机械地改不了（机制见判据 ㉖）。P2（nvim 上色）/P3（pi 门 + `pi-zoned`）待做 |
| `agents/ROLE.md` | **角色说明**（政策，进 git）。由 `bin/pi-local` 用 `--append-system-prompt` 指到它 |
| `agents/skills/keycount-verification/` | 改完东西后**怎么按层验证**（核心自检 → 扩展编译 → 集成 → 不抢焦点 → 落盘 → 单实例） |
| `tools/criteria.sh` | 这一份的判据 runner：**条数以它的汇总行为准**，不在文档里写死 |
| `pi/extensions/subagent/` | vendored 自 pi 0.87.1 示例的 **subagent 工具**（与 pi 同为 MIT）：派任务给隔离子进程的 agent。见 `pi/README.md` |
| `pi/agents/*.md`、`pi/prompts/*.md` | agent 定义（scout/planner/reviewer/worker）与工作流模板；`bin/pi-local` 用软链挂进 `.agent/{agents,prompts}`（扩展只认 `{agentDir}/agents`）。**已去掉写死的 Anthropic 模型**，改为继承派发会话的模型 |

## 怎么复跑全部判据

```sh
sopho-nook/tools/criteria.sh
# 汇总: PASS=<见运行输出> FAIL=0 SKIP=<见运行输出>
```

Windows 侧要注意：**只能用 Git Bash 跑**（`C:\Program Files\Git\bin\bash.exe`）。
用 WSL 跑会走 unix 分支、看的全是 WSL 的 `$HOME` ⇒ 恒 PASS。

## 常用

```sh
sopho-nook/bin/nook                     # 「nook 进去」：进选择列表，然后开文件/跑验证/问 pi/提交
sopho-nook/bin/nvim-local README.md     # 直接打开某个文件
sopho-nook/bin/kctest                   # 跑这个仓库的全部验证（终端侧）
sopho-nook/tools/criteria.sh            # 跑这个 nook 的全部判据
# 在 nook 的 nvim 里：
#   <leader>f   挑一个文件编辑（同一个选择列表）
#   <leader>?   快捷键页（现算）
#   <leader>t   跑验证命令（菜单）
#   <leader>a   pi 浮窗
#   <leader>g   lazygit
#   <leader>r   重载 nook 自己的 Lua（改 nvim/lua/kc/** 后）
#   subagent(...)  派子任务（scout/planner/reviewer/worker；注册见判据 ㉔）
#   :KcLsp        看 clangd 的路径与已连接的 client 数
# 给 clangd 用的编译数据库（不进 git；改过构建命令后重跑）：
#   cd gdext && scons platform=windows target=template_debug api_version=4.7 compiledb
#   C/C++ 键：gd=跳转定义  K=hover  grn=重命名  grr=引用  gra=代码动作  gO=文档符号  <C-x><C-o>=补全
# 区域标记检查（仓库根，只读）：
#   uv run --no-project python tools/zonecheck/zonecheck.py check
#   :KcZoneStatus / :KcZoneCheck / :KcZoneJudge / :KcZoneRefresh / :KcZoneToggleLegacy
#   :KcFormat     手动格式化当前 C/C++ 文件（保存时也会自动做）
#   :KcInfo     打印推导出来的路径（调试 nook 自己用）
```

## 已知未验 / 已知取舍（别当结论）

- **浮窗的外观没人真正看过**：`<leader>a` 的 pi 浮窗、`<leader>t` 的运行浮窗、`<leader>?` 的帮助页，
  目前只在 headless 下验过"键位已注册 / 纯函数正确 / 通道能送键"，**没有人在真终端里看过这几个窗口**。
  这条与 note 那份的已知未验是同一类，沿用它的提醒：`vim.fn.jobwait()` 会阻塞主循环、终端模拟不跑，
  用它"看"终端渲染只会拿到空 buffer（那边实测踩过）。
- **外部改动自动重载（watch）**：机制在 headless 下用**真文件 + 真 `uv_fs_event`** 验过（判据 ㉓），
  但"真终端里边打字边被 pi 改文件"的观感没人看过 —— 与上面那条同一类已知未验。
- **clangd LSP 只验到“client 起来了 + 能力在”**：判据 ㉕ 真起了一个 clangd client 并确认 completion/definition 可用；
  但**没人在真终端里按过补全（`<C-x><C-o>`）或跳转（`gd`）**。且补全质量取决于
  `gdext/compile_commands.json`（不进 git，要自己 `scons ... compiledb` 生成；没有它 clangd 仍会挂上，只是用回退参数）。
- **区域标记：P1 + P2 做了，P3 没做**：检查器（`judge` 会拒）与编辑器侧（上色 / `:KcZone*`）都在；
  但 **pi 侧的门（换掉 `write`/`edit`、fail-closed）未做** —— 所以**现在还没有任何东西真拦得住 agent**。
  另外**没有任何文件被标成 human**（全仓库 legacy）：机制能跑，但“保护”尚未生效。
- **`zone.lua` 的上色没人真看过**：判据 ㉗ 验的是 `plan()` 的行映射与真跑 check/judge/refresh，
  但**真终端里那几块底色 / sign / 行尾虚文本长什么样，没人看过**（与浮窗同类）。
  且 `:KcZoneCheck` 查的是**磁盘上已保存的版本**（`BufWritePost`），不是“保存前将要写的内容”。
- **C/C++ 保存时格式化会改内容**：`clang-format`（仓库根 `.clang-format`）在 `BufWritePre` 跑。
  已验：坏格式能被改对、标记不被弄坏、失败不阻断保存。**代价**：首次套用改过 6 个文件里的 ~73 行
  （**纯空白**）；续行风格与旧手写不同（旧的是“对齐括号再取 tab 停位”，clang-format 复现不了，
  见 `.clang-format` 里的注释）。且格式化**可能重排 human 区的空白** —— 那是人自己保存触发的工具行为，
  不是“agent 碰了 human”。
- **subagent 已验到“单发端到端”**：判据 ㉔ 验注册；另外实跑过一次（父进程只开 `subagent`，让它派 scout 去数 `native/*.cpp`）。
  **没验的**：并行（`tasks=[...]`）与链式（`chain=[...]`）两种模式；以及示例 agent 的 prompt 质量（那是上游的，没改）。
  复跑：`sopho-nook/bin/pi-local --no-session --no-context-files --tools subagent --print '用 subagent 派 agent="scout" 数 native/ 下的 .cpp 文件'`
- **`MSYS=winsymlinks:nativestrict` 那个坑**：不带它 `ln -s` 会静默拷成普通文件，
  于是"profile 换模型自动跟过来"这条静默失效。判据 ⑩ 抓的是"是不是软链"，
  但**抓不到"你在别处又用裸 ln -s 建了一个"**。
- **没做**（相对 note 那份少了一件，是有意的）：
  - 状态栏定制：note 那份在状态栏显示"助手/你"的字数比；本项目没有对应物，
    想过显示"今日已记录多少下"，但那要每次渲染查一次库或做缓存 —— 没验过的性能取舍不先塞进来。
- **`bin/kctest` 与 `<leader>t` 是两份清单**（一份 bash、一份 Lua），靠判据 ⑬ 盯着别漂。
  更好的是只有一份，但那要么让 nvim 依赖 Git Bash，要么让终端依赖 nvim —— 现在这样是有意的取舍。

## 用户定义的交互

> 这一节是**你的**，按 note 那份的规矩：助手不许改它。
> 下面是**助手按 keycount 的形状提的草稿**，等你确认或改掉（见会话里的 q-b466f9a0）。

- **一行命令“nook 进去”**：`sopho-nook/bin/nook`（Windows 侧 `sopho-nook\bin\nook.cmd`）—— 无参数，
  进去后是一个文件选择列表，输入名字检索、↑↓ 选、`<CR>` 打开；进去之后**所有事都在 nvim 里做**
  （开文件 `<leader>f`、跑验证 `<leader>t`、问 pi `<leader>a`、提交 `<leader>g`）。
  想直接开某个文件：`sopho-nook/bin/nvim-local <文件>`。
- `<leader>f`：挑一个文件编辑（同一个选择列表）
- `<leader>?`：快捷键入口，看这个项目里的快捷键（现算，不硬编码）
- `<leader>a`：调出一个 pi 对话窗口（工程内 pi，跑在浮窗里）
- `<leader>t`：跑这个项目真正的验证命令（菜单里挑；也可以直接在终端敲 `bin/kctest`）
- `<leader>w`：保存当前缓冲 —— 别用 `<C-s>`，很多终端把它当流控，会把终端冻住
- `<leader>r`：重载 nook 自己的 Lua —— 改完 `nvim/lua/kc/**` 按它，不必重启 nvim（改 `init.lua` 仍需重启）
- `<leader>g`：lazygit 浮窗（cwd 固定仓库根）
- `<leader>s` / `<leader>m`：打开 SPEC.md / README.md
