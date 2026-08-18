using System.Runtime.InteropServices;
using LLMMeter.WidgetProvider;
using Microsoft.Windows.Widgets.Providers;
using WidgetHelper;

namespace LLMMeter.WidgetProviderHost;

public static class Program
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [MTAThread]
    public static void Main(string[] args)
    {
        if (args.Length == 0 || args[0] != "-RegisterProcessAsComServer")
        {
            return;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        using var manager = RegistrationManager<WidgetProvider>.RegisterProvider();

        if (GetConsoleWindow() != IntPtr.Zero)
        {
            Console.WriteLine("LLM Meter widget provider registered.");
            Console.ReadLine();
            return;
        }

        using var disposedEvent = manager.GetDisposedEvent();
        disposedEvent.WaitOne();
    }
}
