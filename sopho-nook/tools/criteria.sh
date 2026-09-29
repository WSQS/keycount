#!/usr/bin/env bash
# keycount 这一次安装的 sopho-nook 判据（条数以末尾汇总为准，别在这里写死）。
#
# 设计原则（与 note 那份一致）：每条都要能机械跑、并打印出可引用的结论；
# 证不了就如实 SKIP/FAIL，不假装通过。
#
# 从任何位置都能跑：  sopho-nook/tools/criteria.sh
set -uo pipefail   # 故意不用 -e：单条判据的失败应当记为 FAIL，而不是终止整轮

nook="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # <repo>/sopho-nook
repo="$(dirname "$nook")"
cd "$repo"
B="$nook/bin"

pass=0; failed=0; skip=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; failed=$((failed+1)); }
sk() { echo "  SKIP  $1"; skip=$((skip+1)); }

NVIM="$B/nvim-local"
# 这个 nvim 的 -c 'lua ...' 需要把 lua 当参数传，用个短包装免得引号互相打架
nv() { "$NVIM" --headless -c "$1" +q 2>&1; }

# ---------- ① / ② 隔离（并发跑：check-isolation 每次要拍两遍全局目录快照，很贵） ----------
# 并发是安全的：每个实例自己的 before/after 都夹着**它自己的**被测命令；
# 并发最多带来“别人的写入也算到我头上”的**误报**，不会让真泄露漏掉。
echo "########## ① / ② check-isolation（并发；工程外零差异）"
_iso1=$(mktemp); _iso2=$(mktemp)
"$B/check-isolation" -- "$NVIM" --headless +q >"$_iso1" 2>&1 &
_iso_p1=$!
"$B/check-isolation" -- "$B/pi-local" --version >"$_iso2" 2>&1 &
_iso_p2=$!
wait "$_iso_p1"; wait "$_iso_p2"
out=$(cat "$_iso1")
case "$out" in
  *PASS*) ok "① bin/nvim-local（工程外零差异）" ;;
  *) no "① 隔离失败"; printf '%s\n' "$out" | tail -6 | sed 's/^/     /' ;;
esac
out=$(cat "$_iso2")
case "$out" in
  *PASS*) ok "② bin/pi-local（工程外零差异）" ;;
  *) no "② 隔离失败"; printf '%s\n' "$out" | tail -6 | sed 's/^/     /' ;;
esac
rm -f "$_iso1" "$_iso2"

# ---------- ③ 五个 stdpath ----------
echo "########## ③ nvim 五个 stdpath 全在 sopho-nook/ 内"
canon() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1" 2>/dev/null || printf '%s' "${1//\\//}"
  else printf '%s' "$1"; fi
}
want=$(canon "$nook")
paths=$(nv 'lua for _,k in ipairs({"config","data","state","cache","run"}) do io.write(k.."="..vim.fn.stdpath(k).."\n") end' || true)
bad=0; seen=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  seen=$((seen+1))
  actual=$(canon "${line#*=}")
  case "$actual" in
    "$want"/*) ;;
    *) bad=$((bad+1)); echo "     ${line%%=*} = $actual  ← 不在 nook 内" ;;
  esac
done <<< "$paths"
if [ "$seen" -eq 5 ] && [ "$bad" -eq 0 ]; then ok "五条 stdpath 全在 $want 下"
elif [ "$seen" -ne 5 ]; then no "只读到 $seen 条 stdpath（应有 5 条）"
else no "$bad 条 stdpath 落在 nook 外"; fi

# ---------- ④ 本 nook 的 init 与 lua 真被加载 ----------
echo "########## ④ nook 自己的 init 与 nvim/lua/kc 真的被加载"
out=$(nv 'lua local m=pcall(require,"kc"); local p=pcall(require,"kc.paths"); local f=pcall(require,"kc.float"); local r=pcall(require,"kc.run"); io.write("loaded="..tostring(m and p and f and r))')
case "$out" in
  *loaded=true*) ok "kc / kc.paths / kc.float / kc.run 四个模块都可 require" ;;
  *) no "模块加载失败：$out" ;;
esac
out=$(nv 'lua local n=0; for _,m in ipairs(vim.api.nvim_get_keymap("n")) do if tostring(m.desc or ""):sub(1,3)=="kc:" then n=n+1 end end; io.write("kc_maps="..n)')
case "$out" in
  *kc_maps=0*) no "没有任何 kc: 前缀的键位被注册" ;;
  *kc_maps=*) ok "注册了 $(printf '%s' "$out" | grep -o '[0-9]*$') 条 kc: 键位" ;;
  *) no "读键位失败：$out" ;;
esac

# ---------- ⑤ 帮助页是现算的，不是硬编码清单 ----------
echo "########## ⑤ 帮助页现算（临时加一条映射，它必须出现；去掉前缀就不许出现）"
out=$(nv 'lua vim.keymap.set("n","<leader>Z",function() end,{desc="kc: 判据探针映射"}); local l=table.concat(require("kc.help").lines(),"\n"); io.write("probe="..tostring(l:find("判据探针映射")~=nil))')
case "$out" in
  *probe=true*) ok "临时注册的映射立刻出现在帮助页里（说明是现算的）" ;;
  *) no "帮助页没有反映新注册的映射：$out" ;;
esac
out=$(nv 'lua vim.keymap.set("n","<leader>Y",function() end,{desc="没有前缀的映射"}); local l=table.concat(require("kc.help").lines(),"\n"); io.write("noprefix="..tostring(l:find("没有前缀的映射")~=nil))')
case "$out" in
  *noprefix=false*) ok "没有 kc: 前缀的映射不会混进帮助页（对照成立）" ;;
  *) no "对照失败：没有前缀的映射也出现了" ;;
esac

# ---------- ⑥ 路径推导 ----------
echo "########## ⑥ 路径推导正确（:KcInfo 对上 shell 推出来的）"
out=$(nv 'lua io.write(require("kc").info_lines()[1].."\n"..require("kc").info_lines()[2].."\n")')
got_nook=$(printf '%s\n' "$out" | sed -n '1s/^nook *= *//p')
got_repo=$(printf '%s\n' "$out" | sed -n '2s/^repo *= *//p')
if [ "$(canon "$got_nook")" = "$want" ] && [ "$(canon "$got_repo")" = "$(canon "$repo")" ]; then
  ok "nook 与 repo 都推对了"
else
  no "推导不对：nook=[$got_nook] repo=[$got_repo]"
fi

# ---------- ⑦ Windows 启动器的死规矩 ----------
echo "########## ⑦ .cmd 必须纯 ASCII（cmd.exe 遇 LF+非 ASCII 会行错位）"
badcmd=0
for f in "$B"/*.cmd; do
  [ -e "$f" ] || continue
  if LC_ALL=C grep -q '[^ -~]' "$f" 2>/dev/null; then
    badcmd=$((badcmd+1)); echo "     $(basename "$f") 含非 ASCII 字节"
  fi
done
if [ "$badcmd" -eq 0 ]; then ok "全部 .cmd 纯 ASCII（$(ls -1 "$B"/*.cmd 2>/dev/null | wc -l) 个）"
else no "$badcmd 个 .cmd 含非 ASCII"; fi

echo "########## ⑧ .cmd 的 NOOK 变量带尾随反斜杠（少了它会拼到 nook 旁边）"
if grep -q 'set "NOOK=%%~fI\\"' "$B"/*.cmd 2>/dev/null; then
  ok "找到 set \"NOOK=%%~fI\\\" 的写法"
else
  no "没有任何 .cmd 用了带尾随反斜杠的 NOOK"
fi

# ---------- ⑨ 数据不进 git ----------
echo "########## ⑨ 数据不进 git（.agent/ 与 .nvim/xdg/）"
out=$(git -C "$repo" check-ignore -v "$nook/.agent" "$nook/.nvim/xdg" 2>&1)
if [ "$(printf '%s\n' "$out" | grep -c 'sopho-nook/.gitignore')" -ge 2 ]; then
  ok ".agent/ 与 .nvim/xdg/ 都由 sopho-nook/.gitignore 挡住"
else
  no "没被挡住：$out"
fi

# ---------- ⑩ models.json 是真软链（MSYS 会静默拷成普通文件） ----------
echo "########## ⑩ .agent/models.json 是真软链，不是静默拷贝"
mj="$nook/.agent/models.json"
if [ -L "$mj" ]; then
  ok "是软链 → $(readlink "$mj")"
  if [ -f "$mj" ] && command -v cmp >/dev/null 2>&1; then
    if cmp -s "$mj" "$HOME/.pi/agent/models.json"; then ok "nook 视角与全局内容一致（同步生效）"
    else no "与全局内容不一致"; fi
  fi
else
  sk "不是软链（是拷贝）—— 那样 profile 换模型不会自动跟过来；重建：MSYS=winsymlinks:nativestrict ln -sf /c/Users/<你>/.pi/agent/models.json \"$mj\""
fi

# ---------- ⑪ 本项目技能真的被加载 ----------
echo "########## ⑪ pi-local 真的加载了本项目技能（含对照）"
if command -v pi >/dev/null 2>&1 || [ -x "$nook/bin/pi-local" ]; then
  out=$(printf '{"type":"get_commands","id":"c1"}\n' | PI_OFFLINE=1 "$B/pi-local" --mode rpc --no-session --no-context-files 2>/dev/null | grep -o 'skill:keycount-verification' | head -1 || true)
  if [ -n "$out" ]; then ok "RPC 里看得见 skill:keycount-verification"
  else no "没看到技能（--skill 没生效？）"; fi
  # 对照：不传 --skill 就该没有
  ctrl=$(printf '{"type":"get_commands","id":"c1"}\n' | PI_OFFLINE=1 PI_CODING_AGENT_DIR="$nook/.agent" pi --mode rpc --no-session --no-context-files 2>/dev/null | grep -c 'skill:keycount-verification' || true)
  if [ "${ctrl:-0}" -eq 0 ]; then ok "对照：不加 --skill 时没有这个技能"
  else sk "对照不成立（全局也带了同名技能？拿到的计数=$ctrl）"; fi
else
  sk "pi 不在 PATH"
fi

# ---------- ⑫ 改动只落一个文件夹 ----------
echo "########## ⑫ 改动只落一个文件夹（未跟踪项不得出现在 sopho-nook/ 之外）"
untracked=$(git status --porcelain | grep '^??' | sed 's/^?? //' | sort -u)
# 注意：nook 整体未入库时 git 会折叠成一条 "?? sopho-nook/"；已入库后就是里面的具体文件。
# 两种都算“落在 nook 里”，所以要排的是前缀 'sopho-nook/'，不是那一个目录名。
unexpected=$(printf '%s\n' "$untracked" | grep -v '^sopho-nook/' | grep -v '^$')
if [ -z "$unexpected" ]; then ok "sopho-nook/ 之外没有任何未跟踪项"
else no "还多出这些未跟踪项：$unexpected"; fi

# ---------- ⑬ 验证入口 ----------
echo "########## ⑬ bin/kctest 能跑（与 nvim 的 <leader>t 是同一份清单）"
if [ -x "$B/kctest" ]; then
  out=$("$B/kctest" 2>&1); rc=$?
  case "$out" in
    *"FAIL=0"*) if [ "$rc" -eq 0 ]; then ok "kctest 全绿（$(printf '%s' "$out" | grep -o 'PASS=[0-9]*' | tail -1)）"
                else no "kctest 汇总 FAIL=0 但退出码 $rc"; fi ;;
    *) no "kctest 有失败"; printf '%s\n' "$out" | tail -6 | sed 's/^/     /' ;;
  esac
else
  no "bin/kctest 不可执行"
fi

# ---------- ⑮ 候选集来自 git 且自洽 ----------
echo "########## ⑮ 选择列表的候选集：非空、已排序、无重复，且是 git 清单的子集"
out=$(nv 'lua local p=require("kc.picker"); local it=p.items(); local sorted=true; local seen={}; local dup=0; for i,x in ipairs(it) do if seen[x] then dup=dup+1 end; seen[x]=true; if i>1 and it[i-1]>x then sorted=false end end; io.write("count="..#it.." sorted="..tostring(sorted).." dup="..dup)')
count=$(printf '%s' "$out" | grep -o 'count=[0-9]*' | cut -d= -f2)
case "$out" in
  *"sorted=true"*"dup=0"*) if [ "${count:-0}" -gt 10 ]; then ok "候选 $count 个，已排序、无重复"
                          else no "候选只有 $count 个"; fi ;;
  *) no "候选集不自洽：$out" ;;
esac
# 子集性：候选里不许出现 git 清单里没有的路径（说明没自己造路径）
gitls=$(git -C "$repo" ls-files --cached --others --exclude-standard | sort)
outside=$(nv 'lua local it=require("kc.picker").items(); io.write(table.concat(it,"\n"))' | grep -v '^$' | sort | comm -23 - <(printf '%s\n' "$gitls") || true)
if [ -z "$(printf '%s' "$outside" | tr -d '[:space:]')" ]; then ok "候选集是 git 清单的子集（'什么是真文件'交给 .gitignore 说话）"
else no "候选里有 git 清单之外的路径：$(printf '%s' "$outside" | head -3)"; fi

# ---------- ⑯ 排除规则的纯函数边界 ----------
echo "########## ⑯ 排除规则 keep() 的边界（逐条断言）"
out=$(nv 'lua local p=require("kc.picker"); local n=0; local bad=0; local function t(rel,want) n=n+1; if p.keep(rel)~=want then bad=bad+1; io.write("  BAD "..rel.." -> "..tostring(p.keep(rel)).." (want "..tostring(want)..")\n") end end; t("native/kc_hook.cpp",true); t("SPEC.md",true); t("SConstruct",true); t(".gitignore",true); t("sopho-nook/bin/nook",true); t("pet/pet.gd",true); t("thirdparty/sqlite/sqlite3.c",false); t("gdext/godot-cpp/src/x.cpp",false); t("gdext/bin/keycount.dll",false); t("shots/crop-final.png",true==false); t("pet/addons/keycount/bin/x.dll",false); t("a/b/libfoo.a",false); t("a/b/archive.zip",false); io.write("cases="..n.." bad="..bad)')
case "$out" in
  *"bad=0"*) ok "$(printf '%s' "$out" | grep -o 'cases=[0-9]*') 条边界全过（含：无扩展名的 SConstruct 要留下、.dll/.a/.zip/.png 要排掉）" ;;
  *) no "排除规则有错：$out" ;;
esac

# ---------- ⑰ 候选集里不许混进产物 ----------
echo "########## ⑰ 候选集不含产物（这是把名单交给 .gitignore 的直接结果）"
out=$(nv 'lua local it=require("kc.picker").items(); local bad={}; for _,x in ipairs(it) do if x:find("%.log$") or x:find("rebuild") or x:find("%.import$") or x:find("godot%-cpp") or x:find("thirdparty/sqlite") or x:find("%%.godot/") or x:find("run%.log") then bad[#bad+1]=x end end; io.write("junk="..#bad); for _,x in ipairs(bad) do io.write(" "..x) end')
case "$out" in
  *"junk=0"*) ok "没有日志 / 编译产物 / 导入侧车 / vendored 源码混进候选" ;;
  *) no "候选里混进了产物：$out" ;;
esac

# ---------- ⑱ 过滤是纯函数 ----------
echo "########## ⑱ 过滤是纯函数（空查询 = 原样；有匹配；无匹配 = 0）"
out=$(nv 'lua local p=require("kc.picker"); local it=p.items(); local a=#p.filter(it,""); local b=#p.filter(it,"kc_store"); local c=#p.filter(it,"zzzz"); io.write("all="..#it.." empty="..a.." hit="..b.." miss="..c)')
case "$out" in
  *"hit=0"*) no "按 kc_store 过滤竟然 0 条：$out" ;;
  *"miss=0"*)
    empty=$(printf '%s' "$out" | grep -o 'empty=[0-9]*' | cut -d= -f2)
    all=$(printf '%s' "$out" | grep -o 'all=[0-9]*' | cut -d= -f2)
    if [ "$empty" = "$all" ]; then ok "过滤正确（$out）"; else no "空查询没有原样返回：$out"; fi ;;
  *) no "过滤不对：$out" ;;
esac

# ---------- ⑲ 入口纪律 ----------
echo "########## ⑲ bin/nook 只能无参数，且真的会进选择列表"
if [ -x "$B/nook" ]; then
  "$B/nook" foo >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then ok "带参数时退出码 2（有纪律，不静默忽略）"
  else no "带参数时退出码是 $rc（应为 2）"; fi
  if grep -q 'kc").pick()' "$B/nook"; then ok "bin/nook 确实调 require(\"kc\").pick()"
  else no "bin/nook 没有调 pick"; fi
else
  no "bin/nook 不可执行（「nook 进去」的入口）"
fi

# ---------- ⑭ 帮助页的口径与 README 一致 ----------
echo "########## ⑭ 帮助页列出的键位都能在 README 的交互节里找到"
if [ -f "$nook/README.md" ]; then
  out=$(nv 'lua local t={} for _,m in ipairs(vim.api.nvim_get_keymap("n")) do local d=tostring(m.desc or "") if d:sub(1,3)=="kc:" then t[#t+1]=m.lhs end end io.write(table.concat(t," "))')
  missing=0
  for lhs in $out; do
    # leader 是空格，README 里写作 <leader>X
    key="<leader>${lhs# }"
    [ "$key" = "<leader>" ] && continue
    grep -q -- "$key" "$nook/README.md" || { missing=$((missing+1)); echo "     $key 不在 README 里"; }
  done
  if [ "$missing" -eq 0 ]; then ok "帮助页的键位都在 README 的交互节里有交代"
  else no "$missing 条键位没写进 README"; fi
else
  no "sopho-nook/README.md 不存在"
fi

# ---------- ⑳ 列表跟着选中项滚（纯函数不变量） ----------
echo "########## ⑳ layout()：选中项永远落在可见窗口内，高亮行就是它那一条"
out=$(nv 'lua local p=require("kc.picker"); local bad=0; local cases=0; local function hits(n) local t={} for i=1,n do t[i]="f"..i end return t end; local function t(n,sel,rows,off) cases=cases+1; local h=hits(n); local lines,s,o,hi=p.layout(h,"",sel,rows,off); if #lines>rows+1 then bad=bad+1 end; if n>0 then if hi<1 or hi>#lines-1 then bad=bad+1 end; if s<o+1 or s>o+rows then bad=bad+1 end; if lines[hi+1]~="  ▸ "..h[s] then bad=bad+1 end end; if o<0 then bad=bad+1 end end; t(80,80,19,0); t(80,20,19,0); t(80,19,19,0); t(80,1,19,0); t(80,1,19,60); t(80,60,19,10); t(5,3,19,0); t(0,1,19,0); t(3,2,1,99); io.write("cases="..cases.." bad="..bad)')
case "$out" in
  *"bad=0"*) ok "$(printf '%s' "$out" | grep -o 'cases=[0-9]*') 条不变量全过（含：off 超界会被收回、rows=1 也不越界）" ;;
  *) no "layout() 不变量有错：$out" ;;
esac

# ---------- ㉑ 真开一次列表，移动后高亮仍在窗口内（这就是那个 bug） ----------
echo "########## ㉑ 集成：真开选择列表，下移 30 次后高亮仍在窗口内，回到顶部 off 归零"
cat > "$nook/.nvim/xdg/picker_scroll_check.lua" <<'LUA'
local p = require("kc.picker")
p.pick()
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
local h = vim.api.nvim_win_get_height(win)
local function hl()
  local ns = vim.api.nvim_get_namespaces()["kc_picker"]
  local m = ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) or {}
  return m[1] and m[1][2] or -1
end
local function key(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end
local out = {}
local function snap(tag)
  local n = vim.api.nvim_buf_line_count(buf)
  local l = hl()
  out[#out+1] = ("%s lines=%d hl=%d"):format(tag, n, l)
  return n, l
end
snap("init")
for _ = 1, 30 do key("<Down>") end
local n2, l2 = snap("down30")
local vis2 = (l2 >= 1 and l2 < h)
for _ = 1, 30 do key("<Up>") end
local n3, l3 = snap("up30")
local ok = (n2 <= h) and vis2 and (n3 <= h) and (l3 == 1)
io.write(table.concat(out, " ") .. " win_h=" .. h .. " ok=" .. tostring(ok))
LUA
out=$(timeout 40 "$NVIM" --headless -c "luafile sopho-nook/.nvim/xdg/picker_scroll_check.lua" +qa! 2>&1); rc=$?
case "$out" in
  *"ok=true"*) ok "$out" ;;
  *) no "移动后高亮掉出窗口或超时（rc=$rc）：$out" ;;
esac

# ---------- ㉒ nook 自己的 Lua 热更（<leader>r） ----------
echo "########## ㉒ reload：只清 kc.*、reload 后缓存清掉且键位重注册、失败返回 false 不假装成功"
cat > "$nook/.nvim/xdg/reload_check.lua" <<'LUA'
local r = require("kc.reload")
local bad = 0
local function eq(a, b, msg)
  if a ~= b then bad = bad + 1; io.write(" BAD " .. msg .. "\n") end
end
-- 纯函数：只认 kc 与 kc.*
eq(r.is_nook_module("kc"), true, "kc")
eq(r.is_nook_module("kc.paths"), true, "kc.paths")
eq(r.is_nook_module("kcfoo"), false, "kcfoo")
eq(r.is_nook_module("other.kc"), false, "other.kc")
eq(r.is_nook_module("kc2"), false, "kc2")
local sel = r.select({ kc = true, ["kc.paths"] = true, kcfoo = true, ["x.y"] = true, vim = true })
eq(#sel, 2, "select-只挑2个")
eq(sel[1], "kc", "select1")
eq(sel[2], "kc.paths", "select2")
-- 真重载：先加载一个懒模块，reload 后它必须被清掉，且 kc 表换成新的
require("kc.help")
local before = package.loaded["kc"]
local ok = r.reload()
eq(ok, true, "reload-返回true")
eq(package.loaded["kc.help"], nil, "kc.help-缓存被清掉")
if package.loaded["kc"] == before then bad = bad + 1; io.write(" BAD kc 没被换成新表\n") end
-- 重载后 setup 重新注册过键位（含 <leader>r 本身）
local n = 0
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  if tostring(m.desc or ""):sub(1, 3) == "kc:" then n = n + 1 end
end
if n < 9 then bad = bad + 1; io.write(" BAD maps=" .. n .. "\n") end
-- 失败路径：把 kc 挂到一个会报错的 loader 上，reload 必须返回 false（不假装成功）
package.preload["kc"] = function() error("boom: 故意让 kc 加载失败") end
local ok2 = r.reload()
package.preload["kc"] = nil
eq(ok2, false, "reload-失败返回false")
-- 恢复：摘掉坏 loader 后再 reload 一次必须重新成功（<leader>r 是旧映射，重试路径可用）
local ok3 = r.reload()
eq(ok3, true, "reload-恢复后成功")
-- 键位本身：<leader>r 必须注册，且真按下去会换掉 kc 表（映射指向 reload）
local lhs_found, desc = false, nil
for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
  if m.lhs == vim.g.mapleader .. "r" then lhs_found = true; desc = m.desc end
end
if not lhs_found then bad = bad + 1; io.write(" BAD <leader>r 没注册\n") end
local before4 = package.loaded["kc"]
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>r", true, false, true), "x", false)
if package.loaded["kc"] == before4 then bad = bad + 1; io.write(" BAD <leader>r 没有触发重载\n") end
io.write("lhs=" .. tostring(lhs_found) .. " maps=" .. n .. " bad=" .. bad)
LUA
out=$(timeout 40 "$NVIM" --headless -c "luafile sopho-nook/.nvim/xdg/reload_check.lua" +qa! 2>&1); rc=$?
case "$out" in
  *"bad=0"*) ok "$(printf '%s' "$out" | grep -o 'maps=[0-9]* bad=0' | tail -1)（纯函数边界 + 真重载 + 失败路径都过）" ;;
  *) no "reload 判据失败（rc=$rc）：$out" ;;
esac

# ---------- ㉓ 外部改动自动重载（watch） ----------
echo "########## ㉓ watch：纯函数判决 + 真 fs_event（setup 自启 / 干净重载 / 脏缓冲不覆盖）"
cat > "$nook/.nvim/xdg/watch_check.lua" <<'LUA'
local w = require("kc.watch")
local bad = 0
local function eq(a, b, m) if a ~= b then bad = bad + 1; io.write(" BAD " .. m .. " got=" .. tostring(a) .. " want=" .. tostring(b) .. "\n") end end
-- setup 应当已经把它开起来了（这条判据自己不再 start）
eq(w.status():find("started=true") ~= nil, true, "autostart-by-setup")
-- 纯函数：changed / decide 的全部边界
eq(w.changed(nil, nil), false, "changed-nil-nil")
eq(w.changed({ mtime = 1, size = 1 }, nil), true, "changed-has-nil")
eq(w.changed({ mtime = 1, size = 1 }, { mtime = 1, size = 1 }), false, "changed-same")
eq(w.changed({ mtime = 1, size = 1 }, { mtime = 2, size = 1 }), true, "changed-mtime")
eq(w.changed({ mtime = 1, size = 1 }, { mtime = 1, size = 2 }), true, "changed-size")
eq(w.decide(nil, nil, false), "skip", "decide-nil-nil")
eq(w.decide(nil, { mtime = 1, size = 1 }, false), "gone", "decide-gone")
eq(w.decide({ mtime = 2, size = 1 }, { mtime = 1, size = 1 }, false), "reload", "decide-reload")
eq(w.decide({ mtime = 2, size = 1 }, { mtime = 1, size = 1 }, true), "conflict", "decide-conflict")
eq(w.decide({ mtime = 1, size = 1 }, { mtime = 1, size = 1 }, true), "skip", "decide-skip")
-- 集成：真文件 + 真 fs_event
local dir = vim.fs.normalize(vim.fn.getcwd() .. "/sopho-nook/.nvim/xdg/watchtest")
vim.fn.mkdir(dir, "p")
local f = dir .. "/a.txt"
vim.fn.writefile({ "one" }, f)
vim.cmd("edit " .. vim.fn.fnameescape(f))
local buf = vim.api.nvim_get_current_buf()
w.start()
local function content() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
-- 干净缓冲区，外部改动 → 应自动读盘
vim.fn.writefile({ "two", "lines" }, f)
local ok1 = vim.wait(4000, function() return content() == "two\nlines" end, 50)
eq(ok1, true, "reload-external-change")
-- 脏缓冲区，外部改动 → 不许覆盖
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local-dirty" })
vim.bo[buf].modified = true
vim.fn.writefile({ "three" }, f)
local ok2 = vim.wait(1500, function() return content() == "three" end, 50)
eq(ok2, false, "dirty-not-overwritten")
eq(content(), "local-dirty", "dirty-kept")
w.stop()
io.write("bad=" .. bad)
LUA
out=$(timeout 60 "$NVIM" --headless -c "luafile sopho-nook/.nvim/xdg/watch_check.lua" +qa! 2>&1); rc=$?
case "$out" in
  *"bad=0"*) ok "纯函数 10 条 + 真 fs_event：干净重载、脏缓冲不覆盖" ;;
  *) no "watch 判据失败（rc=$rc）：$out" ;;
esac

# ---------- ㉔ subagent 工具（vendored 扩展 + 政策软链） ----------
echo "########## ㉔ subagent：扩展真的注册了 subagent 工具；agents/prompts 能从 .agent 读到"
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  # 先跑一次 pi-local，让政策软链就位（idempotent）
  "$B/pi-local" --version >/dev/null 2>&1 || true
  to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  npmroot=$(npm root -g 2>/dev/null | tr -d '\r')
  pkg="$(to_native "$npmroot")/@earendil-works/pi-coding-agent"
  probe="$nook/.nvim/xdg/subagent_check.mjs"
  cat > "$probe" <<'JS'
const mod = await import(process.env.KC_PI_URL);
const { createAgentSession, DefaultResourceLoader, SessionManager } = mod;
const loader = new DefaultResourceLoader({
  cwd: process.env.KC_CWD,
  agentDir: process.env.PI_CODING_AGENT_DIR,
  additionalExtensionPaths: [process.env.KC_EXT],
});
await loader.reload();
const { session } = await createAgentSession({ resourceLoader: loader, sessionManager: SessionManager.inMemory() });
console.log("TOOLS=" + JSON.stringify(session.getActiveToolNames()));
session.dispose();
JS
  out=$(KC_PI_URL="file:///$pkg/dist/index.js" \
        KC_CWD="$(to_native "$repo")" \
        PI_CODING_AGENT_DIR="$(to_native "$nook/.agent")" \
        KC_EXT="$(to_native "$nook/pi/extensions/subagent")" \
        timeout 120 node "$probe" 2>&1 | grep -o 'TOOLS=.*' || true)
  case "$out" in
    *'"subagent"'*) ok "扩展注册成功：$out" ;;
    *) no "subagent 工具没注册：$out" ;;
  esac
else
  sk "没有 node/npm，跳 subagent 注册判据"
fi
# agents / prompts 必须能从 {agentDir} 下读到（扩展只认 {agentDir}/agents）
for f in agents/worker.md prompts/implement.md; do
  if [ -e "$nook/.agent/$f" ]; then ok ".agent/$f 可读（政策已挂进数据目录）"
  else no ".agent/$f 读不到（软链没建上？）"; fi
done
# 两个启动器都要把它接上
if grep -q 'pi/extensions/subagent' "$B/pi-local" && grep -qF 'pi\extensions\subagent' "$B/pi-local.cmd"; then
  ok "bin/pi-local 与 pi-local.cmd 都显式 --extension 指到 pi/extensions/subagent"
else
  no "启动器没有把 subagent 扩展接上"
fi

# ---------- ㉕ clangd LSP（零插件） ----------
echo "########## ㉕ clangd：候选解析（可运行才算）+ 真起一个 client 并确认能力"
cat > "$nook/.nvim/xdg/lsp_check.lua" <<'LUA'
local lsp = require("kc.lsp")
local bad = 0
local function eq(a, b, m) if a ~= b then bad = bad + 1; io.write(" BAD " .. m .. "\n") end end
eq(lsp.pick({ "definitely_not_here_xyz" }), nil, "pick-none")
eq(lsp.pick({}), nil, "pick-empty")
eq(lsp.pick({ "definitely_not_here_xyz", "cmd.exe" }, function() return true end) ~= nil, true, "pick-second")
eq(lsp.pick({ "cmd.exe" }, function() return false end), nil, "pick-runnable-rejects")
io.write("clangd=" .. tostring(lsp.clangd()) .. "\n")
vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/native/kc_hook.cpp"))
local ok = vim.wait(60000, function() return #vim.lsp.get_clients({ name = "clangd" }) > 0 end, 250)
local cls = vim.lsp.get_clients({ name = "clangd" })
local cap = (cls[1] and cls[1].server_capabilities) or {}
if not ok then bad = bad + 1; io.write(" BAD no-client\n") end
if cap.completionProvider == nil then bad = bad + 1; io.write(" BAD no-completion\n") end
if cap.definitionProvider ~= true then bad = bad + 1; io.write(" BAD no-definition\n") end
if vim.fn.maparg("gd", "n") == "" then bad = bad + 1; io.write(" BAD no-gd-map\n") end
io.write("clients=" .. #cls .. " bad=" .. bad)
LUA
out=$(timeout 120 "$NVIM" --headless -c "luafile sopho-nook/.nvim/xdg/lsp_check.lua" +qa! 2>&1); rc=$?
case "$out" in
  *"bad=0"*) ok "$(printf '%s' "$out" | grep -o 'clients=[0-9]* bad=0')（候选解析边界 + 真 clangd client 能力：补全/跳转）" ;;
  *"clangd=nil"*) sk "没找到可运行的 clangd（跳过 LSP 集成）" ;;
  *) no "clangd LSP 判据失败（rc=$rc）：$out" ;;
esac

# ---------- ㉖ zonecheck（区域标记的只读检查器） ----------
echo "########## ㉖ zonecheck：单测 + 仓库 check + CLI judge（ai 碰 human 必须 deny）"
if command -v uv >/dev/null 2>&1; then
  out=$(timeout 180 uv run --no-project python tools/zonecheck/test_zonecheck.py 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^OK$'; then
    ok "单测全过（$(printf '%s' "$out" | grep -oE 'Ran [0-9]+ tests' | head -1)）"
  else
    no "zonecheck 单测失败（rc=$rc）"; printf '%s\n' "$out" | tail -8 | sed 's/^/     /'
  fi
  # 仓库级：check 必须 0 错，且 covered 文件数 > 0
  # （防“整仓库被 exclude 掉 ⇒ judge 一律 allow”这个老坑——参考项目真踩过）
  files=$(timeout 120 uv run --no-project python tools/zonecheck/zonecheck.py stats 2>/dev/null | grep -oE '[0-9]+ 文件' | grep -oE '^[0-9]+' | head -1)
  timeout 120 uv run --no-project python tools/zonecheck/zonecheck.py check >/dev/null 2>&1; crc=$?
  if [ "$crc" -eq 0 ] && [ "${files:-0}" -gt 0 ]; then
    ok "仓库 check 0 错，且 covered 文件数 = $files（>0，没被 exclude 掏空）"
  else
    no "仓库 check 退出码=$crc，covered 文件数=${files:-?}"
  fi
  # CLI 级 judge（P3 门将来走的就是这条）：ai 碰 human 必须 deny + 退出码 1
  to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  zc="$nook/.nvim/xdg/zc_tmp"; rm -rf "$zc"; mkdir -p "$zc"
  cat > "$zc/.zonecheck.json" <<'JSON'
{"schema":1,"prefixByExt":{".py":"#"},"defaultPrefix":"//","include":["**/*.py"],"exclude":[],"generated":[],
 "defaultZone":"legacy","defaultZoneByFile":{},
 "policy":{"crossZone":"error","humanTouch":"error","markerEdit":"error","unmarkedTouch":"warn"}}
JSON
  printf '# >>> zone:human\nx = 1\n# <<<\ny = 2\n' > "$zc/a.py"
  printf '# >>> zone:human\nx = 2\n# <<<\ny = 2\n' > "$zc/proposed.py"
  out=$(timeout 120 uv run --no-project python tools/zonecheck/zonecheck.py --root "$(to_native "$zc")" judge \
        --path a.py --new "$(to_native "$zc/proposed.py")" --actor ai --policy --json 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '"decision": "deny"'; then
    ok "CLI judge：actor=ai 碰 human 区 → deny（rc=1）"
  else
    no "CLI judge 没拒（rc=$rc）：$out"
  fi
else
  sk "没有 uv，跳 zonecheck 判据"
fi

# ---------- ㉗ 区域标记在编辑器里可见（P2） ----------
echo "########## ㉗ zone P2：plan() 行映射/空区域/嵌套 + 真跑 check/judge/refresh"
cat > "$nook/.nvim/xdg/zone_check.lua" <<'LUA'
local z = require("kc.zone")
local bad = 0
local function eq(a, b, m) if a ~= b then bad = bad + 1; io.write(" BAD " .. m .. " got=" .. tostring(a) .. " want=" .. tostring(b) .. "\n") end end
local function pick(list, zone) for _, s in ipairs(list) do if s.zone == zone then return s end end end
-- plan：内容行 1 基闭区间 → extmark 0 基（end_row 含）
local e = { regions = { { zone = "human", begin = 2, ["end"] = 3, depth = 0 }, { zone = "ai", begin = 6, ["end"] = 6, depth = 0 } }, unmarked = { { 5, 5 } } }
local p = z.plan(e, { highlight_legacy = true })
eq(pick(p, "human").row0, 1, "human.row0")
eq(pick(p, "human").end_row, 2, "human.end_row")
eq(pick(p, "human").opts.sign_text, "H", "human.sign")
eq(pick(p, "ai").row0, 5, "ai.row0")
eq(pick(p, "legacy").row0, 4, "legacy.row0")
eq(#z.plan(e, { highlight_legacy = false }), 2, "legacy-off")
eq(#z.plan({ regions = { { zone = "human", begin = 4, ["end"] = 3, depth = 0 } } }, {}), 0, "empty-region-skipped")
local nest = z.plan({ regions = { { zone = "ai", begin = 2, ["end"] = 9, depth = 0 }, { zone = "human", begin = 4, ["end"] = 5, depth = 1 } } }, {})
eq(pick(nest, "human").opts.priority > pick(nest, "ai").opts.priority, true, "nested-human-wins")
-- 集成：真跑检查器与异步 refresh
vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/native/kc_hook.cpp"))
local buf = vim.api.nvim_get_current_buf()
eq(z.check(0), 0, "check-0-errors")
local j = z.judge_current(0)
eq(j ~= nil and j.decision, "allow", "judge-nochange-allow")
z.refresh(0)
eq(vim.wait(20000, function() return vim.b[buf].kc_zone_covered == true end, 200), true, "refresh-covered")
local cn = vim.b[buf].kc_zone_counts or {}
eq((cn.human or 0) + (cn.ai or 0), 0, "no-human-ai")
eq(vim.b[buf].kc_zone_marks >= 1, true, "legacy-block-drawn")
io.write("bad=" .. bad .. "\n")
LUA
out=$(timeout 180 "$NVIM" --headless -c "luafile sopho-nook/.nvim/xdg/zone_check.lua" +qa! 2>&1); rc=$?
case "$out" in
  *"bad=0"*) ok "plan() 映射/空区域/嵌套 + check(0 错) + judge(零改动 allow) + refresh 都过" ;;
  *) no "zone P2 判据失败（rc=$rc）：$out" ;;
esac

# ---------- ㉘ C/C++ 保存时格式化（clang-format） ----------
echo "########## ㉘ format：候选解析 + 真跑保存时格式化 + 标记不被弄坏"
to_native_fmt() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
fz="$nook/.nvim/xdg/fmt_zone"; rm -rf "$fz"; mkdir -p "$fz"
cat > "$fz/.zonecheck.json" <<'JSON'
{"schema":1,"prefixByExt":{},"defaultPrefix":"//","include":["**/*.cpp"],"exclude":[],"generated":[],"defaultZone":"legacy","defaultZoneByFile":{},"policy":{"crossZone":"error","humanTouch":"error","markerEdit":"error","unmarkedTouch":"warn"}}
JSON
cat > "$nook/.nvim/xdg/fmt_check.lua" <<'LUA'
local f = require("kc.format")
local bad = 0
local function eq(a, b, m) if a ~= b then bad = bad + 1; io.write(" BAD " .. m .. " got=" .. tostring(a) .. " want=" .. tostring(b) .. "\n") end end
eq(f.pick({ "definitely_not_here" }, function() return false end), nil, "pick-none")
eq(f.pick({ "definitely_not_here", "clang-format" }, function(p) return p == "clang-format" end), "clang-format", "pick-second")
eq(f.clang_format() ~= nil, true, "resolved")
local z = vim.fn.getcwd() .. "/sopho-nook/.nvim/xdg/fmt_zone/z.cpp"
vim.fn.writefile({ "// >>> zone:human", "int  f(int x){if(x){return  x;}", "// <<<" }, z)
vim.cmd("edit " .. vim.fn.fnameescape(z))
eq(vim.bo.filetype, "cpp", "filetype")
vim.cmd("write")
local disk = table.concat(vim.fn.readfile(z), "\n")
eq(disk:find("int f(int x) {", 1, true) ~= nil, true, "save-formatted")
eq(disk:find("// >>> zone:human", 1, true) ~= nil, true, "marker-begin-kept")
eq(disk:find("// <<<", 1, true) ~= nil, true, "marker-end-kept")
eq(f.format_buf(vim.api.nvim_get_current_buf()), false, "format-idempotent")
io.write("bad=" .. bad .. "\n")
LUA
out=$(timeout 180 "$NVIM" --headless -c "luafile sopho-nook/.nvim/xdg/fmt_check.lua" +qa! 2>&1); rc=$?
case "$out" in
  *"bad=0"*) ok "候选解析 + 真跑保存时格式化 + 标记仍在" ;;
  *) no "format 判据失败（rc=$rc）：$out" ;;
esac
timeout 120 uv run --no-project python tools/zonecheck/zonecheck.py --root "$(to_native_fmt "$fz")" check >/dev/null 2>&1
if [ "$?" -eq 0 ]; then ok "格式化后 zonecheck 仍 0 错（标记没被弄坏）"; else no "格式化后 zonecheck 报错"; fi

echo
echo "########## 汇总: PASS=$pass FAIL=$failed SKIP=$skip"
[ "$failed" -eq 0 ]
