using System.Runtime.InteropServices;

namespace LLMMeter.App;

internal sealed class TrayIconController : IDisposable
{
    private const int GWLP_WNDPROC = -4;
    private const int WM_APP = 0x8000;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_NULL = 0x0000;
    private const uint NIF_MESSAGE = 0x00000001;
    private const uint NIF_ICON = 0x00000002;
    private const uint NIF_TIP = 0x00000004;
    private const uint NIM_ADD = 0x00000000;
    private const uint NIM_DELETE = 0x00000002;
    private const uint NIM_SETVERSION = 0x00000004;
    private const uint NOTIFYICON_VERSION_4 = 4;
    private const uint TPM_NONOTIFY = 0x0080;
    private const uint TPM_RETURNCMD = 0x0100;
    private const uint MF_SEPARATOR = 0x00000800;
    private const uint MF_STRING = 0x00000000;
    private const uint OPEN_COMMAND = 1;
    private const uint EXIT_COMMAND = 2;
    private const int IDI_APPLICATION = 32512;

    private readonly IntPtr windowHandle;
    private readonly Action toggleWindow;
    private readonly Action exitApplication;
    private readonly WndProcDelegate wndProc;
    private readonly IntPtr previousWndProc;
    private bool disposed;

    public TrayIconController(
        IntPtr windowHandle,
        Action toggleWindow,
        Action exitApplication)
    {
        this.windowHandle = windowHandle;
        this.toggleWindow = toggleWindow;
        this.exitApplication = exitApplication;
        wndProc = WindowProcedure;
        previousWndProc = NativeMethods.SetWindowLongPtr(
            windowHandle,
            GWLP_WNDPROC,
            Marshal.GetFunctionPointerForDelegate(wndProc));

        if (previousWndProc == IntPtr.Zero)
        {
            throw new InvalidOperationException("Unable to attach the tray message handler.");
        }

        var data = CreateNotifyIconData(NIF_MESSAGE | NIF_ICON | NIF_TIP);
        if (!NativeMethods.Shell_NotifyIcon(NIM_ADD, ref data))
        {
            RestoreWindowProcedure();
            throw new InvalidOperationException("Unable to create the notification-area icon.");
        }

        data.uVersion = NOTIFYICON_VERSION_4;
        NativeMethods.Shell_NotifyIcon(NIM_SETVERSION, ref data);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        var data = CreateNotifyIconData(0);
        NativeMethods.Shell_NotifyIcon(NIM_DELETE, ref data);
        RestoreWindowProcedure();
    }

    private IntPtr WindowProcedure(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam)
    {
        if (!disposed && message == WM_APP)
        {
            var mouseMessage = unchecked((int)lParam.ToInt64());
            if (mouseMessage == WM_LBUTTONUP)
            {
                toggleWindow();
            }
            else if (mouseMessage == WM_RBUTTONUP)
            {
                ShowContextMenu();
            }
        }

        return NativeMethods.CallWindowProc(
            previousWndProc,
            hwnd,
            message,
            wParam,
            lParam);
    }

    private void ShowContextMenu()
    {
        var menu = NativeMethods.CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            return;
        }

        try
        {
            NativeMethods.AppendMenu(menu, MF_STRING, OPEN_COMMAND, "Open LLM Meter");
            NativeMethods.AppendMenu(menu, MF_SEPARATOR, 0, string.Empty);
            NativeMethods.AppendMenu(menu, MF_STRING, EXIT_COMMAND, "Exit");
            NativeMethods.GetCursorPos(out var cursor);
            NativeMethods.SetForegroundWindow(windowHandle);
            var command = NativeMethods.TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_NONOTIFY,
                cursor.X,
                cursor.Y,
                0,
                windowHandle,
                IntPtr.Zero);
            NativeMethods.PostMessage(windowHandle, WM_NULL, IntPtr.Zero, IntPtr.Zero);

            switch (command)
            {
                case OPEN_COMMAND:
                    toggleWindow();
                    break;
                case EXIT_COMMAND:
                    exitApplication();
                    break;
            }
        }
        finally
        {
            NativeMethods.DestroyMenu(menu);
        }
    }

    private NotifyIconData CreateNotifyIconData(uint flags) =>
        new()
        {
            cbSize = (uint)Marshal.SizeOf<NotifyIconData>(),
            hWnd = windowHandle,
            uID = 1,
            uFlags = flags,
            uCallbackMessage = WM_APP,
            hIcon = NativeMethods.LoadIcon(
                IntPtr.Zero,
                (IntPtr)IDI_APPLICATION),
            szTip = "LLM Meter",
            szInfo = string.Empty,
            szInfoTitle = string.Empty
        };

    private void RestoreWindowProcedure()
    {
        if (previousWndProc != IntPtr.Zero)
        {
            NativeMethods.SetWindowLongPtr(
                windowHandle,
                GWLP_WNDPROC,
                previousWndProc);
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WndProcDelegate(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    private static class NativeMethods
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool Shell_NotifyIcon(
            uint message,
            ref NotifyIconData data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr SetWindowLongPtr(
            IntPtr hWnd,
            int nIndex,
            IntPtr newLong);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr CallWindowProc(
            IntPtr previousWndProc,
            IntPtr hWnd,
            uint message,
            IntPtr wParam,
            IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr LoadIcon(
            IntPtr hInstance,
            IntPtr lpIconName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr CreatePopupMenu();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AppendMenu(
            IntPtr menu,
            uint flags,
            uint newItem,
            string newItemText);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern int TrackPopupMenu(
            IntPtr menu,
            uint flags,
            int x,
            int y,
            int reserved,
            IntPtr owner,
            IntPtr reservedRect);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DestroyMenu(IntPtr menu);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool PostMessage(
            IntPtr hWnd,
            uint message,
            IntPtr wParam,
            IntPtr lParam);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }
}
