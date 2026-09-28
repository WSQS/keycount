Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class FG2 {
  [StructLayout(LayoutKind.Sequential)]
  public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public int rcCaret_l, rcCaret_t, rcCaret_r, rcCaret_b;
  }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO gti);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  static string T(IntPtr h) {
    if (h == IntPtr.Zero) return "(无)";
    int n = GetWindowTextLength(h);
    StringBuilder sb = new StringBuilder(n + 2);
    GetWindowText(h, sb, sb.Capacity);
    return "0x" + h.ToInt64().ToString("X") + " [" + sb.ToString() + "]";
  }
  public static string Report() {
    IntPtr fg = GetForegroundWindow();
    uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
    GUITHREADINFO gti = new GUITHREADINFO(); gti.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    GetGUIThreadInfo(tid, ref gti);
    // 键盘事件去 hwndFocus，这才是「焦点窗口」
    return "前台= " + T(fg) + " pid=" + pid + "\n  真正持有键盘的 hwndFocus= " + T(gti.hwndFocus);
  }
}
"@
Write-Output ([FG2]::Report())
