-- kc/lazygit.lua —— <leader>g：浮窗里开 lazygit。
--
-- 三条与 note 那份一致的死规矩：
--   · cwd 固定在**仓库根**（不是当前文件所在目录，否则 status 少了半边）
--   · 开之前先落盘（git 读的也是盘）
--   · t 模式**不注册任何键** —— lazygit 自己吃键，在里面 `q` 退出
local M = {}

local float = require("kc.float")
local paths = require("kc.paths")

function M.open()
  return float.open({
    key = "lazygit",
    title = "lazygit · " .. vim.fs.basename(paths.repo()),
    argv = { "lazygit" },
    cwd = paths.repo(),
    save_first = true,
  })
end

return M
