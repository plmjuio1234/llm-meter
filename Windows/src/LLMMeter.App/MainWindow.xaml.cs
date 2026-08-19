using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.InteropServices;
using LLMMeter.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;

namespace LLMMeter.App;

public sealed partial class MainWindow : Window
{
    public DashboardViewModel ViewModel { get; } = new();
    public new DispatcherQueue DispatcherQueue => ContentRoot.DispatcherQueue;
    internal IntPtr WindowHandle => WindowNative.GetWindowHandle(this);

    public MainWindow()
    {
        InitializeComponent();
        ContentRoot.DataContext = ViewModel;
        _ = ViewModel.LoadAsync();
    }

    public void ToggleFromTray()
    {
        if (NativeMethods.IsWindowVisible(WindowHandle))
        {
            HideToTray();
        }
        else
        {
            ShowFromTray();
        }
    }

    public void ShowFromTray()
    {
        var handle = WindowHandle;
        NativeMethods.ShowWindow(handle, NativeMethods.SW_RESTORE);
        Activate();
        NativeMethods.SetForegroundWindow(handle);
    }

    public void HideToTray()
    {
        NativeMethods.ShowWindow(WindowHandle, NativeMethods.SW_HIDE);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.RefreshAsync();
    }

    private async void ConnectOpenAI_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.ConnectAsync(ConnectedProvider.OpenAI);
    }

    private async void ConnectAnthropic_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.ConnectAsync(ConnectedProvider.Anthropic);
    }

    private void OpenDetails_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: AccountCardViewModel account })
        {
            new DetailWindow(account).Activate();
        }
    }
}

internal static class NativeMethods
{
    internal const int SW_HIDE = 0;
    internal const int SW_RESTORE = 9;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(IntPtr hWnd);
}

public sealed class DashboardViewModel : INotifyPropertyChanged
{
    public ObservableCollection<AccountCardViewModel> Accounts { get; } = [];
    private readonly ProviderConnectionService connectionService = new();
    private string statusText = "No accounts connected";
    private string lastUpdatedText = "Not loaded";

    public string StatusText
    {
        get => statusText;
        private set
        {
            if (statusText == value)
            {
                return;
            }

            statusText = value;
            PropertyChanged?.Invoke(this, new(nameof(StatusText)));
        }
    }

    public string LastUpdatedText
    {
        get => lastUpdatedText;
        private set
        {
            if (lastUpdatedText == value)
            {
                return;
            }

            lastUpdatedText = value;
            PropertyChanged?.Invoke(this, new(nameof(LastUpdatedText)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public async Task LoadAsync()
    {
        try
        {
            var snapshot = await connectionService.LoadSnapshotAsync();
            ApplySnapshot(snapshot);
            if (snapshot.Accounts.Count > 0)
            {
                ApplySnapshot(await connectionService.RefreshAsync());
            }
        }
        catch (Exception error)
        {
            Accounts.Clear();
            StatusText = $"Snapshot unavailable: {error.Message}";
            LastUpdatedText = "No data";
        }
    }

    public async Task RefreshAsync()
    {
        try
        {
            ApplySnapshot(await connectionService.RefreshAsync());
        }
        catch
        {
            StatusText = "Refresh could not be completed.";
        }
    }

    public async Task ConnectAsync(ConnectedProvider provider)
    {
        StatusText = $"Connect {provider} in your browser...";
        try
        {
            ApplySnapshot(await connectionService.ConnectAsync(provider));
        }
        catch (OperationCanceledException)
        {
            StatusText = "Account connection timed out or was cancelled.";
        }
        catch
        {
            StatusText = "Account connection could not be completed.";
        }
    }

    private void ApplySnapshot(SharedSnapshot snapshot)
    {
        Accounts.Clear();
        foreach (var account in snapshot.Accounts.Where(account => account.IsEnabled))
        {
            Accounts.Add(new AccountCardViewModel(account));
        }

        StatusText = Accounts.Count == 0
            ? "No accounts connected"
            : $"{Accounts.Count} accounts connected";
        LastUpdatedText = snapshot.Accounts.Count == 0
            ? "Not loaded"
            : $"Updated {snapshot.GeneratedAt.LocalDateTime:g}";
    }
}

public sealed class AccountCardViewModel
{
    public string AccountId { get; }
    public string Label { get; }
    public string ProviderLine { get; }
    public string StateLabel { get; }
    public Brush StateBackground { get; }
    public ObservableCollection<MetricRowViewModel> Metrics { get; }
    public string EmptyMetricsText { get; }
    public Visibility EmptyMetricsVisibility =>
        Metrics.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public AccountCardViewModel(AccountSnapshot account)
    {
        AccountId = account.AccountId;
        Label = account.Label;
        ProviderLine = $"{account.Provider}  ·  {account.Surface}";
        StateLabel = account.State switch
        {
            AccountState.Fresh => "Fresh",
            AccountState.Stale => "Stale",
            AccountState.AuthRequired => "Sign in required",
            AccountState.PermissionDenied => "Permission denied",
            AccountState.RateLimited => "Rate limited",
            AccountState.Unsupported => "Unsupported",
            _ => "No data"
        };
        StateBackground = new SolidColorBrush(account.State switch
        {
            AccountState.Fresh => ColorHelper.FromArgb(0xFF, 0x1D, 0x6B, 0x5B),
            AccountState.Stale => ColorHelper.FromArgb(0xFF, 0x7A, 0x56, 0x1A),
            AccountState.Unsupported or
            AccountState.AuthRequired or
            AccountState.PermissionDenied =>
                ColorHelper.FromArgb(0xFF, 0x6F, 0x32, 0x58),
            _ => ColorHelper.FromArgb(0xFF, 0x55, 0x36, 0x36)
        });
        Metrics = new ObservableCollection<MetricRowViewModel>(
            account.Metrics.Select(metric => new MetricRowViewModel(metric)));
        EmptyMetricsText = StateLabel == "Unsupported"
            ? "This provider has no official account-wide usage endpoint."
            : "No usage values are available yet.";
    }
}

public sealed class MetricRowViewModel
{
    public string Label { get; }
    public string ValueLine { get; }
    public double Ratio { get; }
    public string ResetText { get; }

    public MetricRowViewModel(MetricSnapshot metric)
    {
        Label = metric.Label;
        ValueLine = metric.Limit is null
            ? metric.Value
            : $"{metric.Value} / {metric.Limit}";
        Ratio = Math.Clamp(metric.Ratio ?? 0, 0, 1);
        ResetText = metric.ResetText ?? string.Empty;
    }
}
