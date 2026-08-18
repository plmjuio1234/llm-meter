using System.Text.Json;

namespace LLMMeter.Core;

public static class SnapshotStore
{
    public static async Task<SharedSnapshot> LoadAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(path);
        var snapshot = await JsonSerializer.DeserializeAsync<SharedSnapshot>(
            stream,
            SnapshotJson.Options,
            cancellationToken);

        if (snapshot is null)
        {
            throw new InvalidDataException("Snapshot file was empty.");
        }

        snapshot.Validate();
        return snapshot;
    }

    public static async Task SaveAsync(
        string path,
        SharedSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        snapshot.Validate();
        var directory = Path.GetDirectoryName(path) ?? ".";
        Directory.CreateDirectory(directory);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            await using var stream = File.Create(temporaryPath);
            await JsonSerializer.SerializeAsync(
                stream,
                snapshot,
                SnapshotJson.Options,
                cancellationToken);
            await stream.FlushAsync(cancellationToken);
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
