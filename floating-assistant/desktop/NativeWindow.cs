using System;
using System.Runtime.InteropServices;

internal static class NativeWindow
{
    private const int ExtendedStyle = -20;
    private const int ToolWindow = 0x80;
    private const int AppWindow = 0x40000;
    private const uint NoSize = 0x01, NoMove = 0x02, NoZOrder = 0x04, NoActivate = 0x10, FrameChanged = 0x20;

    internal static void MakeToolWindow(IntPtr hwnd)
    {
        int style = GetWindowLong(hwnd, ExtendedStyle);
        int toolStyle = (style | ToolWindow) & ~AppWindow;
        if (toolStyle == style) return;
        SetWindowLong(hwnd, ExtendedStyle, toolStyle);
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, NoSize | NoMove | NoZOrder | NoActivate | FrameChanged);
    }

    internal static void Move(IntPtr hwnd, int x, int y)
    {
        SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, NoSize | NoZOrder | NoActivate);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect { internal int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] private static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] internal static extern int DwmFlush();
}
