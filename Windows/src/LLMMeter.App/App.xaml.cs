using Microsoft.UI.Xaml;

namespace LLMMeter.App;

public partial class App : Application
{
    public static MainWindow? MainWindowInstance { get; private set; }
    private TrayIconController? trayIcon;

    public App()
    {
        InitializeComponent();
        StartupDiagnostics.Write("App constructed.");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        StartupDiagnostics.Write("OnLaunched started.");
        MainWindowInstance = new MainWindow();
        MainWindowInstance.Closed += MainWindow_Closed;
        MainWindowInstance.Activate();
        StartupDiagnostics.Write(
            $"Main window activated. HWND=0x{MainWindowInstance.WindowHandle.ToInt64():X}.");

        try
        {
            trayIcon = new TrayIconController(
                MainWindowInstance.WindowHandle,
                ToggleMainWindow,
                ExitApplication);
            MainWindowInstance.HideToTray();
            StartupDiagnostics.Write("Notification-area icon installed.");
        }
        catch (Exception error)
        {
            StartupDiagnostics.Write("Notification-area icon installation failed.", error);
            MainWindowInstance.ShowFromTray();
        }
    }

    private void ToggleMainWindow()
    {
        if (MainWindowInstance is not { } window)
        {
            return;
        }

        window.DispatcherQueue.TryEnqueue(window.ToggleFromTray);
    }

    private void ExitApplication()
    {
        if (MainWindowInstance is not { } window)
        {
            return;
        }

        window.DispatcherQueue.TryEnqueue(() =>
        {
            trayIcon?.Dispose();
            trayIcon = null;
            window.Close();
        });
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        StartupDiagnostics.Write("Main window closed.");
        trayIcon?.Dispose();
        trayIcon = null;
        MainWindowInstance = null;
    }
}
