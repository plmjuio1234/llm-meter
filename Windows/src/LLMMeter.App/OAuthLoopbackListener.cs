using System.Net;
using System.Net.Sockets;
using System.Text;

namespace LLMMeter.App;

internal sealed class OAuthLoopbackListener : IAsyncDisposable
{
    private const int MaxRequestBytes = 16 * 1024;
    private readonly TcpListener listener;
    private readonly string callbackPath;

    private OAuthLoopbackListener(TcpListener listener, string callbackPath)
    {
        this.listener = listener;
        this.callbackPath = callbackPath;
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    public static OAuthLoopbackListener Start(
        string callbackPath,
        int? fixedPort,
        IEnumerable<int>? candidatePorts = null)
    {
        var ports = fixedPort is not null
            ? [fixedPort.Value]
            : candidatePorts ?? Enumerable.Range(1456, 10);

        foreach (var port in ports)
        {
            var candidate = new TcpListener(IPAddress.Loopback, port);
            try
            {
                candidate.Start();
                return new OAuthLoopbackListener(candidate, callbackPath);
            }
            catch (SocketException)
            {
                candidate.Stop();
            }
        }

        throw new InvalidOperationException(
            "No loopback callback port was available.");
    }

    public async Task<OAuthCallback> WaitForCallbackAsync(
        CancellationToken cancellationToken)
    {
        while (true)
        {
            using var client = await listener.AcceptTcpClientAsync(cancellationToken);
            using var stream = client.GetStream();
            var request = await ReadRequestAsync(stream, cancellationToken);
            if (request is null)
            {
                await WriteResponseAsync(stream, 400, "Invalid callback request.");
                continue;
            }

            var firstLine = request
                .Split("\r\n", StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault();
            if (firstLine is null ||
                !firstLine.StartsWith("GET ", StringComparison.Ordinal))
            {
                await WriteResponseAsync(stream, 405, "Only GET is supported.");
                continue;
            }

            var target = firstLine
                .Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .ElementAtOrDefault(1);
            if (target is null)
            {
                await WriteResponseAsync(stream, 400, "Invalid callback target.");
                continue;
            }
            if (!target.StartsWith("/", StringComparison.Ordinal) ||
                target.StartsWith("//", StringComparison.Ordinal))
            {
                await WriteResponseAsync(stream, 400, "Invalid callback target.");
                continue;
            }

            if (!Uri.TryCreate(
                    new Uri("http://localhost"),
                    target,
                    out var callbackUri))
            {
                await WriteResponseAsync(stream, 400, "Invalid callback target.");
                continue;
            }
            if (!string.Equals(
                    callbackUri.AbsolutePath,
                    callbackPath,
                    StringComparison.Ordinal))
            {
                await WriteResponseAsync(stream, 404, "Unknown callback path.");
                continue;
            }

            if (!TryParseQuery(callbackUri.Query, out var query))
            {
                await WriteResponseAsync(stream, 400, "Invalid callback query.");
                continue;
            }
            var callback = new OAuthCallback(
                query.GetValueOrDefault("code"),
                query.GetValueOrDefault("state"),
                query.GetValueOrDefault("error"));
            await WriteResponseAsync(
                stream,
                callback.Error is null ? 200 : 400,
                callback.Error is null
                    ? "Account connection completed. You can close this window."
                    : "Account connection was denied.");
            return callback;
        }
    }

    public ValueTask DisposeAsync()
    {
        listener.Stop();
        return ValueTask.CompletedTask;
    }

    private static async Task<string?> ReadRequestAsync(
        NetworkStream stream,
        CancellationToken cancellationToken)
    {
        var bytes = new List<byte>();
        var buffer = new byte[2048];
        while (bytes.Count < MaxRequestBytes)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                break;
            }

            bytes.AddRange(buffer.AsSpan(0, read).ToArray());
            if (bytes.Count >= 4 &&
                bytes[^4] == '\r' &&
                bytes[^3] == '\n' &&
                bytes[^2] == '\r' &&
                bytes[^1] == '\n')
            {
                return Encoding.UTF8.GetString(bytes.ToArray());
            }
        }

        return null;
    }

    private static async Task WriteResponseAsync(
        NetworkStream stream,
        int statusCode,
        string message)
    {
        var body = $"""
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>LLM Meter</title></head>
            <body><h1>{WebUtility.HtmlEncode(message)}</h1></body>
            </html>
            """;
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var header = Encoding.ASCII.GetBytes(
            $"HTTP/1.1 {statusCode} {StatusText(statusCode)}\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            $"Content-Length: {bodyBytes.Length}\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n");
        await stream.WriteAsync(header);
        await stream.WriteAsync(bodyBytes);
    }

    private static string StatusText(int statusCode) =>
        statusCode switch
        {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            405 => "Method Not Allowed",
            _ => "Error"
        };

    private static bool TryParseQuery(
        string query,
        out Dictionary<string, string?> values)
    {
        values = new Dictionary<string, string?>(StringComparer.Ordinal);
        foreach (var part in query.TrimStart('?')
                     .Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = part.Split('=', 2);
            var key = WebUtility.UrlDecode(parts[0]);
            if (string.IsNullOrWhiteSpace(key) || values.ContainsKey(key))
            {
                values = [];
                return false;
            }

            values[key] = parts.Length == 2
                ? WebUtility.UrlDecode(parts[1])
                : null;
        }

        return true;
    }
}

internal sealed record OAuthCallback(
    string? Code,
    string? State,
    string? Error
);
