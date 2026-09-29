-- kc/lsp.lua —— C/C++ 的 LSP（clangd）。**零插件**：用 nvim 内建的 LSP 客户端。
--
-- 与"语法高亮"是两件事：高亮是 tree-sitter/正则的事；这里给的是补全、跳转、hover、诊断。
-- 本 nook 的 clangd 不在 PATH 上（VS 2022 自带），所以先解析可执行文件位置再启动。
--
-- 编译参数来源：`gdext/compile_commands.json`（由 `scons ... compiledb` 生成，不进 git）。
-- 注意：那个 DB 在 `gdext/`，而 `native/`、`thirdparty/` 不是它的子目录 —— clangd 默认只从
-- 源文件所在目录往上找 DB，所以这里显式 `--compile-commands-dir` 指过去。
local M = {}

local paths = require("kc.paths")

--- 纯函数：从候选里挑第一个「可执行」的 clangd。
--- `runnable` 可注入（判据/调用方传），缺省只查存在性；启动路径会传真实的自检。
--- 为什么不能只查存在性：实测 VS 里同时有 x64 和 ARM64 两份 clangd，
--- `executable()` 对 ARM64 那份也返回 1，但在 x64 上运行时直接报错。
function M.pick(candidates, runnable)
  for _, p in ipairs(candidates or {}) do
    if type(p) == "string" and p ~= "" and vim.fn.executable(p) == 1 then
      if runnable == nil or runnable(p) then
        return p
      end
    end
  end
  return nil
end

--- 真自检：跑 `clangd --version`，退出码 0 才认。能挡掉架构不匹配 / 坏安装。
function M.runnable(p)
  local ok = pcall(vim.fn.system, { p, "--version" })
  return ok and vim.v.shell_error == 0
end

--- clangd 候选：PATH → VS 2022 x64 → VS 2022 其它架构 → 标准 LLVM 安装。
function M.candidates()
  local out = {}
  local on_path = vim.fn.exepath("clangd")
  if on_path ~= "" then out[#out + 1] = on_path end
  for _, pat in ipairs({
    "C:/Program Files/Microsoft Visual Studio/*/*/VC/Tools/Llvm/x64/bin/clangd.exe",
    "C:/Program Files/Microsoft Visual Studio/*/*/VC/Tools/Llvm/*/bin/clangd.exe",
    "C:/Program Files/Microsoft Visual Studio/*/*/VC/Tools/Llvm/bin/clangd.exe",
    "C:/Program Files/LLVM/bin/clangd.exe",
    "C:/Program Files (x86)/LLVM/bin/clangd.exe",
  }) do
    vim.list_extend(out, vim.fn.glob(pat, false, true))
  end
  return out
end

function M.clangd()
  if M._resolved == nil then
    M._resolved = M.pick(M.candidates(), M.runnable) or false
  end
  return M._resolved or nil
end

--- 启动 clangd。找不到 clangd 就返回 false（调用方决定要不要出声）。
function M.setup()
  local clangd = M.clangd()
  if not clangd then
    return false
  end
  local cmd = { clangd, "--background-index", "--clang-tidy=0", "--header-insertion=never" }
  -- 只在 DB 真在的时候才指；指向一个不存在的目录会让 clangd 不再往上找。
  local db_dir = paths.repo() .. "/gdext"
  if vim.uv.fs_stat(db_dir .. "/compile_commands.json") then
    cmd[#cmd + 1] = "--compile-commands-dir=" .. db_dir
  end
  vim.lsp.config("clangd", {
    cmd = cmd,
    filetypes = { "c", "cpp", "objc", "objcpp" },
    -- root 到仓库根（有 .git）；编译参数由上面的 --compile-commands-dir 兜底
    root_markers = { ".git" },
  })
  -- nvim 0.11+ 自带的默认键：K=hover、grn=重命名、gra=代码动作、grr=引用、gri=实现、gO=文档符号，
  -- omnifunc 也会设成 v:lua.vim.lsp.omnifunc（<C-x><C-o> 能补全）。缺的是“跳转定义”，补上。
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("kc_lsp", { clear = true }),
    callback = function(a)
      local client = vim.lsp.get_client_by_id(a.data.client_id)
      if not client or client.name ~= "clangd" then return end
      vim.keymap.set("n", "gd", vim.lsp.buf.definition,
        { buffer = a.buf, desc = "kc: 跳转定义（clangd）" })
    end,
  })
  vim.lsp.enable("clangd")
  return true
end

return M
