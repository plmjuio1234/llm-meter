using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;
using LLMMeter.Core;

namespace LLMMeter.App;

internal sealed class ProviderConnectionService
{
    private static readonly TimeSpan RefreshLeeway = TimeSpan.FromMinutes(5);
    private readonly HttpClient client;
    private readonly string rootDirectory;
    private readonly string accountsPath;
    private readonly string snapshotPath;
    private readonly WindowsCredentialStore credentials;

    public ProviderConnectionService()
    {
        rootDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LLMMeter");
        accountsPath = Path.Combine(rootDirectory, "accounts.json");
        snapshotPath = Path.Combine(rootDirectory, "usage-snapshot.json");
        credentials = new WindowsCredentialStore(rootDirectory);
        client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(30)
        };
    }

    public async Task<SharedSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(snapshotPath))
        {
            return SharedSnapshot.Empty();
        }

        return await SnapshotStore.LoadAsync(snapshotPath, cancellationToken);
    }

    public async Task<SharedSnapshot> RefreshAsync(
        CancellationToken cancellationToken = default)
    {
        var accounts = await LoadAccountsAsync(cancellationToken);
        var previous = await LoadSnapshotAsync(cancellationToken);
        if (accounts.Count == 0)
        {
            return SharedSnapshot.Empty();
        }

        var snapshots = new List<AccountSnapshot>();
        foreach (var account in accounts)
        {
            var oldSnapshot = previous.Accounts.FirstOrDefault(
                snapshot => snapshot.AccountId == account.AccountId);
            snapshots.Add(account.IsEnabled
                ? await RefreshAccountAsync(account, oldSnapshot, cancellationToken)
                : oldSnapshot ?? EmptySnapshot(account));
        }

        var snapshot = new SharedSnapshot(
            SharedSnapshot.CurrentSchemaVersion,
            DateTimeOffset.UtcNow,
            snapshots);
        await SnapshotStore.SaveAsync(snapshotPath, snapshot, cancellationToken);
        return snapshot;
    }

    public async Task<SharedSnapshot> ConnectAsync(
        ConnectedProvider provider,
        CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(3));

        var configuration = ProviderConfiguration.For(provider);
        var listener = OAuthLoopbackListener.Start(
            configuration.CallbackPath,
            configuration.FixedPort,
            configuration.CandidatePorts);
        await using (listener)
        {
            var verifier = Pkce.GenerateVerifier();
            var state = Pkce.GenerateVerifier();
            var redirectUri = $"http://localhost:{listener.Port}{configuration.CallbackPath}";
            var authorizationUri = BuildAuthorizationUri(
                configuration,
                redirectUri,
                verifier,
                state);

            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = authorizationUri.ToString(),
                    UseShellExecute = true
                });
            }
            catch
            {
                throw new InvalidOperationException(
                    "The default browser could not be opened.");
            }

            var callback = await listener.WaitForCallbackAsync(timeout.Token);
            if (!string.IsNullOrWhiteSpace(callback.Error))
            {
                throw new InvalidOperationException(
                    "The provider denied the account connection.");
            }
            if (!string.Equals(callback.State, state, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "The account connection state did not match.");
            }
            if (string.IsNullOrWhiteSpace(callback.Code))
            {
                throw new InvalidOperationException(
                    "The provider did not return an authorization code.");
            }

            var token = await ExchangeCodeAsync(
                configuration,
                callback.Code,
                verifier,
                redirectUri,
                timeout.Token);
            var claims = ReadClaims(token.IdToken ?? token.AccessToken);
            var localAccountID = Guid.NewGuid().ToString("N");
            var credentialReference = Guid.NewGuid().ToString("N");
            var account = new WindowsAccountConnection(
                localAccountID,
                configuration.DisplayName,
                claims.Email ?? $"{configuration.DisplayName} OAuth",
                claims.Email,
                credentialReference);
            var credential = new StoredOAuthCredential(
                token.AccessToken,
                token.RefreshToken,
                token.ExpiresAt,
                claims.AccountID,
                claims.Email);

            await credentials.SaveAsync(
                credentialReference,
                credential,
                timeout.Token);
            var accounts = await LoadAccountsAsync(timeout.Token);
            await SaveAccountsAsync(
                accounts.Append(account),
                timeout.Token);
        }

        return await RefreshAsync(cancellationToken);
    }

    private async Task<AccountSnapshot> RefreshAccountAsync(
        WindowsAccountConnection account,
        AccountSnapshot? previous,
        CancellationToken cancellationToken)
    {
        if (!TryParseProvider(account.Provider, out _))
        {
            return FailureSnapshot(account, previous, AccountState.Unsupported);
        }

        StoredOAuthCredential credential;
        try
        {
            credential = await credentials.LoadAsync(
                account.CredentialReference,
                cancellationToken);
        }
        catch
        {
            return FailureSnapshot(account, previous, AccountState.AuthRequired);
        }

        try
        {
            if (NeedsRefresh(credential))
            {
                credential = await RefreshTokenAsync(
                    account,
                    credential,
                    cancellationToken);
                await credentials.SaveAsync(
                    account.CredentialReference,
                    credential,
                    cancellationToken);
            }

            var result = await FetchUsageAsync(account, credential, cancellationToken);
            if (result.State == AccountState.AuthRequired &&
                !string.IsNullOrWhiteSpace(credential.RefreshToken))
            {
                credential = await RefreshTokenAsync(
                    account,
                    credential,
                    cancellationToken);
                await credentials.SaveAsync(
                    account.CredentialReference,
                    credential,
                    cancellationToken);
                result = await FetchUsageAsync(account, credential, cancellationToken);
            }

            return result.Snapshot ??
                FailureSnapshot(account, previous, result.State);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return FailureSnapshot(account, previous, AccountState.NoData);
        }
        catch (HttpRequestException)
        {
            return FailureSnapshot(account, previous, AccountState.NoData);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return FailureSnapshot(account, previous, AccountState.AuthRequired);
        }
    }

    private async Task<FetchResult> FetchUsageAsync(
        WindowsAccountConnection account,
        StoredOAuthCredential credential,
        CancellationToken cancellationToken)
    {
        if (!TryParseProvider(account.Provider, out var provider))
        {
            return new FetchResult(null, AccountState.Unsupported);
        }
        var configuration = ProviderConfiguration.For(provider);
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            configuration.UsageUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            credential.AccessToken);
        request.Headers.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.UserAgent.ParseAdd("LLMMeter/1.0");
        if (provider == ConnectedProvider.OpenAI &&
            !string.IsNullOrWhiteSpace(credential.AccountId))
        {
            request.Headers.TryAddWithoutValidation(
                "ChatGPT-Account-Id",
                credential.AccountId);
        }
        if (provider == ConnectedProvider.Anthropic)
        {
            request.Headers.TryAddWithoutValidation(
                "anthropic-beta",
                "oauth-2025-04-20");
        }

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            return new FetchResult(
                null,
                response.StatusCode switch
                {
                    System.Net.HttpStatusCode.Unauthorized => AccountState.AuthRequired,
                    System.Net.HttpStatusCode.Forbidden => AccountState.PermissionDenied,
                    System.Net.HttpStatusCode.TooManyRequests => AccountState.RateLimited,
                    _ => AccountState.NoData
                });
        }

        try
        {
            return new FetchResult(
                ProviderUsageParser.Parse(
                    provider,
                    account,
                    body,
                    DateTimeOffset.UtcNow),
                AccountState.Fresh);
        }
        catch (JsonException)
        {
            return new FetchResult(null, AccountState.NoData);
        }
        catch (InvalidDataException)
        {
            return new FetchResult(null, AccountState.NoData);
        }
    }

    private async Task<StoredOAuthCredential> RefreshTokenAsync(
        WindowsAccountConnection account,
        StoredOAuthCredential credential,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(credential.RefreshToken))
        {
            throw new InvalidOperationException("A refresh token is unavailable.");
        }

        var token = await RequestTokenAsync(
            ProviderConfiguration.For(
                TryParseProvider(account.Provider, out var provider)
                    ? provider
                    : throw new InvalidOperationException("Unsupported provider.")),
            new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = credential.RefreshToken
            },
            cancellationToken);
        return new StoredOAuthCredential(
            token.AccessToken,
            token.RefreshToken ?? credential.RefreshToken,
            token.ExpiresAt,
            credential.AccountId,
            credential.Email);
    }

    private async Task<OAuthTokenResponse> ExchangeCodeAsync(
        ProviderConfiguration configuration,
        string code,
        string verifier,
        string redirectUri,
        CancellationToken cancellationToken)
    {
        return await RequestTokenAsync(
            configuration,
            new Dictionary<string, string>
            {
                ["grant_type"] = "authorization_code",
                ["code"] = code,
                ["code_verifier"] = verifier,
                ["redirect_uri"] = redirectUri
            },
            cancellationToken);
    }

    private async Task<OAuthTokenResponse> RequestTokenAsync(
        ProviderConfiguration configuration,
        Dictionary<string, string> fields,
        CancellationToken cancellationToken)
    {
        fields["client_id"] = configuration.ClientID;
        using var response = await client.PostAsync(
            configuration.TokenUrl,
            new FormUrlEncodedContent(fields),
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException("The provider token exchange failed.");
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        using var document = JsonDocument.Parse(body);
        var root = document.RootElement;
        var accessToken = RequiredString(root, "access_token");
        var refreshToken = OptionalString(root, "refresh_token");
        var idToken = OptionalString(root, "id_token");
        var expiresAt = OptionalDate(root, "expires_at");
        if (expiresAt is null && Number(root, "expires_in") is { } expiresIn)
        {
            expiresAt = DateTimeOffset.UtcNow.AddSeconds(expiresIn);
        }

        return new OAuthTokenResponse(
            accessToken,
            refreshToken,
            expiresAt,
            idToken);
    }

    private static Uri BuildAuthorizationUri(
        ProviderConfiguration configuration,
        string redirectUri,
        string verifier,
        string state)
    {
        var parameters = new Dictionary<string, string>
        {
            ["response_type"] = "code",
            ["client_id"] = configuration.ClientID,
            ["redirect_uri"] = redirectUri,
            ["scope"] = configuration.Scope,
            ["code_challenge"] = Pkce.Challenge(verifier),
            ["code_challenge_method"] = "S256",
            ["state"] = state
        };
        var query = string.Join(
            "&",
            parameters.Select(pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        return new Uri($"{configuration.AuthorizationUrl}?{query}");
    }

    private async Task<IReadOnlyList<WindowsAccountConnection>> LoadAccountsAsync(
        CancellationToken cancellationToken)
    {
        if (!File.Exists(accountsPath))
        {
            return [];
        }

        await using var stream = File.OpenRead(accountsPath);
        return await JsonSerializer.DeserializeAsync<List<WindowsAccountConnection>>(
                   stream,
                   SnapshotJson.Options,
                   cancellationToken)
               ?? [];
    }

    private async Task SaveAccountsAsync(
        IEnumerable<WindowsAccountConnection> accounts,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(rootDirectory);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            accounts.ToArray(),
            SnapshotJson.Options);
        await WriteAtomicallyAsync(accountsPath, bytes, cancellationToken);
    }

    private static async Task WriteAtomicallyAsync(
        string path,
        byte[] bytes,
        CancellationToken cancellationToken)
    {
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            await File.WriteAllBytesAsync(temporaryPath, bytes, cancellationToken);
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static AccountSnapshot FailureSnapshot(
        WindowsAccountConnection account,
        AccountSnapshot? previous,
        AccountState state)
    {
        if (previous is not null)
        {
            return previous with { State = state };
        }

        return new AccountSnapshot(
            account.AccountId,
            account.Provider,
            "OAuth",
            account.Label,
            account.IsEnabled,
            account.Identity,
            state,
            []);
    }

    private static bool NeedsRefresh(StoredOAuthCredential credential) =>
        credential.ExpiresAt is { } expiresAt &&
        expiresAt <= DateTimeOffset.UtcNow.Add(RefreshLeeway);

    private static bool TryParseProvider(
        string provider,
        out ConnectedProvider result)
    {
        if (provider.Equals("OpenAI", StringComparison.OrdinalIgnoreCase))
        {
            result = ConnectedProvider.OpenAI;
            return true;
        }
        if (provider.Equals("Anthropic", StringComparison.OrdinalIgnoreCase))
        {
            result = ConnectedProvider.Anthropic;
            return true;
        }

        result = default;
        return false;
    }

    private static AccountSnapshot EmptySnapshot(
        WindowsAccountConnection account) =>
        new(
            account.AccountId,
            account.Provider,
            "OAuth",
            account.Label,
            account.IsEnabled,
            account.Identity,
            AccountState.NoData,
            []);

    private static string RequiredString(JsonElement root, string property) =>
        OptionalString(root, property)
        ?? throw new InvalidDataException($"Token response omitted {property}.");

    private static string? OptionalString(JsonElement root, string property)
    {
        return root.TryGetProperty(property, out var value) &&
               value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static double? Number(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number &&
            value.TryGetDouble(out var number))
        {
            return number;
        }
        if (value.ValueKind == JsonValueKind.String &&
            double.TryParse(value.GetString(), out number))
        {
            return number;
        }

        return null;
    }

    private static DateTimeOffset? OptionalDate(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var value))
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Number &&
            value.TryGetInt64(out var seconds))
        {
            return DateTimeOffset.FromUnixTimeSeconds(seconds);
        }
        if (value.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(value.GetString(), out var date))
        {
            return date;
        }

        return null;
    }

    private static Claims ReadClaims(string token)
    {
        try
        {
            var segments = token.Split('.');
            if (segments.Length < 2)
            {
                return new Claims(null, null);
            }

            var encoded = segments[1]
                .Replace("-", "+", StringComparison.Ordinal)
                .Replace("_", "/", StringComparison.Ordinal);
            encoded += new string('=', (4 - encoded.Length % 4) % 4);
            using var document = JsonDocument.Parse(Convert.FromBase64String(encoded));
            var root = document.RootElement;
            var accountID = OptionalString(root, "sub");
            if (root.TryGetProperty(
                    "https://api.openai.com/auth",
                    out var auth) &&
                auth.ValueKind == JsonValueKind.Object)
            {
                accountID = OptionalString(auth, "chatgpt_account_id")
                    ?? OptionalString(auth, "account_id")
                    ?? accountID;
            }

            return new Claims(accountID, OptionalString(root, "email"));
        }
        catch
        {
            return new Claims(null, null);
        }
    }

    private sealed record FetchResult(
        AccountSnapshot? Snapshot,
        AccountState State);

    private sealed record Claims(string? AccountID, string? Email);

    private sealed record ProviderConfiguration(
        string DisplayName,
        string AuthorizationUrl,
        string TokenUrl,
        string UsageUrl,
        string ClientID,
        string Scope,
        string CallbackPath,
        int? FixedPort,
        IEnumerable<int>? CandidatePorts)
    {
        public static ProviderConfiguration For(ConnectedProvider provider) =>
            provider switch
            {
                ConnectedProvider.OpenAI => new(
                    "OpenAI",
                    "https://auth.openai.com/api/accounts/authorize",
                    "https://auth.openai.com/api/accounts/oauth/token",
                    "https://chatgpt.com/backend-api/wham/usage",
                    "app_EMoamEEZ73f0CkXaXp7hrann",
                    "openid profile email offline_access",
                    "/auth/callback",
                    1455,
                    null),
                ConnectedProvider.Anthropic => new(
                    "Anthropic",
                    "https://claude.ai/oauth/authorize",
                    "https://console.anthropic.com/v1/oauth/token",
                    "https://api.anthropic.com/api/oauth/usage",
                    "https://claude.ai/oauth/claude-code-client-metadata",
                    "user:profile user:inference",
                    "/callback",
                    null,
                    Enumerable.Range(1456, 10)),
                _ => throw new ArgumentOutOfRangeException(nameof(provider))
            };
    }
}
