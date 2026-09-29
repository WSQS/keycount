-- keycount 的工程内 nvim 入口（由 sopho-nook/bin/nvim-local 用 -u 指定；XDG_* 都指进本 nook 目录）。
-- 这里只做引导：定位 nook → 把 sopho-nook/nvim/lua 加进 package.path → 交给 kc 模块。
local this = debug.getinfo(1, "S").source:sub(2)
-- normalize 必须紧跟 :h:h：Windows 的 .cmd 启动器交出的是
--   ...\sopho-nook\bin\..\nvim\init.lua（字面含 \..）
-- 不归一化的话，下游再取一次 :h 会把 ".." 当成文件名切掉，
-- repo 就变成 ...\sopho-nook\bin —— 所有路径一起错一级。
local nook = vim.fs.normalize(vim.fn.fnamemodify(this, ":h:h"))
vim.g.kc_nook = nook
package.path = nook .. "/nvim/lua/?.lua;" .. nook .. "/nvim/lua/?/init.lua;" .. package.path

vim.g.mapleader = " "
vim.opt.number = true
vim.opt.signcolumn = "yes"

local ok, mod = pcall(require, "kc")
if ok then
  mod.setup({})
else
  vim.notify("kc: 模块加载失败 —— " .. tostring(mod), vim.log.levels.WARN)
end
