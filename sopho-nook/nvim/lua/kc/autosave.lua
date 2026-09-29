-- kc/autosave.lua —— 切走一个缓冲区之前，先把改过的存盘。
--
-- 为什么需要：nvim 默认把改过的缓冲区留在内存里（hidden），**切文件不会写盘**。
-- 于是"在 A 里改了没存 → 切到 B"就留下一个只存在于内存的版本；更糟的是别的 nvim
-- 或工具打开同一个文件时会看到 swap，报 `W325: Ignoring swapfile from Nvim process N`。
--
-- 口径（明写，别当它做了更多）：
--   · 只在**真正切走**（`BufLeave`）时存；只存"有文件名、改过、可写"的普通文件缓冲区
--     （terminal / scratch / help / 只读 都不碰）。
--   · **退出时不存**：实测 `BufLeave` 在退出序列里不触发（`:qa!` 不会写盘），另外再加一道
--     `v:exiting` 守卫 —— 这样 `:q!` 仍是"丢弃"的意思。
--   · 存盘失败**出声**（ERROR + 文件名），不假装存了。
--   · ⚠️ 会顺带触发 `BufWritePre`，也就是**格式化的那一刻**（`kc/format.lua`）——
--     所以"切走一个 C/C++ 文件"会顺手格式化它。这是有意的连锁（保存就该格式化），
--     但你要知道它发生在这里。
local M = {}

M.enabled = true

--- 存这个缓冲区（如果该存）。返回是否真的写了盘。
function M.save(buf)
  if not M.enabled then return false end
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= "" then return false end      -- terminal / scratch / help / prompt
  if vim.api.nvim_buf_get_name(buf) == "" then return false end
  if not vim.bo[buf].modified then return false end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then return false end
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("write") end)
  if not ok then
    vim.notify("kc autosave: 保存失败（" .. vim.api.nvim_buf_get_name(buf) .. "）：" .. tostring(err),
      vim.log.levels.ERROR)
    return false
  end
  return true
end

--- 总装。可重复调用（热更）：augroup clear 会换掉旧回调。
function M.setup()
  local grp = vim.api.nvim_create_augroup("kc_autosave", { clear = true })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = grp,
    callback = function(a)
      if vim.v.exiting ~= vim.NIL then return end   -- 退出中：不存（保住 :q! 的语义）
      M.save(a.buf)
    end,
  })
  vim.api.nvim_create_user_command("KcAutoSave", function(o)
    local arg = vim.trim(o.args or "")
    if arg == "on" then
      M.enabled = true
    elseif arg == "off" then
      M.enabled = false
    elseif arg ~= "" and arg ~= "status" then
      return vim.notify("kc autosave: 用法 KcAutoSave [on|off|status]", vim.log.levels.WARN)
    end
    vim.notify("kc autosave: " .. (M.enabled and "on（切文件时保存）" or "off"),
      vim.log.levels.INFO)
  end, {
    nargs = "?",
    complete = function() return { "on", "off", "status" } end,
    desc = "kc: 切换文件时自动保存（开/关/查看）",
  })
end

return M
