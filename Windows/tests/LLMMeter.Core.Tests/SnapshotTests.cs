using System.Text.Json;
using LLMMeter.Core;
using Xunit;

namespace LLMMeter.Core.Tests;

public sealed class SnapshotTests
{
    [Fact]
    public void SnapshotRoundTripsAndRejectsDuplicateAccounts()
    {
        var snapshot = new SharedSnapshot(
            SharedSnapshot.CurrentSchemaVersion,
            DateTimeOffset.Parse("2026-01-01T00:00:00Z"),
            [
                new AccountSnapshot(
                    "openai-main",
                    "OpenAI",
                    "OAuth",
                    "Personal",
                    true,
                    "user@example.com",
                    AccountState.Fresh,
                    [new MetricSnapshot("weekly", "Weekly", "42%", "100%", 0.42)])
            ]);

        snapshot.Validate();
        var json = JsonSerializer.Serialize(snapshot, SnapshotJson.Options);
        var decoded = JsonSerializer.Deserialize<SharedSnapshot>(
            json,
            SnapshotJson.Options);

        Assert.NotNull(decoded);
        Assert.Equal("openai-main", decoded!.Accounts.Single().AccountId);

        var duplicate = snapshot with
        {
            Accounts =
            [
                snapshot.Accounts[0],
                snapshot.Accounts[0] with { Label = "Duplicate" }
            ]
        };

        Assert.Throws<InvalidDataException>(() => duplicate.Validate());
    }

    [Fact]
    public void SnapshotSerializationContainsSafePayload()
    {
        var snapshot = new SharedSnapshot(
            SharedSnapshot.CurrentSchemaVersion,
            DateTimeOffset.UtcNow,
            [
                new AccountSnapshot(
                    "anthropic-main",
                    "Anthropic",
                    "OAuth",
                    "Claude",
                    true,
                    null,
                    AccountState.Stale,
                    [new MetricSnapshot("monthly", "Monthly", "68%", "100%", 0.68)])
            ]);

        var json = JsonSerializer.Serialize(snapshot, SnapshotJson.Options);
        using var document = JsonDocument.Parse(json);

        Assert.Equal(
            "anthropic-main",
            document.RootElement.GetProperty("accounts")[0].GetProperty("accountId").GetString());
        Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Claude", json, StringComparison.Ordinal);
    }
}
