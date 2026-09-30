# 拖动判据：模拟真实鼠标按住并连续拖动，断言**窗口位移 ≈ 光标位移**。
#
# 为什么要判"跟得上"而不是"动没动"：旧实现（window_set_position(pos + event.relative)）
# 在 10px/40ms 的**离散跳**形态下也能 100% 跟随，所以旧判据一直打印 ✅；
# 只有**连续小位移**才暴露它（实测 1px/1ms 只跟 30%、3px/3ms 有 45% 的帧反向跳）。
# 详见 SPEC.md「拖动：不能用 event.relative 累加」。
#
# 变量名一律避开 $h/$W/$H：PowerShell 变量名**大小写不敏感**，
# $h(句柄) 与 $H(高度) 是同一个变量，赋值会互相覆盖（实测踩过：句柄被 380 覆盖后
# GetWindowRect 静默失败，看起来像"窗口消失了"）。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DragTest {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);
  [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint p);
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
  public const uint NOSIZE = 0x0001, NOACTIVATE = 0x0010;
  public static IntPtr Find(string title) { return FindWindow(null, title); }
  public static string Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r.L + "," + r.T + "," + (r.R - r.L) + "x" + (r.B - r.T); }
}
"@

$title = "keycount pet (DEBUG)"
$hwnd = [DragTest]::Find($title)
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "找不到窗口：$title"; exit 1 }

$orig = [DragTest]::Rect($hwnd)
Write-Output "窗口原始矩形: $orig"

# 先摆到固定位置，保证往右下拖 300px 一定还在屏幕内（判据要能反复重跑）
[void][DragTest]::SetWindowPos($hwnd, [IntPtr]::Zero, 200, 200, 0, 0, [DragTest]::NOSIZE -bor [DragTest]::NOACTIVATE)
Start-Sleep -Milliseconds 500

$before = [DragTest]::Rect($hwnd)
$parts = $before.Split(",")
$bL = [int]$parts[0]; $bT = [int]$parts[1]
$winW = [int]($parts[2].Split("x")[0]); $winH = [int]($parts[2].Split("x")[1])
$cx = $bL + [int]($winW / 2); $cy = $bT + [int]($winH / 2)
Write-Output "把鼠标挪到圆心 ($cx,$cy)"

# 前置检查：光标真的到位了吗？（不然"拖动根本没开始"会被当成"拖动无效"，浪费一轮）
$ok = $false
$pt = New-Object DragTest+POINT
for ($t = 0; $t -lt 6 -and -not $ok; $t++) {
  [void][DragTest]::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 250
  [void][DragTest]::GetCursorPos([ref]$pt)
  $ok = ([Math]::Abs($pt.X - $cx) -le 2 -and [Math]::Abs($pt.Y - $cy) -le 2)
}
if (-not $ok) {
  Write-Output "❌ 前置检查失败：光标挪不到圆心（想要 $cx,$cy，实际 $($pt.X),$($pt.Y)）"
  [void][DragTest]::SetWindowPos($hwnd, [IntPtr]::Zero, $bL, $bT, 0, 0, [DragTest]::NOSIZE -bor [DragTest]::NOACTIVATE)
  exit 1
}

$steps = 300     # 每步 1px
[void][DragTest]::timeBeginPeriod(1)
[DragTest]::mouse_event([DragTest]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
# 连续拖：1px/1ms，共 (steps, steps) px —— 判据的关键形态，见文件头注释
for ($i = 1; $i -le $steps; $i++) {
  [void][DragTest]::SetCursorPos($cx + $i, $cy + $i)
  Start-Sleep -Milliseconds 1
}
[DragTest]::mouse_event([DragTest]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 400
[void][DragTest]::timeEndPeriod(1)

$after = [DragTest]::Rect($hwnd)
$dx = [int]$after.Split(",")[0] - $bL
$dy = [int]$after.Split(",")[1] - $bT
Write-Output "拖动后窗口矩形: $after"
Write-Output ("光标位移 = ({0}, {1})   窗口位移 = ({2}, {3})   ⇒ 跟随比 = {4:P0}" -f $steps, $steps, $dx, $dy, ($dx / [double]$steps))

# 还原窗口位置，别把用户的宠物挪走
[void][DragTest]::SetWindowPos($hwnd, [IntPtr]::Zero, [int]$orig.Split(",")[0], [int]$orig.Split(",")[1], 0, 0, [DragTest]::NOSIZE -bor [DragTest]::NOACTIVATE)

if ([Math]::Abs($dx - $steps) -le 5 -and [Math]::Abs($dy - $steps) -le 5) {
  Write-Output "跟随判据：窗口位移 ≈ 光标位移 ✅"
  exit 0
} else {
  Write-Output "跟随判据：窗口落后/抖动 ❌（光标走了 $steps px，窗口只走了 $dx px）"
  exit 1
}
