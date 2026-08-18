using System.Text.Json;
using LLMMeter.Core;

var fixturePath = Path.GetFullPath(
    Path.Combine(
        AppContext.BaseDirectory,
        "../../../../../src/LLMMeter.App/Assets/usage-snapshot.json"));
var snapshot = await SnapshotStore.LoadAsync(fixturePath);
var payload = WidgetCardBuilder.Build(snapshot, WidgetSize.Medium);

using var document = JsonDocument.Parse(payload);
var root = document.RootElement;
if (root.GetProperty("type").GetString() != "AdaptiveCard")
{
    throw new InvalidDataException("Widget payload is not an Adaptive Card.");
}

Console.WriteLine(payload);
