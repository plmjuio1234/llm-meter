using System.Security.Cryptography;
using System.Text;

namespace LLMMeter.Core;

public enum ConnectedProvider
{
    OpenAI,
    Anthropic
}

public sealed record WindowsAccountConnection(
    string AccountId,
    string Provider,
    string Label,
    string? Identity,
    string CredentialReference,
    bool IsEnabled = true
);

public sealed record StoredOAuthCredential(
    string AccessToken,
    string? RefreshToken,
    DateTimeOffset? ExpiresAt,
    string? AccountId,
    string? Email
);

public sealed record OAuthTokenResponse(
    string AccessToken,
    string? RefreshToken,
    DateTimeOffset? ExpiresAt,
    string? IdToken
);

public static class Pkce
{
    public static string GenerateVerifier()
    {
        return Base64Url(RandomNumberGenerator.GetBytes(32));
    }

    public static string Challenge(string verifier)
    {
        return Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(verifier)));
    }

    private static string Base64Url(byte[] bytes)
    {
        return Convert.ToBase64String(bytes)
            .Replace("+", "-", StringComparison.Ordinal)
            .Replace("/", "_", StringComparison.Ordinal)
            .TrimEnd('=');
    }
}
