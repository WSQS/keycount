# zonecheck —— 区域标记（human / ai）的只读检查器

给 keycount 用的**最小版**（参考 arcsopho 的 `cpp_playground`，只保留 `check` / `stats` / `judge`）。
目的是 **A：保护**——你标成 `human` 的代码，agent 机械地改不了。**只读，从不改文件。**

## 标记语法

成对、独立成行；`prefix` 由扩展名决定（见 `.zonecheck.json` 的 `prefixByExt`，默认 `//`）：

```
// >>> zone:human      ← 开始（只写 human 或 ai）
    ...你的代码...
// <<<                ← 结束（不重复类型、没有 id）
```

- 配对**纯靠栈**（所以能嵌套：ai 区里夹一块 human）。
- **未标注 = `legacy`**（不受约束）。
- 标记行本身**不属于任何区域**。
- 结束标上写任何多余东西（`<<< zone:human`、`id=…`）都是 `bad-format`。

## 三个子命令

```bash
ZC="uv run --no-project python tools/zonecheck/zonecheck.py"
$ZC check                      # 扫描并报解析错误（退出码 1 = 有错）
$ZC stats --json               # 每文件计数 + 区域区间 + 未标注区间（编辑器上色用）
$ZC judge --path a.cpp --new proposed.cpp --actor ai --policy --json
```

`judge` 是门要用的那个：**基线 = `--path` 在磁盘上的现状**，**待判 = `--new`（或 stdin）**，
回 `allow` / `deny` + 一句人话理由（给人也给模型看）。退出码 `0` allow / `1` deny（**只在带 `--policy` 时**）。

判据（policy，默认值见 `.zonecheck.json`）：

| code | 触发 | 默认 |
|---|---|---|
| `human-touch` | `--actor ai` 且改动碰到 `human` 区 | error（拒） |
| `marker-edit` | `--actor ai` 且动了标记行 | error（拒） |
| `cross-zone` | 一次改动同时碰 human 与 ai | error |
| `unmarked-touch` | 碰到 `legacy`（未标注）行 | warn（不拒） |

## ⚠️ `exclude` 是安全面，不是消噪手段

**列进 `exclude`（或不在 `include`、或命中 `generated`）的路径 = 没有区域约束**，
`judge` 一律回 "未纳入区域检查范围" ⇒ `allow`，agent 可以在那里随便写。

两条纪律：
1. 往 `exclude` 加东西是**有意识的决定**。当前排除的是构建产物 / vendored / 数据目录 / `agent-test/`（那本来就归 agent）。
2. **判据目标不能落在 `exclude` 里**——否则端到端判据会**静默 PASS**（参考项目真踩过）。
   所以 `test_zonecheck.py` 全部在**临时根**上做，并且每条 judge 判据前面都有一次 `covered` **前置自检**。

## 判据

```bash
uv run --no-project python tools/zonecheck/test_zonecheck.py    # 17 条
```

也接进了 nook 的判据 runner（`sopho-nook/tools/criteria.sh` ㉖）：单测 + 仓库 `check` 0 错 +
一条 **CLI 级** `judge`（actor=ai 碰 human 必须 deny/rc=1）。

## 进度

- **P1（检查器）**：已做 —— `check` / `stats` / `judge`，判据 ㉖。
- **P2（nvim 侧）**：已做 —— `sopho-nook/nvim/lua/kc/zone.lua`（区域上色 / sign / 行尾虚文本 + `:KcZoneStatus`、
  `:KcZoneCheck`、`:KcZoneJudge`、`:KcZoneRefresh`、`:KcZoneToggleLegacy`），**只显示、只提示，从不拦人**；判据 ㉗。
- **P3（pi 侧的门）**：未做 —— 换掉内置 `write`/`edit`，走 `judge`，fail-closed。
  在你有第一块 human 区之前，做了也没意义。
- 目前**没有任何文件被标成 human**（`defaultZone=legacy`，全仓库都是 legacy）。
