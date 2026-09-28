Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class FG {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  public static string Title() {
    IntPtr h = GetForegroundWindow();
    int n = GetWindowTextLength(h);
    StringBuilder sb = new StringBuilder(n + 2);
    GetWindowText(h, sb, sb.Capacity);
    return h.ToInt64().ToString("X") + " | " + sb.ToString();
  }
}
"@
Write-Output ("前台窗口: " + [FG]::Title())
