-- nook / repo 的路径只在这里推导一次。
--
-- 为什么单独成模块：fnamemodify 的 `:h` 是**纯文本切分**、不折叠 `..`。
-- Windows 的 .cmd 启动器交出的是字面含 `bin\..` 的 -u 路径，抄多份推导就会各自
-- 退错一级（note 那份历史上正好一半能跑，于是坏的那半看起来像孤例）。
-- 路径留一处，才不会只修好一半。
local M = {}

local function from_source()
  -- 本文件住在 <nook>/nvim/lua/kc/ 下，往上四级就是 nook。
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h")
end

--- <repo>/sopho-nook
function M.nook()
  return vim.fs.normalize(vim.g.kc_nook or from_source())
end

--- <repo>
function M.repo()
  return vim.fs.normalize(vim.fn.fnamemodify(M.nook(), ":h"))
end

--- 这个工程的几个面（判据与帮助页都从这里取，别在别处拼字符串）
function M.native() return M.repo() .. "/native" end
function M.gdext() return M.repo() .. "/gdext" end
function M.pet() return M.repo() .. "/pet" end
function M.tools() return M.repo() .. "/tools" end
function M.evidence() return M.repo() .. "/evidence" end
function M.spec() return M.repo() .. "/SPEC.md" end

--- bin 下的入口。脚本本体无扩展名；Windows 由 PATHEXT 落到同名 .cmd。
function M.exe(name)
  if vim.fn.has("win32") == 1 then
    return M.nook() .. "/bin/" .. name .. ".cmd"
  end
  return M.nook() .. "/bin/" .. name
end

--- 工程内 pi 启动器（两侧同一套设计，只是写法不同）
function M.pilocal() return M.exe("pi-local") end

--- 本项目真正的验证入口（native 测试 + 扩展编译检查），见 bin/kctest
function M.kctest() return M.exe("kctest") end

--- 跨来源路径的统一键：Windows 上 glob 展开段是反斜杠，而 normalize 出来是正斜杠。
--- 少这一步，数据明明有、界面却 join 不上。
function M.key(path)
  return vim.fs.normalize(path)
end

return M
