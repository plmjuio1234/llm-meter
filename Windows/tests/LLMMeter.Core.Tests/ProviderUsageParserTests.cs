using LLMMeter.Core;
using Xunit;

namespace LLMMeter.Core.Tests;

public sealed class ProviderUsageParserTests
{
    private static readonly WindowsAccountConnection Account = new(
        "account-1",
        "OpenAI",
        "OpenAI / Personal",
        "person@example.com",
        "credential-1");

    [Fact]
    public void OpenAiUsageResponseProducesQuotaMetrics()
    {
        const string json = """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 42,
                  "limit_window_seconds": 604800,
                  "reset_at": 1760000000
                }
              }
            }
            """;

        var snapshot = ProviderUsageParser.Parse(
            ConnectedProvider.OpenAI,
            Account,
            json,
            DateTimeOffset.Parse("2026-01-01T00:00:00Z"));

        var metric = Assert.Single(snapshot.Metrics);
        Assert.Equal("openai.oauth.rate_limit.primary", metric.Key);
        Assert.Equal("42%", metric.Value);
        Assert.Equal(0.42, metric.Ratio);
        Assert.Equal(AccountState.Fresh, snapshot.State);
    }

    [Fact]
    public void AnthropicUsageResponseProducesFiveHourMetric()
    {
        const string json = """
            {
              "five_hour": {
                "utilization": 0.68,
                "resets_at": "2026-01-01T05:00:00Z"
              }
            }
            """;

        var snapshot = ProviderUsageParser.Parse(
            ConnectedProvider.Anthropic,
            Account with
            {
                Provider = "Anthropic",
                Label = "Claude / Work"
            },
            json,
            DateTimeOffset.Parse("2026-01-01T00:00:00Z"));

        var metric = Assert.Single(snapshot.Metrics);
        Assert.Equal("anthropic.oauth.rate_limit.five_hour", metric.Key);
        Assert.Equal("68%", metric.Value);
        Assert.Equal(0.68, metric.Ratio);
    }

    [Fact]
    public void PkceUsesIndependentVerifierAndStateValues()
    {
        var verifier = Pkce.GenerateVerifier();
        var state = Pkce.GenerateVerifier();

        Assert.NotEqual(verifier, state);
        Assert.NotEqual(verifier, Pkce.Challenge(verifier));
        Assert.DoesNotContain("+", Pkce.Challenge(verifier));
        Assert.DoesNotContain("/", Pkce.Challenge(verifier));
        Assert.DoesNotContain("=", Pkce.Challenge(verifier));
    }
}
