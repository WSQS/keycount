-- kc/zone.lua —— 区域标记（human / ai）在编辑器里**可见**。
--
-- 这是"软事"：只上色、只提示，**从不阻止写入、从不改文件**。
-- 强制在 pi 侧的门（P3）里；编辑器里拦人只会碍事。
--
-- 数据来自 `tools/zonecheck/zonecheck.py stats --json`（显式给单个文件时会如实报 `covered`）。
-- `covered ~= true` 的文件既不画也不查（静默）——由工具回答"在不在区域纪律内"，
-- 不在这里自己维护扩展名清单（手写清单会与 .zonecheck.json 的 include 漂移）。
local M = {}

local paths = require("kc.paths")

local NS = vim.api.nvim_create_namespace("kc_zone")

M.config = {
  highlight_legacy = true,
  colors = {
    human = "#20402c", human_fg = "#7ee787",
    ai = "#1b3550", ai_fg = "#79c0ff",
    legacy = "#2a2a2a", legacy_fg = "#8b949e",
    virt = "#8b949e",
  },
}

local HL = { human = "KcZoneHuman", ai = "KcZoneAI", legacy = "KcZoneLegacy" }
local SIGN = { human = "H", ai = "A", legacy = "L" }

--- 纯函数：把一个 stats 条目（`{regions=[...], unmarked=[[a,b]]}`）变成要画的 extmark 规格。
--- 判据住在这里：内容行是 **1 基且闭区间**，extmark 的 `row` 是 0 基、`end_row` 也是 **0 基且 inclusive**
--- （`api.txt`：`end_row` "ending line of the mark, 0-based inclusive"），所以 `[a,b] → row=a-1, end_row=b-1`。
--- 空区域（b<a）不画。嵌套用 `priority` 定胜负（越内层越高），所以 human/ai 重叠时内层赢。
function M.plan(entry, opts)
  opts = opts or {}
  local out = {}
  local function push(zone, a, b, depth, no_virt)
    if not HL[zone] or b < a then return end
    local o = {
      line_hl_group = HL[zone],
      sign_text = SIGN[zone],
      sign_hl_group = HL[zone] .. "Sign",
      priority = 100 + (depth or 0),
    }
    if zone ~= "legacy" and not no_virt then
      o.virt_text = { { " " .. zone, "KcZoneVirt" } }
      o.virt_text_pos = "eol"
    end
    out[#out + 1] = { zone = zone, row0 = a - 1, end_row = b - 1, opts = o }
  end
  -- 整文件标记（stats 报的 base）：整份涂色、优先级最低（depth=-1 ⇒ 99），让配对区域盖住它。
  -- 不挂 virt_text：整份的"标签"只出现在第一行一次，反而容易误读；底色本身就是信号。
  if entry.base and entry.base ~= "legacy" and (opts.lines or 0) >= 1 then
    push(entry.base, 1, opts.lines, -1, true)
  end
  for _, r in ipairs(entry.regions or {}) do
    push(r.zone, r.begin or 1, r["end"] or 0, r.depth or 0)
  end
  if opts.highlight_legacy ~= false then
    for _, rng in ipairs(entry.unmarked or {}) do
      push("legacy", rng[1], rng[2], 0)
    end
  end
  return out
end

-- ---------------------------------------------------------------- 调用检查器

local function run(sub, extra)
  local root = paths.repo()
  local cmd = { "uv", "run", "--no-project", "python", "tools/zonecheck/zonecheck.py", sub }
  vim.list_extend(cmd, extra or {})
  return vim.system(cmd, { cwd = root, text = true }):wait()
end

local function run_async(sub, extra, cb)
  local root = paths.repo()
  local cmd = { "uv", "run", "--no-project", "python", "tools/zonecheck/zonecheck.py", sub }
  vim.list_extend(cmd, extra or {})
  vim.system(cmd, { cwd = root, text = true }, function(res)
    vim.schedule(function() cb(res) end)
  end)
end

local function decode(res)
  if not res or res.stdout == nil or res.stdout == "" then return nil end
  local ok, parsed = pcall(vim.json.decode, res.stdout)
  return ok and parsed or nil
end

--- 缓冲区对应的仓库相对路径（posix 分隔符）；不在仓库内 → nil
local function rel_of(path)
  local root = paths.repo()
  local abs = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
  if abs:sub(1, #root + 1) ~= root .. "/" then return nil end
  return abs:sub(#root + 2)
end

local function file_buf(buf)
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or vim.bo[buf].buftype ~= "" then return nil end
  return buf, path
end

--- 用 stats 的结果把区域画上（异步；`covered ~= true` 就不画）
function M.refresh(buf)
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.b[buf].kc_zone_marks = 0
  local b, path = file_buf(buf)
  if not b then return end
  run_async("stats", { "--json", path }, function(res)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local parsed = decode(res)
    if not parsed or type(parsed.files) ~= "table" then return end
    local fe = parsed.files[1]
    if not fe or fe.covered ~= true then return end
    local n = 0
    for _, s in ipairs(M.plan(fe, { highlight_legacy = M.config.highlight_legacy,
                                   lines = vim.api.nvim_buf_line_count(buf) })) do
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, NS, s.row0, 0,
        vim.tbl_extend("force", { end_row = s.end_row }, s.opts))
      if ok then n = n + 1 end
    end
    vim.b[buf].kc_zone_marks = n
    vim.b[buf].kc_zone_counts = fe.counts
    vim.b[buf].kc_zone_covered = true
  end)
end

--- 各区高亮/符号的开关（`:KcZoneToggleLegacy`）
function M.toggle_legacy()
  M.config.highlight_legacy = not M.config.highlight_legacy
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then M.refresh(buf) end
  end
  vim.notify("kc zone: legacy 行高亮 " .. (M.config.highlight_legacy and "开" or "关"), vim.log.levels.INFO)
end

--- 区域状态（`:KcZoneStatus`）：covered + 计数
function M.status(buf)
  local b, path = file_buf(buf)
  if not b then
    vim.notify("kc zone: 这个 buffer 没有文件名", vim.log.levels.WARN)
    return nil
  end
  local parsed = decode(run("stats", { "--json", path }))
  local fe = parsed and parsed.files and parsed.files[1] or nil
  if not fe then
    vim.notify("kc zone: 未纳入区域检查范围（不在 include，或命中 exclude/generated）",
      vim.log.levels.INFO, { title = "kc zone" })
    return nil
  end
  local c = fe.counts or {}
  vim.notify(("kc zone: covered=true  base=%s  human=%d ai=%d legacy=%d markers=%d regions=%d"):format(
    tostring(fe.base or "legacy"), c.human or 0, c.ai or 0, c.legacy or 0, c.markers or 0, #(fe.regions or {})),
    vim.log.levels.INFO, { title = "kc zone" })
  return fe
end

--- 检查当前文件（`:KcZoneCheck` / BufWritePost）。返回错误条数或 nil。
--- 查的是**磁盘上**的内容（BufWritePost 时就是刚保存的版本）。
function M.check(buf, opts)
  opts = opts or {}
  local b, path = file_buf(buf)
  if not b then return nil end
  local res = run("check", { path })
  local errors = {}
  for _, line in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    local f, lnum, code, msg = line:match("^(.-):(%d+): %[(.-)%] (.*)$")
    if f then
      errors[#errors + 1] = { filename = paths.repo() .. "/" .. f, lnum = tonumber(lnum), text = "[" .. code .. "] " .. msg }
    end
  end
  if #errors > 0 then
    vim.fn.setqflist({}, "r", { title = "kc zonecheck", items = errors })
    vim.notify(("kc zone: 标记有问题（%d 条），见 quickfix"):format(#errors), vim.log.levels.WARN)
  elseif not opts.quiet then
    vim.notify("kc zone: 标记没发现问题", vim.log.levels.INFO)
  end
  return #errors
end

--- 把当前 buffer 当成"AI 的建议"判一次（`:KcZoneJudge`，只判不写）。返回 judge 的结果表。
function M.judge_current(buf)
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local b, path = file_buf(buf)
  if not b then return nil end
  local rel = rel_of(path)
  if not rel then
    vim.notify("kc zone: 这个文件不在仓库内", vim.log.levels.WARN)
    return nil
  end
  local tmp = paths.nook() .. "/.nvim/xdg/kc_zone_proposed.tmp"
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), tmp)
  local parsed = decode(run("judge", { "--path", rel, "--new", tmp, "--actor", "ai", "--policy", "--json" }))
  if not parsed then
    vim.notify("kc zone: judge 没返回可解析结果", vim.log.levels.ERROR)
    return nil
  end
  vim.notify(("kc zone judge: %s\n%s"):format(parsed.decision, parsed.reason or ""),
    parsed.decision == "deny" and vim.log.levels.WARN or vim.log.levels.INFO, { title = "kc zone" })
  return parsed
end

--- 总装。可重复调用（热更）：augroup clear 会换掉旧回调。
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local c = M.config.colors
  vim.api.nvim_set_hl(0, "KcZoneHuman", { bg = c.human, default = true })
  vim.api.nvim_set_hl(0, "KcZoneHumanSign", { fg = c.human_fg, default = true })
  vim.api.nvim_set_hl(0, "KcZoneAI", { bg = c.ai, default = true })
  vim.api.nvim_set_hl(0, "KcZoneAISign", { fg = c.ai_fg, default = true })
  vim.api.nvim_set_hl(0, "KcZoneLegacy", { bg = c.legacy, default = true })
  vim.api.nvim_set_hl(0, "KcZoneLegacySign", { fg = c.legacy_fg, default = true })
  vim.api.nvim_set_hl(0, "KcZoneVirt", { fg = c.virt, default = true })

  local function schedule_refresh(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local gen = (vim.b[buf].kc_zone_gen or 0) + 1
    vim.b[buf].kc_zone_gen = gen
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].kc_zone_gen == gen then M.refresh(buf) end
    end, 150)
  end

  local grp = vim.api.nvim_create_augroup("kc_zone", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = grp,
    callback = function(a) schedule_refresh(a.buf) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function(a)
      M.refresh(a.buf)
      M.check(a.buf, { quiet = true })
    end,
  })

  vim.api.nvim_create_user_command("KcZoneRefresh", function() M.refresh(0) end,
    { desc = "kc: 重新上色当前文件的区域" })
  vim.api.nvim_create_user_command("KcZoneStatus", function() M.status(0) end,
    { desc = "kc: 当前文件的 covered 与 human/ai/legacy 计数" })
  vim.api.nvim_create_user_command("KcZoneCheck", function() M.check(0) end,
    { desc = "kc: 检查当前文件的区域标记（结果进 quickfix）" })
  vim.api.nvim_create_user_command("KcZoneJudge", function() M.judge_current(0) end,
    { desc = "kc: 把当前 buffer 当成 AI 的改动判一次（只判不写）" })
  vim.api.nvim_create_user_command("KcZoneToggleLegacy", function() M.toggle_legacy() end,
    { desc = "kc: 开关 legacy（未标注）行高亮" })
end

return M
