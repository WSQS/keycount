-- kc/help.lua —— <leader>?：**现算**的快捷键页。
--
-- 为什么不写一份硬编码清单：清单会跟真实键位漂移（note 那边的判据 ⑪ 专门盯这条），
-- 而现算的不会。取法：扫实际注册的映射，认那些 desc 以 "kc:" 开头的。
--
-- 代价（明写，故意的）：没写 desc 的映射不会出现在这里。这逼着每条映射都带上说明。
local M = {}

local PREFIX = "kc:"

local function collect()
  local rows, seen = {}, {}
  -- leader 本身就是空格，不换写法的话帮助页里会显示成裸 " ?"，读不出来
  local leader = tostring(vim.g.mapleader or " ")
  local function show_lhs(lhs)
    if leader ~= "" and vim.startswith(lhs, leader) then
      return "<leader>" .. lhs:sub(#leader + 1)
    end
    return lhs
  end
  local function add(mode, lhs, desc, where)
    local key = mode .. "\0" .. lhs .. "\0" .. desc
    if seen[key] then return end
    seen[key] = true
    rows[#rows + 1] = { mode = mode, lhs = show_lhs(lhs), desc = desc, where = where }
  end

  for _, mode in ipairs({ "n", "t", "v", "x" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      local d = tostring(m.desc or "")
      if d:sub(1, #PREFIX) == PREFIX then
        add(mode, m.lhs, d:sub(#PREFIX + 1), "全局")
      end
    end
  end

  -- buffer-local 的（浮窗内注册的那些）不在 nvim_get_keymap 里，单独扫
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      for _, mode in ipairs({ "n", "t" }) do
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
          local d = tostring(m.desc or "")
          if d:sub(1, #PREFIX) == PREFIX then
            add(mode, m.lhs, d:sub(#PREFIX + 1), "浮窗内")
          end
        end
      end
    end
  end

  table.sort(rows, function(a, b)
    if a.where ~= b.where then return a.where < b.where end
    return a.lhs < b.lhs
  end)
  return rows
end

function M.lines()
  local out = {
    "kc —— keycount 的工程内 nvim",
    "快捷键由实际注册的映射现算，不是硬编码清单（上面那张表会随代码自己变）",
    "",
  }
  for _, r in ipairs(collect()) do
    out[#out + 1] = string.format("  %-3s %-9s %-46s [%s]", r.mode, r.lhs, r.desc, r.where)
  end
  out[#out + 1] = ""
  out[#out + 1] = "q 或 Esc 关闭本页"
  return out
end

function M.show()
  local lines = M.lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local w = math.min(110, math.max(50, math.floor(vim.o.columns * 0.75)))
  local h = math.min(#lines + 1, math.max(8, math.floor(vim.o.lines * 0.75)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.max(0, math.floor((vim.o.lines - h) / 2)),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    style = "minimal",
    border = "rounded",
    title = " kc help ",
    title_pos = "center",
  })
  -- 这两条故意**不**用 "kc:" 前缀：否则它们会把自己也列进帮助页里
  local close = function() pcall(vim.api.nvim_win_close, win, true) end
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "关闭本页" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "关闭本页" })
  return win
end

return M
