using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using LLMMeter.Core;
using Microsoft.Windows.Widgets.Providers;

namespace LLMMeter.WidgetProvider;

[ComDefaultInterface(typeof(IWidgetProvider))]
[Guid("A4A4E5EE-6DB8-4A4A-93D7-2B0AFA1E6B5B")]
public sealed class WidgetProvider : IWidgetProvider
{
    private const string ProviderClassId = "A4A4E5EE-6DB8-4A4A-93D7-2B0AFA1E6B5B";
    private readonly ConcurrentDictionary<string, WidgetContext> widgets = new();

    public static Guid ClassId => Guid.Parse(ProviderClassId);

    public void CreateWidget(WidgetContext widgetContext)
    {
        widgets[widgetContext.Id] = widgetContext;
        Update(widgetContext.Id);
    }

    public void DeleteWidget(string widgetId, string customState)
    {
        widgets.TryRemove(widgetId, out var removedContext);
    }

    public void OnActionInvoked(WidgetActionInvokedArgs actionInvokedArgs)
    {
        if (widgets.ContainsKey(actionInvokedArgs.WidgetContext.Id))
        {
            Update(actionInvokedArgs.WidgetContext.Id);
        }
    }

    public void OnWidgetContextChanged(WidgetContextChangedArgs contextChangedArgs)
    {
        widgets[contextChangedArgs.WidgetContext.Id] = contextChangedArgs.WidgetContext;
        Update(contextChangedArgs.WidgetContext.Id);
    }

    public void Activate(WidgetContext widgetContext)
    {
        widgets[widgetContext.Id] = widgetContext;
    }

    public void Deactivate(string widgetId)
    {
        widgets.TryRemove(widgetId, out _);
    }

    private static void Update(string widgetId)
    {
        var snapshot = LoadSnapshot();
        var options = new WidgetUpdateRequestOptions(widgetId)
        {
            Template = WidgetCardBuilder.Build(snapshot, WidgetSize.Medium),
            Data = "{}"
        };
        WidgetManager.GetDefault().UpdateWidget(options);
    }

    private static SharedSnapshot LoadSnapshot()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LLMMeter",
            "usage-snapshot.json");

        try
        {
            return SnapshotStore.LoadAsync(path).GetAwaiter().GetResult();
        }
        catch (Exception)
        {
            return SharedSnapshot.Empty();
        }
    }
}
