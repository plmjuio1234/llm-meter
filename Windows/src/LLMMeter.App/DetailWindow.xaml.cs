using Microsoft.UI.Xaml;

namespace LLMMeter.App;

public sealed partial class DetailWindow : Window
{
    public DetailWindow(AccountCardViewModel account)
    {
        InitializeComponent();
        ContentRoot.DataContext = account;
    }
}
