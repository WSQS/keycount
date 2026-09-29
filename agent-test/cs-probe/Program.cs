using System.Diagnostics;
using System.Runtime.InteropServices;

// 只用 Win32 低层键盘钩子，验证 C# 侧能否装上钩子
internal static class Program
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private static nint _hook = 0;
    private static int _count = 0;

    private delegate nint HookProc(int nCode, nint wParam, nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookExW(int idHook, HookProc lpfn, nint hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(nint hhk);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hhk, int nCode, nint wParam, nint lParam);

    [DllImport("kernel32.dll")]
    private static extern nint GetModuleHandleW(string? name);

    private static nint Callback(int nCode, nint wParam, nint lParam)
    {
        if (nCode >= 0 && wParam == WM_KEYDOWN) _count++;
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private static int Main()
    {
        var proc = new HookProc(Callback);
        _hook = SetWindowsHookExW(WH_KEYBOARD_LL, proc, GetModuleHandleW(null), 0);
        GC.KeepAlive(proc);
        if (_hook == 0)
        {
            Console.WriteLine($"HOOK FAILED win32err={Marshal.GetLastWin32Error()}");
            return 1;
        }
        Console.WriteLine($"HOOK OK handle=0x{_hook:X}");

        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 4000)
        {
            // 低层钩子需要消息泵才能派发
            while (PeekMessageW(out var msg, 0, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
            Thread.Sleep(10);
        }
        Console.WriteLine($"keydown seen = {_count}");
        UnhookWindowsHookEx(_hook);
        return 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public nint hwnd; public uint message; public nint wParam, lParam; public uint time; public int ptX, ptY; }

    [DllImport("user32.dll")] private static extern bool PeekMessageW(out MSG m, nint h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] private static extern nint DispatchMessageW(ref MSG m);
}
