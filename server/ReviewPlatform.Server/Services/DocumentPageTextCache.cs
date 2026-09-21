using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ReviewPlatform.Server.Services;

public interface IDocumentPageTextCache
{
    Task<string?> GetAsync(
        string imageHash,
        string provider,
        string model,
        string promptVersion,
        CancellationToken cancellationToken = default);

    Task SetAsync(
        string imageHash,
        string provider,
        string model,
        string promptVersion,
        string text,
        CancellationToken cancellationToken = default);
}

public sealed class FileDocumentPageTextCache(
    IWebHostEnvironment environment,
    IConfiguration configuration) : IDocumentPageTextCache
{
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web);

    public async Task<string?> GetAsync(
        string imageHash,
        string provider,
        string model,
        string promptVersion,
        CancellationToken cancellationToken = default)
    {
        var path = BuildPath(imageHash, provider, model, promptVersion);
        if (!File.Exists(path)) return null;
        try
        {
            await using var stream = File.OpenRead(path);
            var entry = await JsonSerializer.DeserializeAsync<CacheEntry>(
                stream,
                JsonOptions,
                cancellationToken);
            return entry?.Text;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    public async Task SetAsync(
        string imageHash,
        string provider,
        string model,
        string promptVersion,
        string text,
        CancellationToken cancellationToken = default)
    {
        var path = BuildPath(imageHash, provider, model, promptVersion);
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                81920,
                FileOptions.Asynchronous))
            {
                await JsonSerializer.SerializeAsync(
                    stream,
                    new CacheEntry(text, DateTimeOffset.UtcNow),
                    JsonOptions,
                    cancellationToken);
            }
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private string BuildPath(
        string imageHash,
        string provider,
        string model,
        string promptVersion)
    {
        var identity = string.Join('\n', imageHash, provider, model, promptVersion);
        var key = Convert.ToHexString(SHA256.HashData(
                Encoding.UTF8.GetBytes(identity)))
            .ToLowerInvariant();
        return Path.Combine(ResolveRoot(), $"{key}.json");
    }

    private string ResolveRoot()
    {
        var configured = configuration["Documents:PageCachePath"];
        if (string.IsNullOrWhiteSpace(configured))
        {
            return Path.Combine(
                environment.ContentRootPath,
                "App_Data",
                "document-page-cache");
        }
        return Path.IsPathRooted(configured)
            ? configured
            : Path.GetFullPath(Path.Combine(environment.ContentRootPath, configured));
    }

    private sealed record CacheEntry(string Text, DateTimeOffset CreatedAt);
}

public sealed class NullDocumentPageTextCache : IDocumentPageTextCache
{
    public Task<string?> GetAsync(
        string imageHash,
        string provider,
        string model,
        string promptVersion,
        CancellationToken cancellationToken = default) =>
        Task.FromResult<string?>(null);

    public Task SetAsync(
        string imageHash,
        string provider,
        string model,
        string promptVersion,
        string text,
        CancellationToken cancellationToken = default) => Task.CompletedTask;
}
