using System.Collections.ObjectModel;
using System.ComponentModel;
using LLMMeter.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LLMMeter.App;

public sealed partial class MainWindow : Window
{
    public DashboardViewModel ViewModel { get; } = new();

    public MainWindow()
    {
        InitializeComponent();
        ContentRoot.DataContext = ViewModel;
        Loaded += async (_, _) => await ViewModel.LoadAsync();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.LoadAsync();
    }

    private void OpenDetails_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: AccountCardViewModel account })
        {
            new DetailWindow(account).Activate();
        }
    }
}

public sealed class DashboardViewModel : INotifyPropertyChanged
{
    public ObservableCollection<AccountCardViewModel> Accounts { get; } = [];
    private string statusText = "Loading account snapshot...";
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
            var path = Path.Combine(
                AppContext.BaseDirectory,
                "Assets",
                "usage-snapshot.json");
            var snapshot = await SnapshotStore.LoadAsync(path);
            var sharedPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LLMMeter",
                "usage-snapshot.json");
            await SnapshotStore.SaveAsync(sharedPath, snapshot);

            Accounts.Clear();
            foreach (var account in snapshot.Accounts.Where(account => account.IsEnabled))
            {
                Accounts.Add(new AccountCardViewModel(account));
            }

            StatusText = $"{Accounts.Count} accounts connected";
            LastUpdatedText = $"Updated {snapshot.GeneratedAt.LocalDateTime:g}";
        }
        catch (Exception error)
        {
            Accounts.Clear();
            StatusText = $"Snapshot unavailable: {error.Message}";
            LastUpdatedText = "No data";
        }
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
            AccountState.RateLimited => "Rate limited",
            AccountState.Unsupported => "Unsupported",
            _ => "No data"
        };
        StateBackground = new SolidColorBrush(account.State switch
        {
            AccountState.Fresh => ColorHelper.FromArgb(0xFF, 0x1D, 0x6B, 0x5B),
            AccountState.Stale => ColorHelper.FromArgb(0xFF, 0x7A, 0x56, 0x1A),
            AccountState.Unsupported or AccountState.AuthRequired =>
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
