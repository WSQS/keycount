# 点击穿透判据：圆内可点、圆外穿透。
#
# 原理：`WindowFromPoint` 会**跳过**带 WS_EX_TRANSPARENT 的窗口（文档行为），
# 所以它正好回答「这一点上鼠标会落到谁身上」：
#   圆内（宠物本体）  → 应当返回宠物自己的 HWND
#   圆外（透明角）    → 应当**不是**宠物（落到下面的窗口或桌面）
#
# 注意：穿透状态是宠物**每帧根据光标位置**切换的，所以每个采样点都要先把光标挪过去、
# 等它跑一两帧，再问 WindowFromPoint —— 不能一次问一串点。
#
# 用法：
#   powershell -File agent-test/clickthrough-test.ps1                 # 测发布包（keycount.exe）
#   powershell -File agent-test/clickthrough-test.ps1 -Proc godot.windows.opt.tools.64
# 退出码：0 = 全部符合预期；1 = 有不符合；2 = 找不到窗口
param(
  [string]$Proc = "keycount",
  [double]$Radius = 0,           # 0 = 从宠物日志的 circle= 读（圆会被数字撑大，写死会假红）
  [int]$DeadlineMs = 300,        # 切换必须在这个时间内完成（实测只要 0～11ms，留足余量）
  [string]$OutDir = "$env:TEMP\kc-clickthrough"
)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class CT {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
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
  public static IntPtr At(int x, int y) { POINT p; p.X = x; p.Y = y; return WindowFromPoint(p); }
  public static void Move(int x, int y) { SetCursorPos(x, y); }
  public static string Cursor() { POINT p; GetCursorPos(out p); return p.X+","+p.Y; }
}
"@
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$hw = [CT]::Find($Proc)
if ($hw -eq [IntPtr]::Zero) { Write-Output "找不到进程 $Proc 的可见窗口"; exit 2 }
$parts = [CT]::R($hw).Split(",")
[int]$X = $parts[0]; [int]$Y = $parts[1]; [int]$W = $parts[2]; [int]$H = $parts[3]
$cx = $X + [int]($W / 2); $cy = $Y + [int]($H / 2)
$savedCursor = [CT]::Cursor()

# 半径：优先从宠物自己的日志读（ALIVE ... circle=NN）。
# 圆的大小随数字长度变（数字变长 → 圈变大），写死一个数会在数字变长后假红 ——
# 这正是这条判据以前的问题。日志里的 circle 是**画的圆**，命中/穿透用的是它 + 6px 晕。
if ($Radius -le 0) {
  $logPath = Join-Path $env:APPDATA "Godot\app_userdata\keycount pet\run.log"
  if (Test-Path $logPath) {
    $tail = (Get-Content $logPath -Tail 40) -join " "
    $m = [regex]::Matches($tail, 'circle=(\d+)')
    if ($m.Count -gt 0) { $Radius = [double]$m[$m.Count - 1].Groups[1].Value + 6.0 }
  }
  if ($Radius -le 0) { Write-Output "⚠️ 读不到日志里的 circle=，退回 96"; $Radius = 96 }
}
Write-Output ("窗口 0x{0:X} 中心 ({1},{2})  判据半径 {3}（圆 + 晕）" -f [int64]$hw, $cx, $cy, $Radius)

$inside = [Math]::Round($Radius - 12)
$outside = [Math]::Round($Radius + 12)
$cases = @(
  @{ name = "圆心";            dx = 0;        dy = 0;        expect = "pet"  },
  @{ name = "内·上";           dx = 0;        dy = -$inside; expect = "pet"  },
  @{ name = "内·下";           dx = 0;        dy = $inside;  expect = "pet"  },
  @{ name = "内·左";           dx = -$inside; dy = 0;        expect = "pet"  },
  @{ name = "内·右";           dx = $inside;  dy = 0;        expect = "pet"  },
  @{ name = "外·上";           dx = 0;        dy = -$outside;expect = "pass" },
  @{ name = "外·下";           dx = 0;        dy = $outside; expect = "pass" },
  @{ name = "外·左";           dx = -$outside;dy = 0;        expect = "pass" },
  @{ name = "外·右";           dx = $outside; dy = 0;        expect = "pass" },
  @{ name = "窗口左上角";      dx = -($W/2)+4;dy = -($H/2)+4;expect = "pass" },
  @{ name = "窗口右下角";      dx = ($W/2)-4; dy = ($H/2)-4; expect = "pass" }
)

$failed = 0
foreach ($c in $cases) {
  $x = $cx + [int]$c.dx; $y = $cy + [int]$c.dy
  [CT]::Move($x, $y)
  # 轮询等它切过来（顺便量延迟）：穿透状态是宠物**每帧按光标位置**切的，
  # 不能只 sleep 固定时间就断言（实测切换只要 0～11ms，但首帧/首次切换可能慢一点）。
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $ms = -1; $isPet = $false
  while ($sw.Elapsed.TotalMilliseconds -lt $DeadlineMs) {
    $hit = [CT]::At($x, $y)
    $isPet = ($hit -eq $hw)
    $good = if ($c.expect -eq "pet") { $isPet } else { -not $isPet }
    if ($good) { $ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1); break }
    Start-Sleep -Milliseconds 5
  }
  $ok = $ms -ge 0
  if (-not $ok) { $failed++ }
  Write-Output ("  {0} {1,-12} 期望 {2,-4} 实际 {3,-12} 耗时 {4} ms" -f `
    $(if ($ok) { "PASS" } else { "FAIL" }), $c.name, $c.expect,
    $(if ($isPet) { "宠物" } else { "0x" + ("{0:X}" -f [int64]$hit) }), $ms)
}

$sp = $savedCursor.Split(",")
[CT]::Move([int]$sp[0], [int]$sp[1])   # 把光标放回原处

Write-Output ""
if ($failed -eq 0) { Write-Output "点击穿透判据：全部符合预期 ✅"; exit 0 }
Write-Output ("点击穿透判据：{0} 项不符合 ❌" -f $failed); exit 1
