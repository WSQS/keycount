-- kc —— keycount 的工程内 nvim 配置（由 sopho-nook/bin/nvim-local 用 -u 加载）。
--
-- 分工：本模块放「四条通用能力 + 本项目的键位」；具体实现各自成模块
-- （float / pi / lazygit / run / help），因为它们要能被单独调用与单独验证。
local M = {}

local paths = require("kc.paths")

--- 保存当前缓冲。<leader>w 与「开 pi 之前先落盘」共用这一条代码路径 ——
--- pi 的 read 与外部工具读的都是**盘**，不是你的缓冲区，所以"改了没存就问 pi"
--- 是静默失效的（它答的是没有你那段之前的内容）。
function M.write_current()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if not vim.bo[buf].modified then return false end
  if vim.bo[buf].buftype ~= "" then return false end -- terminal/prompt/help 之类不写
  local ok = pcall(vim.cmd, "write")
  return ok
end

--- 进选择列表（「nook 进去」之后就是从这挑文件）
function M.pick()
  require("kc.picker").pick()
end

--- 推导出来的路径（:KcInfo；判据也拿它比对）
function M.info_lines()
  return {
    "nook    = " .. paths.nook(),
    "repo    = " .. paths.repo(),
    "native  = " .. paths.native(),
    "gdext   = " .. paths.gdext(),
    "pet     = " .. paths.pet(),
    "kctest  = " .. paths.kctest(),
    "stdpath(config) = " .. vim.fn.stdpath("config"),
    "stdpath(state)  = " .. vim.fn.stdpath("state"),
    "stdpath(run)    = " .. vim.fn.stdpath("run"),
  }
end

function M.setup(_opts)
  vim.opt.number = true
  vim.opt.signcolumn = "yes"
  vim.opt.expandtab = true
  vim.opt.shiftwidth = 2
  vim.opt.tabstop = 2
  vim.opt.mouse = "a"
  vim.opt.ignorecase = true
  vim.opt.smartcase = true
  vim.opt.termguicolors = true

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = "kc: " .. desc })
  end

  map("<leader>f", function() M.pick() end, "挑一个文件编辑（候选集与排除规则在 kc/picker.lua）")
  map("<leader>?", function() require("kc.help").show() end, "快捷键入口")
  map("<leader>a", function() require("kc.pi").open() end, "调出 pi 对话窗口")
  map("<leader>g", function() require("kc.lazygit").open() end, "lazygit 浮窗（cwd=仓库根）")
  map("<leader>t", function() require("kc.run").pick() end, "跑本项目的验证命令")
  map("<leader>w", function() M.write_current() end,
    "保存当前缓冲（别用 <C-s>：很多终端把它当流控，会把终端冻住）")
  map("<leader>r", function() require("kc.reload").reload() end,
    "重载 nook 自己的 Lua（改 nvim/lua/kc/** 后；改 init.lua 仍需重启）")
  map("<leader>s", function() vim.cmd.edit(vim.fn.fnameescape(paths.spec())) end, "打开 SPEC.md")
  map("<leader>m", function() vim.cmd.edit(vim.fn.fnameescape(paths.repo() .. "/README.md")) end,
    "打开 README.md")

  -- 外部改动自动重载：pi（或任何外部进程）写了盘，nvim 这边自己跟上。
  -- 幂等；且会用当前代码顶掉旧回调，所以 <leader>r 之后 watch 逻辑也是新的。
  require("kc.watch").start()

  -- C/C++ 的 LSP（clangd，零插件）。找不到 clangd 就静默不启（:KcLsp 可查）。
  require("kc.lsp").setup()

  -- 区域标记（human/ai）在编辑器里可见（软事：只显示、只提示，从不拦人）。
  require("kc.zone").setup()

  vim.api.nvim_create_user_command("KcPick", function() M.pick() end,
    { desc = "kc: 挑一个文件编辑" })
  vim.api.nvim_create_user_command("KcHelp", function() require("kc.help").show() end,
    { desc = "kc: 快捷键页（现算）" })
  vim.api.nvim_create_user_command("KcRun", function() require("kc.run").pick() end,
    { desc = "kc: 跑本项目的验证命令" })
  vim.api.nvim_create_user_command("KcPi", function() require("kc.pi").open() end,
    { desc = "kc: 在浮窗里开工程内 pi" })
  vim.api.nvim_create_user_command("KcReload", function() require("kc.reload").reload() end,
    { desc = "kc: 重载 nook 自己的 Lua" })
  vim.api.nvim_create_user_command("KcWatch", function()
    vim.notify(require("kc.watch").status(), vim.log.levels.INFO, { title = "kc watch" })
  end, { desc = "kc: 外部改动自动重载的现状" })
  vim.api.nvim_create_user_command("KcLsp", function()
    local lsp = require("kc.lsp")
    local clients = #vim.lsp.get_clients({ name = "clangd" })
    vim.notify(("kc lsp: clangd=%s\n已连接 client=%d"):format(lsp.clangd() or "(未找到)", clients),
      vim.log.levels.INFO, { title = "kc lsp" })
  end, { desc = "kc: clangd LSP 现状" })
  vim.api.nvim_create_user_command("KcInfo", function()
    vim.notify(table.concat(M.info_lines(), "\n"), vim.log.levels.INFO, { title = "kc info" })
  end, { desc = "kc: 打印推导出来的路径（调试 nook 自己用）" })
end

return M
