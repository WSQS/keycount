-- kc/format.lua —— C/C++ 保存时格式化（clang-format，零插件）。
--
-- 只做 filetype `c` / `cpp`；风格来自**仓库根的 `.clang-format`**（`-style=file`，clang-format
-- 会从文件所在目录往上找）。找不到 clang-format 就什么都不做，并且**出声一次**——不假装格式化过。
--
-- 为什么不去用刚接上的 clangd 的 `textDocument/formatting`：`BufWritePre` 那一刻 clangd 可能
-- 还没挂上（它异步 attach），那样会**静默不格式化**；直接调 clang-format 更可靠，而且用的是
-- 同一个引擎、同一份 `.clang-format`。
--
-- 与区域标记的关系：格式化会重排行，可能碰到 human 区里的**空白**。这是人自己保存触发的工具行为，
-- 不是"agent 碰了 human"；判据里有一条"格式化后标记仍能解析、zonecheck 仍 0 错"来兜住最坏情况。
local M = {}

--- 纯函数：从候选里挑第一个存在的 clang-format（存在性判断可注入，判据用）
function M.pick(candidates, exists)
  exists = exists or function(p) return vim.fn.executable(p) == 1 end
  for _, p in ipairs(candidates or {}) do
    if type(p) == "string" and p ~= "" and exists(p) then return p end
  end
  return nil
end

function M.candidates()
  local out = {}
  local on_path = vim.fn.exepath("clang-format")
  if on_path ~= "" then out[#out + 1] = on_path end
  for _, pat in ipairs({
    "C:/Program Files/Microsoft Visual Studio/*/*/VC/Tools/Llvm/x64/bin/clang-format.exe",
    "C:/Program Files/Microsoft Visual Studio/*/*/VC/Tools/Llvm/*/bin/clang-format.exe",
    "C:/Program Files/LLVM/bin/clang-format.exe",
    "C:/Program Files (x86)/LLVM/bin/clang-format.exe",
  }) do
    vim.list_extend(out, vim.fn.glob(pat, false, true))
  end
  return out
end

--- 真自检：跑 `clang-format --version`，退出码 0 才认。
--- 与 lsp.lua 同一个坑：VS 里 x64 与 ARM64 两份并存，`executable()` 对 ARM64 也返回 1，
--- 但在 x64 上运行时直接报 `UNKNOWN: unknown error`。
function M.runnable(p)
  local ok = pcall(vim.fn.system, { p, "--version" })
  return ok and vim.v.shell_error == 0
end

function M.clang_format()
  if M._resolved == nil then M._resolved = M.pick(M.candidates(), M.runnable) or false end
  return M._resolved or nil
end

--- 跑 clang-format，返回格式化后的行数组；失败返回 nil + 原因。
--- 注意：`vim.system` 在 spawn 失败时会 **抛错**（ARM64 二进制在 x64 上就是这种），
--- 而这里跑在 `BufWritePre` 里 —— 一抛就把**整个保存**弄失败了。所以必须 pcall。
function M.run(buf, path)
  local exe = M.clang_format()
  if not exe then return nil, "no-clang-format" end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ok, res = pcall(vim.system, { exe, "-style=file", "-assume-filename", path },
    { stdin = table.concat(lines, "\n") .. "\n", text = true })
  if not ok then return nil, tostring(res) end
  local r = res:wait()
  if r.code ~= 0 then
    return nil, (r.stderr ~= "" and r.stderr or ("clang-format 退出码 " .. tostring(r.code)))
  end
  local out = vim.split(r.stdout, "\n", { plain = true })
  if out[#out] == "" then table.remove(out) end
  return out
end

--- 格式化一个 buffer（就地改）。返回 true 表示真的改了内容。
function M.format_buf(buf)
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  local ft = vim.bo[buf].filetype
  if ft ~= "c" and ft ~= "cpp" then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then return false end
  local out, err = M.run(buf, vim.fn.fnamemodify(path, ":p"))
  if not out then
    if err == "no-clang-format" then
      vim.notify_once("kc format: 没找到 clang-format，C/C++ 不做保存时格式化", vim.log.levels.WARN)
    else
      vim.notify("kc format: clang-format 失败：" .. tostring(err), vim.log.levels.ERROR)
    end
    return false
  end
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), out) then
    return false -- 已在格式上：不动它（免得制造假的 undo 步 / modified）
  end
  local current = vim.api.nvim_get_current_buf() == buf
  local view = current and vim.fn.winsaveview() or nil
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  if current then vim.fn.winrestview(view) end
  return true
end

--- 总装：只在保存时做（按用户要求），另给一个手动命令。
function M.setup()
  local grp = vim.api.nvim_create_augroup("kc_format", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = grp,
    pattern = { "*.c", "*.cc", "*.cpp", "*.cxx", "*.h", "*.hpp", "*.hxx" },
    callback = function(a) M.format_buf(a.buf) end,
  })
  vim.api.nvim_create_user_command("KcFormat", function() M.format_buf(0) end,
    { desc = "kc: 用 clang-format 格式化当前文件（C/C++）" })
end

return M
