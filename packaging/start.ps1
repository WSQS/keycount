# keycount pet 启动器（随发布包分发）
#
# 为什么需要这一层：
#   Godot 在 GDExtension 初始化**之前**就已经创建并激活了主窗口，所以在扩展里
#   GetForegroundWindow() 看到的永远是宠物自己 —— 宠物就没法把键盘还回去。
#   只有在**拉起宠物之前**那一刻记下「谁持有键盘」，宠物起来后第一帧才能
#   用（此刻仍是前台的）自己进程身份 SetForegroundWindow 把它还回去。
#
# 直接双击 keycount.exe 也能跑，但启动那一下键盘会被宠物夺走
# （你正在打的字会掉进宠物里，什么都不会出现）。
$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class KcFgHelper {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@

$exe = Join-Path $PSScriptRoot "keycount.exe"
if (-not (Test-Path $exe)) {
  throw "找不到 $exe —— 启动器要和 keycount.exe 放在同一个文件夹里"
}

$prev = [KcFgHelper]::GetForegroundWindow().ToInt64()
# 传给宠物：它读 KC_PREV_FOREGROUND，把焦点还回去。格式 0xHHHH（strtoull base 0）
$env:KC_PREV_FOREGROUND = ("0x{0:X}" -f $prev)

Start-Process -FilePath $exe
Write-Host ("keycount pet 已启动（前置窗口 0x{0:X}）" -f $prev)
