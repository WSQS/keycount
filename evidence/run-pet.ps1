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
  [switch]$NoBuild                                    # 明确禁止自动编
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # evidence/ 的上一级
if (-not $Project) { $Project = Join-Path $root "pet" }

if (-not (Test-Path $Godot)) {
  throw "找不到 Godot：$Godot`n用 -Godot 指定路径（需要 4.7.2，扩展的 api_version 对准它）"
}
if (-not (Test-Path (Join-Path $Project "project.godot"))) {
  throw "找不到工程：$Project`n用 -Project 指定路径"
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
