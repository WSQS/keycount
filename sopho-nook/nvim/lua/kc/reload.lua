-- kc/reload.lua —— 热更 nook 自己的 Lua：改 nvim/lua/kc/** 之后按 <leader>r，不必重启 nvim。
--
-- 只做两件事，顺序固定：
--   1. 从 package.loaded 里摘掉本 nook 的模块（kc 与 kc.*）；
--   2. 重新 require("kc").setup() —— 用新代码重新注册键位与命令。
-- 之后任何一次 require("kc.xxx") 都会从盘上重新读，于是新代码生效。
--
-- 口径（明写，别当它做了更多）：
--   · 只认 kc 与 kc.*。不碰内置、不碰别的插件 —— 热更能把整张模块表换掉，
--     但别的模块没按这条设计，替它们做主只会出事。
--   · **不重跑 nvim/init.lua**（它是 -u 交进来的脚本，不在 package.loaded 里）。
--     改了 init.lua 仍要重启 nvim。
--   · 已经跑着的浮窗进程不受影响：登记表在 _G（见 float.lua），跨模块重载存活。
local M = {}

--- 纯函数：模块名属不属于本 nook 的 Lua。只认 "kc" 与 "kc.xxx"，不误伤 kcfoo / other.kc。
function M.is_nook_module(name)
  return name == "kc" or name:sub(1, 3) == "kc."
end

--- 纯函数：从一张「已加载」表里挑出本 nook 的模块名，排序后返回。
--- 参数可注入（判据拿假表来测），缺省用真正的 package.loaded。
function M.select(loaded)
  local names = {}
  for name in pairs(loaded or package.loaded) do
    if M.is_nook_module(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

--- 当前已加载的本 nook 模块（排序）
function M.loaded_modules()
  return M.select(package.loaded)
end

--- 重载。返回 true/false；失败时把错误如实报出来，不装作成功。
function M.reload()
  local names = M.loaded_modules()
  for _, name in ipairs(names) do
    package.loaded[name] = nil
  end
  -- 重新加载 + 重新注册，任何一步抛错都报出来。
  -- 报错后 kc 可能处在半加载状态，但 <leader>r 是**旧映射**、仍然可用（Lua 清缓存不会
  -- 抹掉已注册的键位），修好文件再按一次即可 —— 这条重试路径不依赖刚被清掉的模块。
  local ok, err = pcall(function()
    require("kc").setup({})
  end)
  if not ok then
    vim.notify("kc: 重载失败（旧代码仍在跑）—— " .. tostring(err),
      vim.log.levels.ERROR, { title = "kc reload" })
    return false
  end
  vim.notify(("kc: 已重载 %d 个模块：%s"):format(#names, table.concat(names, ", ")),
    vim.log.levels.INFO, { title = "kc reload" })
  return true
end

return M
