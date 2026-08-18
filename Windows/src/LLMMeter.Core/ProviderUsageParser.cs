using System.Globalization;
using System.Text.Json;

namespace LLMMeter.Core;

public static class ProviderUsageParser
{
    public static AccountSnapshot Parse(
        ConnectedProvider provider,
        WindowsAccountConnection account,
        string json,
        DateTimeOffset fetchedAt)
    {
        using var document = JsonDocument.Parse(json);
        var metrics = provider switch
        {
            ConnectedProvider.OpenAI => ParseOpenAI(document.RootElement, fetchedAt),
            ConnectedProvider.Anthropic => ParseAnthropic(document.RootElement, fetchedAt),
            _ => []
        };

        return new AccountSnapshot(
            account.AccountId,
            account.Provider,
            "OAuth",
            account.Label,
            account.IsEnabled,
            account.Identity,
            metrics.Count == 0 ? AccountState.NoData : AccountState.Fresh,
            metrics);
    }

    private static List<MetricSnapshot> ParseOpenAI(
        JsonElement root,
        DateTimeOffset fetchedAt)
    {
        var metrics = new List<MetricSnapshot>();
        if (TryGetObject(root, "rate_limit", out var rateLimit))
        {
            AddRateLimitMetrics(metrics, "openai.oauth.rate_limit", rateLimit, fetchedAt);
        }

        if (root.TryGetProperty("additional_rate_limits", out var additional) &&
            additional.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in additional.EnumerateArray())
            {
                var id = FirstString(entry, "id", "limit_name", "metered_feature")
                    ?? "additional";
                if (TryGetObject(entry, "rate_limit", out var nested))
                {
                    AddRateLimitMetrics(
                        metrics,
                        $"openai.oauth.rate_limit.{Slug(id)}",
                        nested,
                        fetchedAt);
                }
                else
                {
                    AddRateLimitMetrics(
                        metrics,
                        $"openai.oauth.rate_limit.{Slug(id)}",
                        entry,
                        fetchedAt);
                }
            }
        }

        if (TryGetObject(root, "code_review_rate_limit", out var codeReview))
        {
            AddRateLimitMetrics(metrics, "openai.oauth.code_review", codeReview, fetchedAt);
        }

        return metrics;
    }

    private static List<MetricSnapshot> ParseAnthropic(
        JsonElement root,
        DateTimeOffset fetchedAt)
    {
        var metrics = new List<MetricSnapshot>();
        AddAnthropicMetric(metrics, root, "five_hour", "anthropic.oauth.rate_limit.five_hour", fetchedAt);
        AddAnthropicMetric(metrics, root, "seven_day", "anthropic.oauth.rate_limit.seven_day", fetchedAt);
        AddAnthropicMetric(
            metrics,
            root,
            "seven_day_oauth_apps",
            "anthropic.oauth.rate_limit.seven_day_oauth_apps",
            fetchedAt);
        AddAnthropicMetric(
            metrics,
            root,
            "seven_day_opus",
            "anthropic.oauth.rate_limit.seven_day_opus",
            fetchedAt);
        AddAnthropicMetric(
            metrics,
            root,
            "seven_day_sonnet",
            "anthropic.oauth.rate_limit.seven_day_sonnet",
            fetchedAt);
        AddAnthropicMetric(
            metrics,
            root,
            "seven_day_routines",
            "anthropic.oauth.rate_limit.seven_day_routines",
            fetchedAt);

        if (root.TryGetProperty("limits", out var limits) &&
            limits.ValueKind == JsonValueKind.Array)
        {
            var index = 0;
            foreach (var limit in limits.EnumerateArray())
            {
                var percent = Number(limit, "percent");
                if (percent is null)
                {
                    index++;
                    continue;
                }

                AddMetric(
                    metrics,
                    $"anthropic.oauth.rate_limit.{Slug(FirstString(limit, "group", "kind") ?? $"scoped-{index}")}",
                    percent.Value / 100,
                    Date(limit, "resets_at"),
                    fetchedAt);
                index++;
            }
        }

        return metrics;
    }

    private static void AddRateLimitMetrics(
        ICollection<MetricSnapshot> metrics,
        string prefix,
        JsonElement rateLimit,
        DateTimeOffset fetchedAt)
    {
        AddOpenAIWindow(metrics, rateLimit, "primary_window", $"{prefix}.primary", fetchedAt);
        AddOpenAIWindow(metrics, rateLimit, "secondary_window", $"{prefix}.secondary", fetchedAt);
    }

    private static void AddOpenAIWindow(
        ICollection<MetricSnapshot> metrics,
        JsonElement rateLimit,
        string property,
        string key,
        DateTimeOffset fetchedAt)
    {
        if (!TryGetObject(rateLimit, property, out var window))
        {
            return;
        }

        var percent = Number(window, "used_percent");
        if (percent is null)
        {
            return;
        }

        AddMetric(metrics, key, percent.Value / 100, Date(window, "reset_at"), fetchedAt);
    }

    private static void AddAnthropicMetric(
        ICollection<MetricSnapshot> metrics,
        JsonElement root,
        string property,
        string key,
        DateTimeOffset fetchedAt)
    {
        if (!TryGetObject(root, property, out var window))
        {
            return;
        }

        var utilization = Number(window, "utilization");
        if (utilization is null)
        {
            return;
        }

        var ratio = utilization.Value > 1 ? utilization.Value / 100 : utilization.Value;
        AddMetric(metrics, key, ratio, Date(window, "resets_at"), fetchedAt);
    }

    private static void AddMetric(
        ICollection<MetricSnapshot> metrics,
        string key,
        double ratio,
        DateTimeOffset? resetAt,
        DateTimeOffset fetchedAt)
    {
        metrics.Add(new MetricSnapshot(
            key,
            key[(key.LastIndexOf('.') + 1)..].Replace('_', ' '),
            $"{FormatPercent(ratio)}%",
            "100%",
            ratio,
            "percent",
            FormatReset(resetAt, fetchedAt)));
    }

    private static bool TryGetObject(
        JsonElement parent,
        string property,
        out JsonElement value)
    {
        if (parent.TryGetProperty(property, out value) &&
            value.ValueKind == JsonValueKind.Object)
        {
            return true;
        }

        value = default;
        return false;
    }

    private static double? Number(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
        {
            return number;
        }

        if (value.ValueKind == JsonValueKind.String &&
            double.TryParse(
                value.GetString(),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out number))
        {
            return number;
        }

        return null;
    }

    private static DateTimeOffset? Date(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number &&
            value.TryGetDouble(out var seconds))
        {
            return DateTimeOffset.FromUnixTimeSeconds((long)seconds);
        }

        if (value.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(
                value.GetString(),
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal,
                out var parsed))
        {
            return parsed;
        }

        return null;
    }

    private static string? FirstString(JsonElement parent, params string[] properties)
    {
        foreach (var property in properties)
        {
            if (parent.TryGetProperty(property, out var value) &&
                value.ValueKind == JsonValueKind.String &&
                !string.IsNullOrWhiteSpace(value.GetString()))
            {
                return value.GetString();
            }
        }

        return null;
    }

    private static string Slug(string value)
    {
        var chars = value
            .ToLowerInvariant()
            .Select(character => char.IsLetterOrDigit(character) ? character : '-')
            .ToArray();
        return new string(chars);
    }

    private static string FormatPercent(double ratio)
    {
        return (ratio * 100).ToString("0.##", CultureInfo.InvariantCulture);
    }

    private static string? FormatReset(DateTimeOffset? resetAt, DateTimeOffset fetchedAt)
    {
        if (resetAt is null)
        {
            return null;
        }

        var local = resetAt.Value.ToLocalTime();
        return $"Resets {local:g}";
    }
}
