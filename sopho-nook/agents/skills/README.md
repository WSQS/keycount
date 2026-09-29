# 这个项目自己的"情况"

`sopho-nook/bin/pi-local` 会用 `--skill <nook>/agents/skills` 显式加载这里的技能（pi 文档 `skills.md`：
`--skill <path>` 可重复）。

- 放：这个项目里"做某类事"的流程（怎么验一个改动、怎么处理平台坑、提交前该看什么）。
- 不放：工具实现（在 `sopho-nook/bin/` 与 `sopho-nook/nvim/lua/`）、数据（`.agent/`、`.nvim/xdg/`）。
  也不放**事实**——事实的住处是仓库根 `SPEC.md`，技能只写"怎么用它"。
- 每个技能一个**分组目录**：`agents/skills/<情况>/SKILL.md`。
- 代价（有意）：因为不肯在仓库根放 `.agents/`，所以**只有经 `sopho-nook/bin/pi-local` 启动的会话**
  能自动带上这些技能。若希望"在这个目录里跑任何 agent 都自动带上"，那就要在仓库根放一个
  `.agents/skills` 指针 —— 那是另一处改动，与"改动只落一个文件夹"冲突，所以默认不做。

## 现在的技能

| 目录 | 什么时候用 |
|---|---|
| `keycount-verification/` | 改完这个仓库里的任何东西、要声称"它能跑"之前 |
