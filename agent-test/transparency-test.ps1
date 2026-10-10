# 透明性判据：把窗口挪走，比较同一块屏幕区域的像素。
#
# 为什么需要它：宠物窗口是"整块 380×380 的透明画布 + 中间一个圆"。如果渲染器起了
# Vulkan/Forward+，那**整块会变成纯黑方块**（把桌面遮住），而 CI 断言不了这一点
# （要真实桌面 + 真实窗口）。2026-10-09 首次发布流程就漏掉过 —— 当时我用肉眼看截图
# 下了"透明正常"的结论，后来用这个脚本一量才知道默认启动是黑方块。
#
# 原理：窗口透明 ⇒ 四角像素应当跟着"窗口后面的内容"变；
#       黑方块 / 不透明 ⇒ 四角在挪窗前后都不变，且亮度恒为 0。
#
# 用法：
#   powershell -File agent-test/transparency-test.ps1                      # 测发布包（keycount.exe）
#   powershell -File agent-test/transparency-test.ps1 -Proc godot.windows.opt.tools.64   # 测开发版
# 退出码：0 = 透明；1 = 黑方块/不透明；2 = 找不到窗口
param(
  [string]$Proc = "keycount",
  [int]$Shift = 420,
  [string]$OutDir = "$env:TEMP\kc-transparency"
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class TK {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  // 注意：不要用 FindWindow($null, title) —— PowerShell 会把 $null 变成空字符串，
  // 于是去找"类名为空"的窗口，必然失败（实测踩过）。
  public static IntPtr Find(string proc) {
    var pids = new System.Collections.Generic.List<uint>();
    foreach (var p in System.Diagnostics.Process.GetProcessesByName(proc)) pids.Add((uint)p.Id);
    IntPtr found = IntPtr.Zero;
    EnumWindows((h,l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (pids.Contains(p) && IsWindowVisible(h)) {
        RECT r; GetWindowRect(h, out r);
        if (r.R - r.L > 200 && r.B - r.T > 200) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string R(IntPtr h) { RECT r; GetWindowRect(h, out r); return r.L+","+r.T+","+(r.R-r.L)+","+(r.B-r.T); }
  public static void Move(IntPtr h, int x, int y) { SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x1|0x10); }
}
"@
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Cap([int]$x, [int]$y, [int]$w, [int]$h) {
  $b = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($x, $y, 0, 0, $b.Size)
  $g.Dispose()
  return $b
}

# 只比「四角」：窗口的圆在中间，四角是纯透明区 —— 透明时它们应当完全跟着后面内容变。
function CornerStats($imgA, $imgB, [int]$w, [int]$h, [int]$e) {
  $diff = 0; $tot = 0; [double]$sA = 0; [double]$sB = 0
  foreach ($cx in @(0, ($w - $e))) {
    foreach ($cy in @(0, ($h - $e))) {
      for ($i = 0; $i -lt $e; $i++) {
        for ($j = 0; $j -lt $e; $j++) {
          $pa = $imgA.GetPixel($cx + $i, $cy + $j); $pb = $imgB.GetPixel($cx + $i, $cy + $j)
          $tot++
          if ([Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B) -gt 30) { $diff++ }
          $sA += ($pa.R + $pa.G + $pa.B) / 3.0
          $sB += ($pb.R + $pb.G + $pb.B) / 3.0
        }
      }
    }
  }
  return @{ diff = $diff; tot = $tot; avgA = [Math]::Round($sA / $tot, 1); avgB = [Math]::Round($sB / $tot, 1) }
}

$hw = [TK]::Find($Proc)
if ($hw -eq [IntPtr]::Zero) { Write-Output "找不到进程 $Proc 的可见窗口"; exit 2 }
$parts = [TK]::R($hw).Split(",")
[int]$X = $parts[0]; [int]$Y = $parts[1]; [int]$W = $parts[2]; [int]$H = $parts[3]
Write-Output ("窗口 {0},{1} {2}x{3}" -f $X, $Y, $W, $H)

$a = Cap $X $Y $W $H
$a.Save((Join-Path $OutDir "A.png")) | Out-Null

# 前置：先确认「桌面没在动」。同一位置连拍两张，四角应当完全一致；
# 不一致说明背景自己在变（实测踩过：活跃桌面下判据会假红 ❌，其实窗口是透明的）。
Start-Sleep -Milliseconds 400
$a2 = Cap $X $Y $W $H
$jitter = (CornerStats $a $a2 $W $H 40).diff
if ($jitter -gt 50) {
  Write-Output ("⚠️ 桌面在动（四角有 {0} 个像素在 0.4s 内变了）—— 这次测不准（不是失败，请重跑）" -f $jitter)
  exit 2
}

[TK]::Move($hw, $X + $Shift, $Y)
Start-Sleep -Milliseconds 900
$b = Cap $X $Y $W $H
$b.Save((Join-Path $OutDir "B.png")) | Out-Null
[TK]::Move($hw, $X, $Y)

$st = CornerStats $a $b $W $H 40
$diff = $st.diff; $tot = $st.tot; $avgA = $st.avgA; $avgB = $st.avgB
$avgA = [Math]::Round($sumA / $tot, 1); $avgB = [Math]::Round($sumB / $tot, 1)
Write-Output ("四角 {0} 像素：挪窗前后不同处 {1} 个（{2}%）；平均亮度 A={3} B={4}（0=纯黑）" -f `
  $tot, $diff, ([Math]::Round(100.0 * $diff / $tot, 1)), $avgA, $avgB)
if ($diff -eq 0) { Write-Output "=> 四角完全跟着后面内容变 ⇒ 透明 ✅"; exit 0 }
elseif ($avgA -lt 10 -and $avgB -lt 10) { Write-Output "=> 四角始终接近纯黑 ⇒ 黑方块 ❌"; exit 1 }
else { Write-Output "=> 四角有固定内容（看 $OutDir 的 A/B 图）❌"; exit 1 }
