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
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        await using var stream = File.Create(path);
        await JsonSerializer.SerializeAsync(
            stream,
            snapshot,
            SnapshotJson.Options,
            cancellationToken);
    }
}
