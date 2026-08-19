namespace LLMMeter.App;

internal static class StartupDiagnostics
{
    public static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LLMMeter",
        "startup.log");

    public static void Write(string message, Exception? error = null)
    {
        try
        {
            var directory = Path.GetDirectoryName(LogPath)!;
            Directory.CreateDirectory(directory);
            var detail = error is null
                ? string.Empty
                : $" {error.GetType().Name}: {error.Message}";
            File.AppendAllText(
                LogPath,
                $"{DateTimeOffset.UtcNow:O} {message}{detail}{Environment.NewLine}");
        }
        catch
        {
            // Diagnostics must never prevent the app from starting.
        }
    }
}
