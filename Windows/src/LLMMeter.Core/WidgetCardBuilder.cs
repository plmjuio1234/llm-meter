using System.Text.Json;
using System.Text.Json.Nodes;

namespace LLMMeter.Core;

public enum WidgetSize
{
    Small,
    Medium,
    Large
}

public static class WidgetCardBuilder
{
    public static string Build(SharedSnapshot snapshot, WidgetSize size)
    {
        snapshot.Validate();

        var accountLimit = size switch
        {
            WidgetSize.Small => 1,
            WidgetSize.Medium => 3,
            WidgetSize.Large => 6,
            _ => 3
        };

        var body = new JsonArray
        {
            Header(),
            new JsonObject
            {
                ["type"] = "Container",
                ["style"] = "default",
                ["items"] = Accounts(snapshot.Accounts.Take(accountLimit).ToArray())
            }
        };

        if (snapshot.Accounts.Count > accountLimit)
        {
            body.Add(new JsonObject
            {
                ["type"] = "TextBlock",
                ["text"] = $"+{snapshot.Accounts.Count - accountLimit} more accounts",
                ["size"] = "Small",
                ["color"] = "Light",
                ["spacing"] = "Small",
                ["horizontalAlignment"] = "Right"
            });
        }

        var document = new JsonObject
        {
            ["$schema"] = "http://adaptivecards.io/schemas/adaptive-card.json",
            ["type"] = "AdaptiveCard",
            ["version"] = "1.5",
            ["body"] = body
        };

        return document.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        });
    }

    private static JsonObject Header() =>
        new()
        {
            ["type"] = "TextBlock",
            ["text"] = "LLM Meter",
            ["weight"] = "Bolder",
            ["size"] = "Large",
            ["color"] = "Light",
            ["wrap"] = true
        };

    private static JsonArray Accounts(IReadOnlyList<AccountSnapshot> accounts)
    {
        var items = new JsonArray();
        foreach (var account in accounts)
        {
            var status = account.State switch
            {
                AccountState.Fresh => "Fresh",
                AccountState.Stale => "Stale",
                AccountState.AuthRequired => "Sign in required",
                AccountState.RateLimited => "Rate limited",
                AccountState.Unsupported => "Unsupported",
                _ => "No data"
            };

            var metricText = account.Metrics.Count == 0
                ? status
                : string.Join(
                    "  ·  ",
                    account.Metrics.Take(2).Select(metric =>
                        metric.Limit is null
                            ? $"{metric.Label}: {metric.Value}"
                            : $"{metric.Label}: {metric.Value}/{metric.Limit}"));

            items.Add(new JsonObject
            {
                ["type"] = "Container",
                ["style"] = "emphasis",
                ["spacing"] = "Medium",
                ["items"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["type"] = "TextBlock",
                        ["text"] = account.Label,
                        ["weight"] = "Bolder",
                        ["color"] = "Light",
                        ["wrap"] = true
                    },
                    new JsonObject
                    {
                        ["type"] = "TextBlock",
                        ["text"] = $"{account.Provider}  ·  {status}",
                        ["size"] = "Small",
                        ["color"] = "Accent",
                        ["wrap"] = true
                    },
                    new JsonObject
                    {
                        ["type"] = "TextBlock",
                        ["text"] = metricText,
                        ["size"] = "Small",
                        ["color"] = "Light",
                        ["wrap"] = true,
                        ["spacing"] = "Small"
                    }
                }
            });
        }

        return items;
    }
}
