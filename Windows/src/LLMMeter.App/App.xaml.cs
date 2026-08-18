using Microsoft.UI.Xaml;

namespace LLMMeter.App;

public partial class App : Application
{
    public static Window? MainWindowInstance { get; private set; }
    private TrayIconController? trayIcon;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindowInstance = new MainWindow();
        MainWindowInstance.Closed += MainWindow_Closed;
        trayIcon = new TrayIconController(
            ToggleMainWindow,
            ExitApplication);
        MainWindowInstance.Activate();
        MainWindowInstance.HideToTray();
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
        trayIcon?.Dispose();
        trayIcon = null;
        MainWindowInstance = null;
    }
}
