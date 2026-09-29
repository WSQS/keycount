-- kc/picker.lua —— 「nook 进去」之后的选择列表：挑这个项目里的一个文件来编辑。
--
-- 设计照 note 那份：**候选集、排除规则、过滤都是纯函数**（判据住在这里），浮窗只是界面、
-- 可以整个换掉。这样"列表里有什么"这件事能机械验，不用靠"打开看一眼"。
--
-- 两条从 note 那边抄来的硬修（都是真踩过的）：
--   · 选择器工作在**插入模式**，所以关掉它之后必须 `stopinsert`，
--     否则你打开的文件一进来就在插入模式（用户实测报过）。
--   · 插入点必须一直留在输入行上，否则 ↑↓ 会把插入点带进列表里，接着打字就打进列表了。
local M = {}

local paths = require("kc.paths")

--- 跨来源路径的统一键（界面与判据必须走同一条路径表示）
M.path_key = paths.key

--- 不进列表的路径（相对仓库根，前缀匹配）：**被 git 跟踪、但确实是 vendored 的第三方源码**。
--- （真正的生成物不靠这里排——它们在 .gitignore 里，见 M.items()）
M.exclude_prefix = {
  "thirdparty/sqlite/",   -- 9.5MB 的 amalgamation，跟踪着但没人会去编辑它
  "gdext/godot-cpp/",    -- 已在 .gitignore 里，这里留着当二保险
}

--- 二进制/归档：这类文件“能打开”但没有编辑意义，列出来只占位置。
---
--- 口径是**黑名单**（而非“哪些扩展名可编辑”的白名单）：白名单的毛病是以后新增的文件类型
--- （新语言、新配置、新脚本）会静默不出现，而这正是你找不到它的场合。
--- 所以默认“全都算”，只排掉那些确定不可编辑的。
M.binary_ext = {
  -- 编译产物
  dll = true, exe = true, lib = true, obj = true, exp = true, pdb = true,
  ilk = true, idb = true, so = true, a = true, o = true, class = true,
  -- 归档
  zip = true, ["7z"] = true, rar = true, gz = true, tar = true, tpz = true,
  aar = true, apk = true, whl = true, jar = true, xz = true, bz2 = true,
  -- 图片/媒体
  png = true, jpg = true, jpeg = true, gif = true, bmp = true, ico = true,
  webp = true, tga = true, mp3 = true, mp4 = true, ogg = true, wav = true,
  -- Live2D 模型（将来若真要编辑得用专门的工具，不是文本编辑器）
  moc3 = true, mtn = true,
}

--- 纯函数：这个相对路径该不该出现在列表里
function M.keep(rel)
  rel = M.path_key(rel)
  for _, p in ipairs(M.exclude_prefix) do
    if rel == p:sub(1, #p - 1) or vim.startswith(rel, p) then return false end
  end
  local name = rel:match("[^/]+$") or rel
  local ext = name:match("%.([^.]+)$")
  if ext and M.binary_ext[ext:lower()] then return false end
  return true
end

--- 纯函数：候选集 = 仓库里**被 git 跟踪的 + 未跟踪但没被忽略的**文件，返回相对仓库根的路径。
---
--- 为什么交给 git 而不是自己列一份“日志/产物”名单：那种名单一定会跟 .gitignore 漂开，
--- 而漂开的后果是列表里混进 `gdext/rebuild.log`、`pet/run.log` 这类运行产物
--- （实测：手写名单那版 82 条里有 18 条是产物或重复的 .import 侧车文件）。
--- .gitignore 已经是这个仓库里“什么是真文件、什么是生成物”的**唯一权威**，直接用它。
---
--- 代价（明写）：被忽略的文件（如 `pet/run.log`）不会出现在列表里。
--- 要看它就直接 `:e pet/run.log` 或 `bin/nvim-local pet/run.log` —— 那也不是“该编辑的源文件”。
function M.items()
  local root = M.path_key(paths.repo())
  local listed = vim.fn.systemlist({
    "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard",
  })
  if vim.v.shell_error ~= 0 then
    return {} -- git 不可用（不是仓库 / 没装 git）—— 交给调用方出声，不自作主张回退
  end
  local kept = {}
  for _, rel in ipairs(listed) do
    if rel ~= "" then
      rel = M.path_key(rel)
      if M.keep(rel) then kept[#kept + 1] = rel end
    end
  end
  table.sort(kept)
  return kept
end

--- 纯函数：过滤。只搜路径（不搜内容）。空查询 = 原样返回。
function M.filter(items, q)
  if not q or q == "" then
    return items
  end
  return vim.fn.matchfuzzy(items, q)
end

--- 纯函数：算出这一帧要写进缓冲的行、夹紧后的选中项、窗口起点 off、以及高亮行（0 基，-1 = 不高亮）。
--- 这就是「列表要跟着选中项滚」的判据所在：
---   · 第 1 行永远是输入行（插入点钉在这里，打字才不会打进列表）；
---   · 列表比窗口长时只写可见的那一段（第 off+1 条到 off+rows 条），选中项必定落在其中。
--- 为什么必须自己滚、不能靠 nvim 的视图：插入点被钉在第 1 行，nvim 为保证光标可见
--- 会把视图锁在顶部 —— 实测列表超过窗口高度后，高亮行会掉到窗口外（hl_visible=false）。
function M.layout(hits, q, sel, rows, off)
  q = q or ""
  rows = math.max(1, rows)
  local n = #hits
  if n == 0 then
    return { "> " .. q, "    （无匹配）" }, 1, 0, -1
  end
  if sel < 1 then sel = 1 elseif sel > n then sel = n end
  off = math.max(0, off or 0)
  if sel <= off then
    off = sel - 1
  elseif sel > off + rows then
    off = sel - rows
  end
  local maxoff = math.max(0, n - rows)
  if off > maxoff then off = maxoff end
  local lines = { "> " .. q }
  local last = math.min(n, off + rows)
  for i = off + 1, last do
    lines[#lines + 1] = (i == sel and "  ▸ " or "    ") .. hits[i]
  end
  -- 高亮行（0 基）：缓冲第 1 行是输入行，所以第 sel 条落在 sel-off+1 行、0 基即 sel-off
  return lines, sel, off, sel - off
end

--- 把 :edit 的报错翻译成人话（纯函数，可单独测）。
--- 交换文件（E325）那一条来自 note 那边的实测：真实 TUI 里 nvim 会停下来问，
--- 而脚本答不了，于是只抛一串 E5108/E325；headless 反而只给 W325 直接放行。
function M.explain_open_error(shown, err)
  local msg = tostring(err)
  if msg:find("E325") or msg:find("ATTENTION") then
    return ("%s 已有交换文件（多半是上次异常退出留下的，或正被另一个 nvim 打开）。\n"
      .. "先关掉那一边；确认没有未保存内容后，删掉它的 .swp/.swo 再来。"):format(shown)
  end
  return ("%s：%s"):format(shown, msg)
end

--- 打开一个文件。返回是否真打开了。
function M.open_path(path)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if ok then return true end
  local shown = vim.fn.fnamemodify(path, ":.")
  local msg = M.explain_open_error(shown, err)
  vim.notify("kc: 打不开 " .. msg,
    (msg:find("交换文件") and vim.log.levels.WARN or vim.log.levels.ERROR))
  return false
end

--- 浮窗选择器。选中 ⇒ 普通 :edit 打开（没有"模式"）。观感无法 headless 验，见 README。
function M.pick()
  local root = M.path_key(paths.repo())
  local all = M.items()
  if #all == 0 then
    return vim.notify(
      "kc: 候选集是空的 —— 拿不到 git 的清单（不是仓库？没装 git？）。"
        .. "选择列表故意不自己扫描目录：这个仓库里“什么是真文件、什么是生成物”由 .gitignore 说话。",
      vim.log.levels.WARN)
  end
  local state = { q = "", sel = 1, hits = all, off = 0 }

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(110, math.max(60, vim.o.columns - 8))
  local height = math.min(20, math.max(8, #all + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = 2,
    col = 3,
    style = "minimal",
    border = "rounded",
    title = " 挑一个文件编辑 · 输入筛选 · ↑↓ 选 · <CR> 打开 · <Esc> 取消 ",
  })
  vim.wo[win].wrap = false
  local ns = vim.api.nvim_create_namespace("kc_picker")
  local rows = math.max(1, height - 1) -- 第 1 行是输入行，剩下的才是列表

  local function render()
    state.hits = M.filter(all, state.q)
    local lines, sel, off, hi = M.layout(state.hits, state.q, state.sel, rows, state.off)
    state.sel, state.off = sel, off
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if hi >= 0 then
      vim.api.nvim_buf_add_highlight(buf, ns, "Visual", hi, 0, -1)
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  -- 选择器是在插入模式里打字过滤的，所以关掉它之后必须把插入模式收回来，
  -- 否则选完文件那个页面一进来就在 insert。用 schedule：插入模式的映射回调返回后，
  -- nvim 会继续保持插入模式。
  local function leave_insert()
    vim.schedule(function()
      if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then vim.cmd("stopinsert") end
    end)
  end

  local function move(d)
    -- 夹紧交给 M.layout（它同时会算好窗口起点 off，让选中项留在可见段里）
    state.sel = state.sel + d
    render()
    -- 插入点必须留在输入行，否则方向键会把插入点带进列表
    vim.api.nvim_win_set_cursor(win, { 1, #state.q + 2 })
  end

  local function open_selected()
    local rel = state.hits[state.sel]
    close()
    if rel then M.open_path(root .. "/" .. rel) end
    leave_insert()
  end

  render()
  vim.cmd("startinsert!")
  vim.api.nvim_win_set_cursor(win, { 1, 2 })

  local o = { buffer = buf, silent = true }
  vim.keymap.set("i", "<CR>", open_selected, o)
  vim.keymap.set("i", "<Esc>", function() close(); leave_insert() end, o)
  for _, k in ipairs({ "<C-n>", "<C-j>", "<Down>" }) do
    vim.keymap.set("i", k, function() move(1) end, o)
  end
  for _, k in ipairs({ "<C-p>", "<C-k>", "<Up>" }) do
    vim.keymap.set("i", k, function() move(-1) end, o)
  end
  vim.keymap.set("n", "<CR>", open_selected, o)
  vim.keymap.set("n", "q", close, o)
  vim.keymap.set("n", "j", function() move(1) end, o)
  vim.keymap.set("n", "k", function() move(-1) end, o)
  vim.keymap.set("n", "<Down>", function() move(1) end, o)
  vim.keymap.set("n", "<Up>", function() move(-1) end, o)

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      local q = text:sub(3)
      if q ~= state.q then
        state.q = q
        state.sel = 1
        render()
        vim.api.nvim_win_set_cursor(win, { 1, #q + 2 })
      end
    end,
  })
  -- 光标驱动选中：任何把插入点带到列表行的动作（↑↓、被内建吃掉的 <C-j>/<C-n>、鼠标点）
  -- 都当成"选中那一行"，然后把插入点送回输入行。
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = function()
      local l = vim.api.nvim_win_get_cursor(win)[1]
      if l <= 1 then return end
      local n = #state.hits
      if n == 0 then return end
      -- 缓冲第 l 行 = 第 off+(l-1) 条候选（第 1 行是输入行）
      local i = math.max(1, math.min(state.off + (l - 1), n))
      if i ~= state.sel then
        state.sel = i
        render()
      end
      vim.api.nvim_win_set_cursor(win, { 1, #state.q + 2 })
    end,
  })
  vim.api.nvim_win_set_cursor(win, { 1, 2 })
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close })
end

return M
