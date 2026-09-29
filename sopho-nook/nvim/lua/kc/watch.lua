-- kc/watch.lua —— 外部改动自动重载缓冲区。
--
-- 场景：这个项目的文件**同时**由你和 pi 改。pi（或任何外部进程）写了盘，
-- nvim 里的缓冲区不会自己变；过去要手动 `:e!`。这个模块把这件事自动化。
--
-- 三件事，缺一不可（README 早写过它"是 note 那份里最难的一块"）：
--   1. **uv_fs_event**：盯「已打开文件所在目录」（Windows 下 libuv 用 ReadDirectoryChangesW）。
--   2. **去抖**：编辑器写盘常触发一串事件，逐个处理会把缓冲区抽来抽去。攒 150ms 再办。
--   3. **脏缓冲区优先**：缓冲区有未保存修改时**绝不覆盖**，只警告——覆盖了就是丢你的东西。
--
-- 状态放 `_G`（不是模块局部变量）：`<leader>r` 热更能把模块表整个换掉，
-- 而已经装上的 fs_event 句柄还活着。把回调/派发也存进 `_G`，新代码一 start 就顶替旧的，
-- 于是 watch.lua 本身也能靠 `<leader>r` 更新（这是 float.lua 那条教训的同一条）。
local M = {}

local uv = vim.uv or vim.loop

local DEBOUNCE_MS = 150

--- 纯函数：两个指纹（{mtime=..., size=...} 或 nil）是否有差异。
function M.changed(prev, now)
  if prev == nil or now == nil then
    return (prev == nil) ~= (now == nil)
  end
  return prev.mtime ~= now.mtime or prev.size ~= now.size
end

--- 纯函数：拿到「盘上现状 / 我们上次记的盘上指纹 / 缓冲区脏不脏」，决定该干什么。
---   "skip"     没变化（或本来就知道文件不在）
---   "gone"     盘上文件没了（被删/改名）
---   "conflict" 盘上变了，但缓冲区有未保存修改 → 不覆盖
---   "reload"   盘上变了且缓冲区干净 → 读盘
--- 这个函数是判据所在：三种边界都能单独构造出来验。
function M.decide(on_disk, remembered, modified)
  if on_disk == nil and remembered == nil then return "skip" end
  if on_disk == nil then return "gone" end
  if not M.changed(remembered, on_disk) then return "skip" end
  if modified then return "conflict" end
  return "reload"
end

local function basename(p)
  return (tostring(p):match("[^/\\]+$")) or tostring(p)
end

local function same_dir(a, b)
  if not a or not b then return false end
  return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower()
end

--- 盘上指纹：mtime 折成一个整数（纳秒），加 size。文件不存在 → nil
local function finger(path)
  if not path or path == "" then return nil end
  local st = uv.fs_stat(path)
  if not st then return nil end
  local m = st.mtime or {}
  return { mtime = tonumber(m.sec or 0) * 1000000000 + tonumber(m.nsec or 0), size = tonumber(st.size or -1) }
end

local function st()
  if type(_G.kc_watch) ~= "table" then
    _G.kc_watch = {
      dirs = {},       -- dir -> fs_event 句柄
      known = {},      -- buf -> 上次记录的盘上指纹
      pending = {},    -- buf -> true（去抖期间的待办）
      started = false,
    }
  end
  local s = _G.kc_watch
  s.dirs = s.dirs or {}
  s.known = s.known or {}
  s.pending = s.pending or {}
  return s
end

--- 加进待办并（重）起去抖定时器。回调里查 `_G`，所以热更后用的是新代码。
local function schedule(buf)
  local s = st()
  s.pending[buf] = true
  if not s.timer then s.timer = uv.new_timer() end
  s.timer:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      local f = st().flush
      if f then f() end
    end)
  end)
end

--- 处理一个缓冲区：按纯函数的判决动手
local function check(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].buftype ~= "" then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then return end
  local s = st()
  local now = finger(path)
  local dec = M.decide(now, s.known[buf], vim.bo[buf].modified)
  if dec == "skip" then return end
  local shown = vim.fn.fnamemodify(path, ":.")
  if dec == "gone" then
    s.known[buf] = nil
    vim.notify("kc: " .. shown .. " 在盘上不见了（被删/改名？）——缓冲区保留，没有动它。",
      vim.log.levels.WARN)
    return
  end
  if dec == "conflict" then
    -- 记下盘上指纹：既避免对同一批事件反复告警，又不碰你的缓冲区。
    s.known[buf] = now
    vim.notify("kc: " .. shown .. " 在盘上变了，但你的缓冲区有未保存修改——**没有覆盖**它。\n"
      .. "（想放弃本地改动读盘： `:e!`；想保留本地改动：先 `:w`）", vim.log.levels.WARN)
    return
  end
  -- reload：干净缓冲区，读盘。保存/恢复各窗口的视图（光标与 topline）。
  local views = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview)
  end
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("edit!") end)
  if not ok then
    -- 不动 known：下次事件会再试；失败要出声，不假装重载了
    vim.notify("kc: 重载 " .. shown .. " 失败：" .. tostring(err), vim.log.levels.ERROR)
    return
  end
  for w, v in pairs(views) do
    if vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function() vim.fn.winrestview(v) end)
    end
  end
  s.known[buf] = finger(path)
  vim.notify("kc: 已重载 " .. shown .. "（外部改动）", vim.log.levels.INFO)
end

--- 目录事件：找出这个目录下、文件名对得上的缓冲区，排进去抖队列
local function on_event(dir, filename)
  local base = filename and tostring(filename):lower() or nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local p = vim.api.nvim_buf_get_name(buf)
      if p ~= "" and same_dir(vim.fs.dirname(p), dir) then
        if base == nil or basename(p):lower() == base then
          schedule(buf)
        end
      end
    end
  end
end

--- 去抖到点：把待办逐个交给当前 dispatch
local function flush()
  local s = st()
  local pend = s.pending
  s.pending = {}
  local d = s.dispatch
  if not d then return end
  for buf in pairs(pend) do
    if vim.api.nvim_buf_is_valid(buf) then d(buf) end
  end
end

local function watch_dir(dir)
  local s = st()
  if s.dirs[dir] then return end
  local h = uv.new_fs_event()
  if not h then return end
  local ok = h:start(dir, {}, function(err, filename)
    if err then return end
    -- fs_event 回调跑在 **fast event context** 里，不能直接调 nvim API（实测 E5560）。
    -- 丢回主循环再处理。
    vim.schedule(function()
      local e = st().on_event
      if e then e(dir, filename) end
    end)
  end)
  if not ok then
    h:close()
    return
  end
  s.dirs[dir] = h
end

local function ensure(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].buftype ~= "" then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then return end
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then watch_dir(dir) end
  local s = st()
  if s.known[buf] == nil then s.known[buf] = finger(path) end
end

--- 开。可重复调用（幂等）；也会用当前代码顶替旧的回调，所以 `<leader>r` 之后 watch 逻辑是新的。
function M.start()
  local s = st()
  s.on_event = on_event
  s.flush = flush
  s.dispatch = check
  s.started = true

  local grp = vim.api.nvim_create_augroup("kc_watch", { clear = true })
  -- 读盘/写盘后刷新指纹：写盘要刷新，否则我们自己的写会触发一次"外部改动"
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
    group = grp,
    callback = function(a)
      if vim.api.nvim_buf_is_valid(a.buf) then
        st().known[a.buf] = finger(vim.api.nvim_buf_get_name(a.buf))
        ensure(a.buf)
      end
    end,
  })
  -- 进任何缓冲区都确保它在被盯（新开的文件目录可能还没盯上）
  vim.api.nvim_create_autocmd("BufEnter", {
    group = grp,
    callback = function(a) ensure(a.buf) end,
  })
  -- 缓冲区没了就把状态清掉，别让 buf 号复用指到旧指纹
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = grp,
    callback = function(a)
      local s2 = st()
      s2.known[a.buf] = nil
      s2.pending[a.buf] = nil
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then ensure(buf) end
  end
end

--- 关。停掉 watcher 与定时器（判据/收尾用）。
function M.stop()
  local s = st()
  for dir, h in pairs(s.dirs) do
    pcall(function() h:stop() end)
    pcall(function() h:close() end)
    s.dirs[dir] = nil
  end
  if s.timer then
    pcall(function() s.timer:stop() end)
    pcall(function() s.timer:close() end)
    s.timer = nil
  end
  local ok, grp = pcall(vim.api.nvim_get_autocmds, { group = "kc_watch" })
  if ok then pcall(vim.api.nvim_del_augroup_by_name, "kc_watch") end
  s.pending = {}
  s.started = false
end

--- 现状（`:KcWatch` 打印用）
function M.status()
  local s = st()
  local dirs = 0
  for _ in pairs(s.dirs) do dirs = dirs + 1 end
  return ("watch: started=%s 目录=%d 待办=%d"):format(tostring(s.started), dirs, vim.tbl_count(s.pending))
end

return M
