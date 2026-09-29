-- kc/float.lua —— 浮窗终端：pi 与 lazygit、以及本项目的验证命令共用这一套。
--
-- 这里只做三件事：几何、起进程、**记住它**。
--
-- 「记住」特意放在 `_G`（既不是模块局部变量，也不是 vim.g）：
--   · 不能放模块局部变量：热更能把模块表整个换掉，而那个进程还活着；
--   · 不能放 vim.g：它读出来是**转换后的副本**（dict → 新表），对读回来的表做
--     索引赋值会丢 —— note 那份实测踩到过：open() 之后登记表仍是 {}，
--     于是热更再开一次就变成第二份进程（"同一份对话"就断了）。
-- `_G` 里是同一个真表，跨模块重载存活。
--
-- 顺序仍然是那条老坑：**先建 buffer → 放进浮窗成为当前 buffer → 再 termopen**。
-- termopen 用的是*当前* buffer，反了就会把主编辑窗口顶成终端。
local M = {}

local paths = require("kc.paths")

local function registry()
  if type(_G.kc_floats) ~= "table" then _G.kc_floats = {} end
  return _G.kc_floats
end

local function win_of(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then return w end
  end
  return nil
end

local function entry_alive(entry)
  local b = entry and entry.buf
  return b ~= nil and vim.api.nvim_buf_is_valid(b) and not vim.b[b].kc_float_dead
end

local function geometry()
  local w = math.min(150, math.max(60, math.floor(vim.o.columns * 0.88)))
  local h = math.min(45, math.max(10, math.floor(vim.o.lines * 0.88)))
  return {
    relative = "editor",
    width = w,
    height = h,
    row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
  }
end

local function float_config(entry)
  return vim.tbl_extend("force", geometry(), {
    style = "minimal",
    border = "rounded",
    title = " " .. tostring(entry.title or "kc") .. " ",
    title_pos = "center",
  })
end

--- 起一个浮窗终端。spec：
---   key          登记名（"pi" / "lazygit" / "kctest"）—— 也是"同一个进程"这条的钥匙
---   argv         命令行数组，或函数（开的那一刻才求值）
---   title        浮窗标题
---   cwd          工作目录（缺省仓库根）
---   env          额外环境
---   save_first   开之前先落盘（pi 与 git 读的都是盘）
---   on_keys(buf, job) 可选：给该 buffer 注册键位
function M.open(spec)
  if spec.save_first then
    local saved = require("kc").write_current()
    if saved then
      vim.notify("kc: 已保存当前缓冲，好让 " .. spec.key .. " 看到你现在的版本", vim.log.levels.INFO)
    end
  end

  local reg = registry()
  local entry = reg[spec.key]

  -- 已经弹着 → 切过去；收起过 → 原样弹回来（同一份对话 / 同一个挑选状态）
  local win = win_of(entry and entry.buf)
  if win then
    vim.api.nvim_set_current_win(win)
    if vim.bo[entry.buf].buftype == "terminal" then vim.cmd("startinsert") end
    return win
  end
  if entry_alive(entry) then
    win = vim.api.nvim_open_win(entry.buf, true, float_config(entry))
    if vim.bo[entry.buf].buftype == "terminal" then vim.cmd("startinsert") end
    return win
  end
  -- 进程已经死了：把旧 buffer 丢掉，重开
  if entry and entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
    pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
  end
  reg[spec.key] = nil

  local argv = type(spec.argv) == "function" and spec.argv() or spec.argv
  if type(argv) ~= "table" or not argv[1] or vim.fn.executable(argv[1]) ~= 1 then
    vim.notify("kc: 找不到可执行文件 " .. tostring(argv and argv[1]), vim.log.levels.ERROR)
    return nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local my = { buf = buf, title = spec.title }
  reg[spec.key] = my

  local w = vim.api.nvim_open_win(buf, true, float_config(my))
  local opts = { cwd = spec.cwd or paths.repo() }
  if spec.env then opts.env = spec.env end
  opts.on_exit = function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then vim.b[buf].kc_float_dead = true end
      local alive = win_of(buf)
      if alive and #vim.api.nvim_list_wins() > 1 then pcall(vim.api.nvim_win_close, alive, true) end
    end)
  end

  local job = vim.fn.termopen(argv, opts)
  if job <= 0 then
    reg[spec.key] = nil
    pcall(vim.api.nvim_win_close, w, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify("kc: 启动失败：" .. table.concat(argv, " "), vim.log.levels.ERROR)
    return nil
  end
  my.job = job

  -- hide（不是 wipe）：收起浮窗时进程与滚动记录都留着
  vim.bo[buf].bufhidden = "hide"
  if spec.on_keys then spec.on_keys(buf, job) end
  if vim.bo[buf].buftype == "terminal" then vim.cmd("startinsert") end
  return w
end

--- 收起浮窗（不杀进程，不丢状态）
function M.hide(key)
  local entry = registry()[key]
  local win = win_of(entry and entry.buf)
  if win then pcall(vim.api.nvim_win_close, win, false) end
end

--- 彻底丢掉一个浮窗（连进程与 buffer）。给"运行器"用：
--- 每次跑新命令都要一个干净的终端，不能复用上一次那个还活着的 job。
function M.kill(key)
  local reg = registry()
  local e = reg[key]
  if e and e.buf and vim.api.nvim_buf_is_valid(e.buf) then
    local w = win_of(e.buf)
    if w and #vim.api.nvim_list_wins() > 1 then pcall(vim.api.nvim_win_close, w, true) end
    pcall(vim.api.nvim_buf_delete, e.buf, { force = true })
  end
  reg[key] = nil
end

function M.is_open(key)
  local entry = registry()[key]
  return win_of(entry and entry.buf) ~= nil
end

--- 登记表里的那个 buffer（判据用）
function M.buf(key)
  local entry = registry()[key]
  if not entry or not entry.buf or not vim.api.nvim_buf_is_valid(entry.buf) then return nil end
  return entry.buf
end

--- 那个 job（判据用）
function M.job(key)
  local entry = registry()[key]
  return entry and entry.job or nil
end

-- 终端改了大小时，把每个还弹着的浮窗重算一次
vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("kc_float", { clear = true }),
  callback = function()
    for _, e in pairs(registry()) do
      local w = win_of(e.buf)
      if w then pcall(vim.api.nvim_win_set_config, w, geometry()) end
    end
  end,
})

return M
