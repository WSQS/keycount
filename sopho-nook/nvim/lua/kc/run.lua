-- kc/run.lua —— 跑这个项目**真正的**验证命令，在浮窗里。
--
-- 为什么值得有这么一条：本项目的结论一贯要求"有实测数字"，而这些命令就是要按的那些
-- （native 两个自检、扩展编译、数据查询）。做进浮窗是为了不必离开编辑器、也不会记错参数。
--
-- 两条纪律：
--   · 每条命令都是**直接 argv**，不经 shell 拼字符串；跑不了的如实说原因，不假装跑过。
--   · 每次跑都先 kill 掉上一个 run 浮窗 —— 复用会指向还活着的旧 job，等于骗人。
-- 加一条命令要同步加进 bin/kctest（终端侧）与 tools/criteria.sh（判据）。
local M = {}

local float = require("kc.float")
local paths = require("kc.paths")

--- Windows 上跑 .sh 必须显式找 Git Bash —— bash.exe 常常不在 PATH 上。
local function bash()
  if vim.fn.has("win32") == 0 then
    local p = vim.fn.exepath("bash")
    return p ~= "" and p or "/bin/bash"
  end
  for _, p in ipairs({
    "C:/Program Files/Git/bin/bash.exe",
    "C:/Program Files (x86)/Git/bin/bash.exe",
    "C:/Program Files/Git/usr/bin/bash.exe",
  }) do
    if vim.fn.executable(p) == 1 then return p end
  end
  local p = vim.fn.exepath("bash")
  return p ~= "" and p or nil
end
M.bash = bash

--- 命令行数据报表（Python 自带 sqlite3，直读宠物写的库）
local function cli(sub)
  return { "uv", "run", "--no-project", "python", paths.tools() .. "/keycount.py", sub }
end

--- 每条 build() 返回 { argv = {...}, cwd = "..." }；
--- 返回 nil, reason 表示这条现在跑不了（缺可执行文件之类），调用方要如实说。
M.commands = {
  {
    name = "验证全部：bin/kctest（native 两个自检 + 扩展编译检查）",
    build = function()
      local sh = bash()
      if not sh then return nil, "找不到 Git Bash（Windows 上跑 .sh 必须靠它）" end
      return { argv = { sh, paths.nook() .. "/bin/kctest" }, cwd = paths.repo() }
    end,
  },
  {
    name = "存储自检：test_store（39 条断言，不需要 Godot）",
    build = function()
      local exe = paths.native() .. "/test_store.exe"
      if vim.fn.executable(exe) ~= 1 then
        return nil, "native/test_store.exe 不存在 —— 先跑 native/build_store.sh（或菜单第一条）"
      end
      return { argv = { exe }, cwd = paths.native() }
    end,
  },
  {
    name = "键名自检：test_hook --selftest（25 条断言）",
    build = function()
      local exe = paths.native() .. "/test_hook.exe"
      if vim.fn.executable(exe) ~= 1 then
        return nil, "native/test_hook.exe 不存在 —— 先跑「验证全部」"
      end
      return { argv = { exe, "--selftest" }, cwd = paths.native() }
    end,
  },
  {
    name = "扩展编译检查：scons template_debug",
    build = function()
      if vim.fn.executable("scons") ~= 1 then return nil, "scons 不在 PATH" end
      return {
        argv = { "scons", "platform=windows", "target=template_debug", "api_version=4.7", "-j12" },
        cwd = paths.gdext(),
      }
    end,
  },
  {
    name = "今日键盘数据",
    build = function()
      if vim.fn.executable("uv") ~= 1 then return nil, "uv 不在 PATH" end
      return { argv = cli("today"), cwd = paths.repo() }
    end,
  },
  {
    name = "最近 7 天",
    build = function()
      if vim.fn.executable("uv") ~= 1 then return nil, "uv 不在 PATH" end
      return { argv = cli("week"), cwd = paths.repo() }
    end,
  },
  {
    name = "运行记录（能看出有没有没正常结束的运行）",
    build = function()
      if vim.fn.executable("uv") ~= 1 then return nil, "uv 不在 PATH" end
      return { argv = cli("runs"), cwd = paths.repo() }
    end,
  },
}

--- 命令名清单（帮助页与判据都用它，避免文档里再抄一份）
function M.names()
  local out = {}
  for i, c in ipairs(M.commands) do out[i] = c.name end
  return out
end

function M.run(idx)
  local c = M.commands[idx]
  if not c then return nil end
  local spec, reason = c.build()
  if not spec then
    vim.notify("kc: 「" .. c.name .. "」现在跑不了 —— " .. tostring(reason), vim.log.levels.WARN)
    return nil
  end
  float.kill("run") -- 每次一个干净的终端，不复用还活着的旧 job
  return float.open({
    key = "run",
    title = "kc run · " .. c.name,
    argv = spec.argv,
    cwd = spec.cwd,
  })
end

function M.pick()
  vim.ui.select(M.names(), { prompt = "kc: 跑哪一条？" }, function(_, idx)
    if idx then M.run(idx) end
  end)
end

return M
