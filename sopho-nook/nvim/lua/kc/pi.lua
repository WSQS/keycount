-- kc/pi.lua —— <leader>a：把工程内 pi 调进浮窗。
--
-- Esc 的分工（**不从 pi 手里拿走任何键**）：
--   打字中单 Esc   → 转发给 pi（pi 原生的 app.interrupt，即打断）
--   打字中 Esc Esc → 关闭浮窗
--   普通模式单 Esc → 关闭（那里 Esc 本来就空闲）
-- 真的结束 pi 会话仍走 pi 自己的 ctrl+c（两下）与 ctrl+d，窗口随进程退出自动关。
--
-- 代价（明写）：单按一次 Esc 最多要等 'timeoutlen'（默认 1000ms）才轮到它 ——
-- nvim 得先排除"你是不是要按第二下"。反过来，你紧接着按别的键时 nvim 会立刻
-- 判定不可能是 Esc Esc 并把 Esc 发出去，所以不会把迟到的 Esc 掉进你正在打的字里。
local M = {}

local float = require("kc.float")
local paths = require("kc.paths")

local function send_esc(job)
  if job and job > 0 then
    pcall(vim.api.nvim_chan_send, job, "\27")
  end
end

function M.open()
  return float.open({
    key = "pi",
    title = "pi · " .. vim.fs.basename(paths.repo()),
    argv = function() return { paths.pilocal() } end,
    cwd = paths.repo(),
    save_first = true, -- pi 的 read 读的是盘，不是你的缓冲区
    on_keys = function(buf, job)
      vim.keymap.set("t", "<Esc>", function() send_esc(job) end,
        { buffer = buf, desc = "kc: 单 Esc 转发给 pi（打断）" })
      vim.keymap.set("t", "<Esc><Esc>", function() float.hide("pi") end,
        { buffer = buf, desc = "kc: Esc Esc 关闭 pi 浮窗" })
      vim.keymap.set("n", "<Esc>", function() float.hide("pi") end,
        { buffer = buf, desc = "kc: 普通模式 Esc 关闭 pi 浮窗" })
    end,
  })
end

-- 留出来给判据：验"转发 0x1b 的通道"时不必真开一个 pi 会话
M._send_esc = send_esc

return M
