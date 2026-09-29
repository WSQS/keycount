Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DragTest {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
  public static IntPtr Find(string title) { return FindWindow(null, title); }
  public static string Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r.L + "," + r.T + "," + (r.R - r.L) + "x" + (r.B - r.T); }
}
"@

$title = "keycount pet (DEBUG)"
$h = [DragTest]::Find($title)
if ($h -eq [IntPtr]::Zero) { Write-Output "找不到窗口：$title"; exit 1 }

# 窗口挪到固定位置，便于复现
$before = [DragTest]::Rect($h)
Write-Output "拖动前窗口矩形: $before"

# 取窗口中心（圆就在窗户正中）
$parts = $before.Split(",")
$cx = [int]$parts[0] + [int]($parts[2].Split("x")[0]) / 2
$cy = [int]$parts[1] + [int]($parts[2].Split("x")[1]) / 2
Write-Output "把鼠标挪到圆心 ($cx,$cy) 并按住左键拖 (+140,+90)"

[void][DragTest]::SetCursorPos($cx, $cy)
Start-Sleep -Milliseconds 300
[DragTest]::mouse_event([DragTest]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
for ($i = 1; $i -le 14; $i++) {
  [void][DragTest]::SetCursorPos($cx + $i * 10, $cy + [int]($i * 6.4))
  Start-Sleep -Milliseconds 40
}
[DragTest]::mouse_event([DragTest]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 300

$after = [DragTest]::Rect($h)
Write-Output "拖动后窗口矩形: $after"
$aL = [int]$after.Split(",")[0]; $aT = [int]$after.Split(",")[1]
$bL = [int]$before.Split(",")[0]; $bT = [int]$before.Split(",")[1]
Write-Output ("位移 = ({0}, {1})  → {2}" -f ($aL - $bL), ($aT - $bT), $(if ($aL -ne $bL -or $aT -ne $bT) { "拖动生效 ✅" } else { "拖动无效 ❌（窗口没动）" }))
