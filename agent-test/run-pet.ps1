# 启动器：把「宠物出现之前谁持有键盘」记下来，传给宠物进程。
#
# 为什么必须有这一步（实测出来的）：Godot 在 GDExtension 初始化**之前**
# 就已经创建并激活了主窗口，所以在扩展里 GetForegroundWindow() 看到的永远是宠物自己
# （日志里 prev_foreground == hwnd 就是这个原因）。
# 只有启动器在拉起宠物之前那一瞬能看到真实的前置窗口。
# 宠物拿到它之后，用（此刻还是前台的）自己进程身份调用 SetForegroundWindow 把焦点还回去。
#
# 路径全部从脚本位置推导，所以整个工程可以随意搬家。

param(
  [string]$Project,                                   # 默认 <脚本>../../pet
  [string]$Godot = "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
  [string]$RenderingDriver = "opengl3",               # 必须是 opengl3，Vulkan 下透明会变黑方块
  [switch]$Build,                                     # 强制重新编扩展
  [switch]$NoBuild,                                   # 明确禁止自动编
  [switch]$Restart,                                   # 先优雅关掉已在跑的那个，再启动
  [switch]$AllowMultiple                              # 明知会双倍计数也要再开一个
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # agent-test/ 的上一级
if (-not $Project) { $Project = Join-Path $root "pet" }
$procName = Split-Path -Leaf $Godot                              # godot.windows.opt.tools.64.exe

if (-not (Test-Path $Godot)) {
  throw "找不到 Godot：$Godot`n用 -Godot 指定路径（需要 4.7.2，扩展的 api_version 对准它）"
}
if (-not (Test-Path (Join-Path $Project "project.godot"))) {
  throw "找不到工程：$Project`n用 -Project 指定路径"
}

# ---- 防重复启动 ----
# 每个宠物进程都会装一个自己的全局钩子，所以两个宠物 = 同一下按键被记两次，数字直接翻倍。
# 按**命令行里是否出现本工程路径**来判断，而不是按进程名 ——
# 否则你自己开着 Godot 编辑器看别的工程也会被误拦。
function Get-PetProcesses {
  # 不走正则：把两边都规范成「反斜杠 + 小写」再做子串匹配。
  # Windows 路径本来就大小写不敏感，这样也不用担心正则转义。
  $needle = $Project.Replace('/', '\').ToLowerInvariant()
  $raw = @(Get-CimInstance Win32_Process -Filter "Name = '$procName'" -ErrorAction SilentlyContinue)
  $matched = @($raw | Where-Object {
    if (-not $_.CommandLine) { return $false }   # 刚启动的进程有时读不到命令行
    $_.CommandLine.Replace('/', '\').ToLowerInvariant().Contains($needle)
  })
  # 前面这个逗号很关键：保证空结果也返回「数组」而不是「什么都没有」。
  # PowerShell 里把空管道结果赋给变量会得到 $null，而 $null.Count 也是 $null，
  # 于是 `$existing.Count -eq 0` 判为假 —— 重试循环会被静默跳过，守卫完全失效。
  # 这个坑我在这里实测踩到过，不是理论问题。
  return ,$matched
}

$existing = Get-PetProcesses
if ($existing.Count -lt 1) {
  # 刚启动的进程有时读不到 CommandLine，_此处重试两次，减少「紧接着又启动一个」的竞态
  for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Milliseconds 250
    $existing = Get-PetProcesses
    if ($existing.Count -gt 0) { break }
  }
}
if ($existing.Count -gt 0) {
  $pids = ($existing | ForEach-Object { $_.ProcessId }) -join ", "
  if ($Restart) {
    Write-Output "已经在跑（PID: $pids），按 -Restart 优雅关闭它 ..."
    foreach ($p in $existing) {
      $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
      if ($proc) {
        # CloseMainWindow 发的是 WM_CLOSE → 宠物会走 _shutdown：落盘 + 记录运行结束
        if (-not $proc.CloseMainWindow()) { Write-Output "  PID $($p.ProcessId) 关闭请求失败，强杀" ; $proc.Kill() }
      }
    }
    # 等它真的退出，别紧接着又起一个
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-PetProcesses).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if ((Get-PetProcesses).Count -gt 0) {
      Write-Output "  等不到它退出，强杀"
      Get-PetProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Start-Sleep -Seconds 1
    }
    Write-Output "  旧实例已退出（它的数据已经落盘了）"
  } elseif (-not $AllowMultiple) {
    Write-Output "已经有宠物在跑（PID: $pids），拒绝再启动一个。"
    Write-Output ""
    Write-Output "原因：每个宠物进程都会装自己的全局键盘钩子，两个一起跑会把同一下按键记两次，"
    Write-Output "      计数直接翻倍（我实测过：9 下按键变成了 18）。"
    Write-Output ""
    Write-Output "想重启：  -Restart      （会优雅关掉旧的：先落盘、再记录运行结束）"
    Write-Output "确实要两个：-AllowMultiple（数字会翻倍，除非你另有打算）"
    exit 1
  } else {
    Write-Output "警告：-AllowMultiple 已指定，现在会有 $($existing.Count + 1) 个宠物，计数会翻倍。"
  }
}

# ---- 扩展 dll 不在就编一次，省得「跑起来发现没加载扩展」 ----
$dll = Join-Path $Project "addons\keycount\bin\keycount.windows.template_debug.x86_64.dll"
if ($Build -or ((-not $NoBuild) -and (-not (Test-Path $dll)))) {
  $gdext = Join-Path $root "gdext"
  Write-Output "扩展 dll 缺失或有 -Build，开始编译 ..."
  Push-Location $gdext
  try {
    scons platform=windows target=template_debug api_version=4.7 -j12
    if ($LASTEXITCODE -ne 0) { throw "scons 失败（exit=$LASTEXITCODE）" }
    Copy-Item "bin\*.dll" (Join-Path $Project "addons\keycount\bin\") -Force
  } finally { Pop-Location }
}

# ---- 过一遍导入，否则 GDExtension 不会被注册（.godot/extension_list.cfg）----
$extList = Join-Path $Project ".godot\extension_list.cfg"
if (-not (Test-Path $extList)) {
  Write-Output "首次运行：先做一次导入以注册 GDExtension ..."
  & $Godot --headless --editor --quit --path $Project | Out-Null
}

# ---- 记下前置窗口，传给宠物 ----
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FgHelper {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
$prev = [FgHelper]::GetForegroundWindow().ToInt64()
Write-Output ("前置窗口 HWND = 0x{0:X}" -f $prev)

$env:KC_PREV_FOREGROUND = ("0x{0:X}" -f $prev)

Start-Process -FilePath $Godot -ArgumentList @("--path", $Project, "--rendering-driver", $RenderingDriver)
Write-Output "宠物已启动（KC_PREV_FOREGROUND 已传入）"
