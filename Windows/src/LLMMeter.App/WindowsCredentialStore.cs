using System.Security.Cryptography;
using System.Text.Json;
using LLMMeter.Core;

namespace LLMMeter.App;

internal sealed class WindowsCredentialStore
{
    private readonly string directory;

    public WindowsCredentialStore(string rootDirectory)
    {
        directory = Path.Combine(rootDirectory, "Credentials");
    }

    public async Task SaveAsync(
        string reference,
        StoredOAuthCredential credential,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(directory);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(credential, SnapshotJson.Options);
        var protectedBytes = ProtectedData.Protect(
            plaintext,
            optionalEntropy: null,
            DataProtectionScope.CurrentUser);
        await WriteAtomicallyAsync(
            PathFor(reference),
            protectedBytes,
            cancellationToken);
        CryptographicOperations.ZeroMemory(plaintext);
    }

    public async Task<StoredOAuthCredential> LoadAsync(
        string reference,
        CancellationToken cancellationToken)
    {
        var protectedBytes = await File.ReadAllBytesAsync(
            PathFor(reference),
            cancellationToken);
        var plaintext = ProtectedData.Unprotect(
            protectedBytes,
            optionalEntropy: null,
            DataProtectionScope.CurrentUser);
        try
        {
            var credential = JsonSerializer.Deserialize<StoredOAuthCredential>(
                plaintext,
                SnapshotJson.Options);
            return credential
                ?? throw new InvalidDataException("The stored credential was empty.");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private string PathFor(string reference) =>
        Path.Combine(directory, $"{reference}.bin");

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
}
