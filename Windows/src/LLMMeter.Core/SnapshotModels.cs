using System.Text.Json;
using System.Text.Json.Serialization;

namespace LLMMeter.Core;

public enum AccountState
{
    Fresh,
    Stale,
    AuthRequired,
    RateLimited,
    Unsupported,
    NoData
}

public sealed record MetricSnapshot(
    string Key,
    string Label,
    string Value,
    string? Limit = null,
    double? Ratio = null,
    string? Unit = null,
    string? ResetText = null
);

public sealed record AccountSnapshot(
    string AccountId,
    string Provider,
    string Surface,
    string Label,
    bool IsEnabled,
    string? Identity,
    AccountState State,
    IReadOnlyList<MetricSnapshot> Metrics
);

public sealed record SharedSnapshot(
    int SchemaVersion,
    DateTimeOffset GeneratedAt,
    IReadOnlyList<AccountSnapshot> Accounts
)
{
    public const int CurrentSchemaVersion = 1;

    public void Validate()
    {
        if (SchemaVersion != CurrentSchemaVersion)
        {
            throw new InvalidDataException(
                $"Unsupported snapshot schema version: {SchemaVersion}.");
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var account in Accounts)
        {
            if (string.IsNullOrWhiteSpace(account.AccountId))
            {
                throw new InvalidDataException("Account IDs must not be empty.");
            }

            if (!ids.Add(account.AccountId))
            {
                throw new InvalidDataException(
                    $"Duplicate account ID: {account.AccountId}.");
            }
        }
    }

    public static SharedSnapshot Empty(DateTimeOffset? generatedAt = null) =>
        new(CurrentSchemaVersion, generatedAt ?? DateTimeOffset.UtcNow, []);
}

public static class SnapshotJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
}
