# agent-test —— 给 agent 用的运行/验证工具箱

这里不是"历史证据的仓库"，是**可重跑的动作**和**一次实验的原始复现件**。
它存在的理由来自 `SPEC.md` 那条硬规矩：

> 每条平台性结论都要有一行**能重跑**的命令、或一份日志/截图；证不了就写「未验」。

## ⚠️ 先看这一条

**`run-pet.ps1` 不是测试，是启动器 —— 启动宠物必须用它。**

少了它，宠物启动后会攥住你的键盘焦点（`hwndFocus` 落在宠物上），你随手打的字会掉进宠物里。
原因（`SPEC.md`「抢焦点这件事打了三仗」）：Godot 在 GDExtension 初始化**之前**就创建并激活了主窗口，
只有启动器能在拉起宠物前那一瞬记下"原来谁持有键盘"。**删目录前先想想这条。**

## 内容

| 件 | 作用 |
|---|---|
| `run-pet.ps1` | **启动器（运行时必需）**：记前置窗口 → 过导入 → 拉起宠物 |
| `fg.ps1` / `fg2.ps1` | 查"键盘到底在谁手上"。`fg2.ps1` 用 `GetGUIThreadInfo`，是**唯一可信**的那个（`GetForegroundWindow` / Godot `has_focus()` 都不可信） |
| `inject.ps1` / `inject2.ps1` / `inject3.ps1` | 弹一个自测窗口、`SendKeys` 往**它自己**里打字（不向任何别的窗口注入），验证全局抓键。`inject3.ps1` 把结果写到 `native/inject-received.txt` |
| `drag-test.ps1` | 模拟真实拖拽 |
| `screenshot.ps1` / `crop.ps1` / `crop2.ps1` | 截图与裁剪（SPEC 里的裁剪证据就是它们出的） |
| `probe.py` | 早期探针 |
| `cs-probe/` | 早前验证钩子用的 C# 探针（源码保留，`bin/`、`obj/` 不进 git） |
| `spike-godot/` | **Godot 透明窗口实测工程**（420×420、borderless、transparent）。回答了一个问题：Vulkan/Forward+ 下透明窗口是**纯黑方块**，OpenGL3/Compatibility 才正常。`crop-vulkan.png` / `crop-opengl3.png` 是 SPEC 引用的原始证据 |

## 怎么用（照抄）

```powershell
powershell -File agent-test/run-pet.ps1       # 启动宠物（必须）
powershell -File agent-test/fg2.ps1           # 判据：hwndFocus 不能是宠物
powershell -File agent-test/inject3.ps1       # 注入 9 下，再看 tools/keycount.py today 涨 9
```

`spike-godot/` 要重跑的话当成一个普通 Godot 工程打开（`--path agent-test/spike-godot`），
它和 `pet/` 完全解耦 —— 哪天透明又坏了，先用它区分"是 Godot/驱动的问题，还是 `pet/` 代码的问题"。

## 卫生

能再生成的产物都不入库（见根 `.gitignore`）：`spike-godot/full-*.png`、`run*.log`、`stdout*.txt`、
`cs-probe/{bin,obj}/`、`native/inject-received.txt`。只留**被引用**的那几张裁剪图。
