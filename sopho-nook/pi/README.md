# sopho-nook/pi —— 本 nook 的 pi 侧政策（进 git）

这里放**跟项目走**的 pi 资源。数据（会话/凭据/信任）仍在 `../.agent/`，不进 git；这里只放政策。

## 目录

| 路径 | 作用 |
|---|---|
| `extensions/subagent/{index.ts,agents.ts}` | **subagent 工具**：把任务派给隔离子进程的专用 agent。原样取自 pi 自带示例 `examples/extensions/subagent/`。 |
| `agents/*.md` | subagent 的 agent 定义（scout / planner / reviewer / worker），带 `tools` frontmatter。**去掉了示例里写死的 `model:`**（见下）。 |
| `prompts/*.md` | 工作流 prompt 模板（`/implement`、`/scout-and-plan`、`/implement-and-review`）。 |

## 出处与授权

- 来源：`@earendil-works/pi-coding-agent` **0.87.1**，`examples/extensions/subagent/`。
- pi 的授权是 **MIT**；示例与 pi 同源。vendor 进来只为"不依赖 npm 全局目录的结构"。
- **本地唯一改动**：示例的 4 个 agent 写死了 Anthropic 模型（`claude-haiku-4-5` / `claude-sonnet-4-5`）。
  本机 provider 是 LiteLLM，写死的名字会 **provider 歧义 + 未认证**，子 agent 直接起不来（实测报
  `Model "claude-haiku-4-5" is ambiguous across providers`）。所以删掉 `model:`。
  按 pi 文档，**省略 `model` 时子 agent 继承派发会话的模型** —— 本 nook 就是 `litellm/deepseek-flash`。
  想让某个 agent 用别的模型，填 `provider/model` 全名。

## 接线（为什么需要软链）

pi 只从约定目录发现资源，而这些目录都在**数据目录**（`.agent/`，不进 git）下：

- 扩展：`bin/pi-local` 用 `--extension <nook>/pi/extensions/subagent` 显式加载（不必往 `.agent/extensions/` 里放）。
- agent 定义：**扩展自己只认 `{agentDir}/agents`**（`getAgentDir()` = `PI_CODING_AGENT_DIR` = `<nook>/.agent`）。
- prompt 模板：pi 的用户模板目录是 `{agentDir}/prompts`。

所以 `bin/pi-local`（以及 Windows 的 `pi-local.cmd`）会把这两个目录挂进 `.agent/`：

```
.agent/agents   -> ../pi/agents     # 给 subagent 扩展发现 agent
.agent/prompts  -> ../pi/prompts    # 给 pi 发现工作流模板
```

**建软链必须带 `MSYS=winsymlinks:nativestrict`** —— 否则 MSYS 的 `ln -s` 会静默拷成普通文件，
于是改 `pi/agents/*.md` 不生效（README 里 models.json 那条踩过同一个坑）。

## 用法（在 pi 会话里）

```
subagent(agent="scout",  task="找出 native/ 里处理键名的所有位置")
subagent(tasks=[{agent="scout",task="..."},{agent="reviewer",task="..."}])   # 并行，≤8
subagent(chain=[{agent="scout",task="..."},{agent="planner",task="基于 {previous} 出计划"}])
```

默认 `agentScope:"user"`，只从这里列的 agent 里选；要用仓库本地的 `.pi/agents` 才需要显式改 scope（本 nook 没开）。
