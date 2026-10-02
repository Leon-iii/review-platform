using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;

// One active PDF per server. Cancelling an HTTP request must not cancel a job.
public sealed class DocumentJobSignals
{
    public SemaphoreSlim UploadGate { get; } = new(1, 1);
    private readonly SemaphoreSlim queued = new(0, 1);
    public Task WaitForJobAsync(CancellationToken cancellationToken) => queued.WaitAsync(cancellationToken);
    public void NotifyQueued()
    {
        try { queued.Release(); } catch (SemaphoreFullException) { }
    }
    private readonly ConcurrentDictionary<string, CancellationTokenSource> running = new();
    public bool IsRunning(string id) => running.ContainsKey(id);
    public void Register(string id, CancellationTokenSource source) => running[id] = source;
    public void Unregister(string id) => running.TryRemove(id, out _);
    public void Cancel(string id)
    {
        if (running.TryGetValue(id, out var source))
            try { source.Cancel(); } catch (ObjectDisposedException) { }
    }
}

public sealed class DocumentJobService(
    SyncDbContext database, DocumentProcessingService processing,
    ILlmProviderResolver resolver, DocumentJobSignals signals, IConfiguration configuration)
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<DocumentJobResponse> UploadAsync(string id, string fileName,
        Stream content, long length, CancellationToken cancellationToken)
    {
        if (!Guid.TryParseExact(id, "D", out _))
            throw new DocumentImportException("올바르지 않은 PDF 작업 ID입니다.");
        await signals.UploadGate.WaitAsync(cancellationToken);
        try
        {
            var existing = await database.DocumentJobs.AsNoTracking()
                .SingleOrDefaultAsync(job => job.Id == id, cancellationToken);
            if (existing is not null) return Response(existing);
            var limits = configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();
            var pending = await database.DocumentJobs.CountAsync(
                job => job.Status == "queued" || job.Status == "running", cancellationToken);
            if (pending >= limits.MaximumPendingJobs)
                throw new DocumentImportException("PDF 분석 대기열이 가득 찼습니다. 진행 중인 작업이 끝난 뒤 다시 시도해 주세요.");
            var vision = await resolver.CaptureAsync(LlmPurposes.DocumentVision, cancellationToken);
            var concepts = await resolver.CaptureAsync(LlmPurposes.ConceptExtraction, cancellationToken);
            await processing.StoreUploadAsync(id, content, fileName, length, cancellationToken);
            var record = new DocumentJobRecord
            {
                Id = id, FileName = Path.GetFileName(fileName),
                CheckpointJson = JsonSerializer.Serialize(new DocumentCheckpoint(), Json),
                VisionProfileJson = JsonSerializer.Serialize(vision, Json),
                ConceptProfileJson = JsonSerializer.Serialize(concepts, Json)
            };
            database.DocumentJobs.Add(record);
            await database.SaveChangesAsync(cancellationToken);
            signals.NotifyQueued();
            return Response(record);
        }
        finally { signals.UploadGate.Release(); }
    }

    public async Task<DocumentJobResponse?> GetAsync(string id, CancellationToken cancellationToken) =>
        await database.DocumentJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, cancellationToken)
            is { } job ? Response(job) : null;

    public async Task<string?> GetResultAsync(string id, CancellationToken cancellationToken) =>
        await database.DocumentJobs.AsNoTracking().Where(job => job.Id == id && job.Status == "completed")
            .Select(job => job.ResultJson).SingleOrDefaultAsync(cancellationToken);

    public async Task<DocumentJobResponse?> CancelAsync(string id, CancellationToken cancellationToken)
    {
        await database.DocumentJobs.Where(job => job.Id == id && job.Status != "completed")
            .ExecuteUpdateAsync(setters => setters.SetProperty(job => job.Status, "cancelled")
                .SetProperty(job => job.Error, (string?)null)
                .SetProperty(job => job.UpdatedAt, DateTimeOffset.UtcNow), cancellationToken);
        signals.Cancel(id);
        return await GetAsync(id, cancellationToken);
    }

    public async Task<DocumentJobResponse?> RetryAsync(string id, CancellationToken cancellationToken)
    {
        await signals.UploadGate.WaitAsync(cancellationToken);
        try
        {
            // Wait until the interrupted provider has actually stopped.
            if (signals.IsRunning(id))
                throw new DocumentImportException("작업을 중단하는 중입니다. 잠시 후 다시 시도해 주세요.");
            var record = await database.DocumentJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, cancellationToken);
            if (record is null) return null;
            if (record.Status is not ("failed" or "cancelled")) return Response(record);
            var limits = configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();
            if (await database.DocumentJobs.CountAsync(job => job.Status == "queued" || job.Status == "running", cancellationToken)
                >= limits.MaximumPendingJobs)
                throw new DocumentImportException("PDF 분석 대기열이 가득 찼습니다. 잠시 후 다시 시도해 주세요.");
            await database.DocumentJobs.Where(job => job.Id == id &&
                (job.Status == "failed" || job.Status == "cancelled"))
                .ExecuteUpdateAsync(setters => setters.SetProperty(job => job.Status, "queued")
                    .SetProperty(job => job.Error, (string?)null)
                    .SetProperty(job => job.UpdatedAt, DateTimeOffset.UtcNow), cancellationToken);
            signals.NotifyQueued();
            return await GetAsync(id, cancellationToken);
        }
        finally { signals.UploadGate.Release(); }
    }

    private static DocumentJobResponse Response(DocumentJobRecord record)
    {
        var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, Json)!;
        return new(record.Id, record.FileName, record.Status, checkpoint.Stage,
            checkpoint.Pages.Count, checkpoint.TotalPages, checkpoint.Chunks.Count, checkpoint.TotalChunks,
            record.Error, record.UpdatedAt,
            JsonSerializer.Deserialize<LlmProfileDto>(record.VisionProfileJson, Json)!.Model,
            JsonSerializer.Deserialize<LlmProfileDto>(record.ConceptProfileJson, Json)!.Model);
    }
}

public sealed class DocumentJobWorker(
    IServiceScopeFactory scopeFactory, DocumentJobSignals signals,
    ILogger<DocumentJobWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using (var scope = scopeFactory.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
            await database.DocumentJobs.Where(job => job.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(job => job.Status, "queued"), stoppingToken);
        }
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (!await RunNextAsync(stoppingToken))
                    await signals.WaitForJobAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                logger.LogError(exception, "PDF job worker failed; will retry polling.");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    public async Task<bool> RunNextAsync(CancellationToken stoppingToken = default)
    {
        using var scope = scopeFactory.CreateScope();
        var services = scope.ServiceProvider;
        var database = services.GetRequiredService<SyncDbContext>();
        // SQLite cannot translate DateTimeOffset ordering through EF. All
        // timestamps here are UTC, so their stored representation sorts FIFO.
        var job = await database.DocumentJobs.FromSqlRaw(
            "SELECT * FROM DocumentJobs WHERE Status = 'queued' ORDER BY UpdatedAt, Id LIMIT 1")
            .AsNoTracking().SingleOrDefaultAsync(stoppingToken);
        if (job is null) return false;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        signals.Register(job.Id, cancellation);
        try
        {
            var claimed = await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "queued")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status, "running")
                    .SetProperty(item => item.Error, (string?)null), stoppingToken);
            if (claimed == 0) return true;
            var resolver = services.GetRequiredService<ILlmProviderResolver>();
            var conceptProfile = JsonSerializer.Deserialize<LlmProfileDto>(job.ConceptProfileJson, DocumentJobService.Json)!;
            var visionProfile = JsonSerializer.Deserialize<LlmProfileDto>(job.VisionProfileJson, DocumentJobService.Json)!;
            var concepts = await resolver.ResolveSnapshotAsync(conceptProfile, cancellation.Token);
            var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(job.CheckpointJson, DocumentJobService.Json)!;
            var result = await services.GetRequiredService<DocumentProcessingService>().ProcessStoredPdfAsync(
                job.Id, job.FileName, concepts,
                () => resolver.ResolveSnapshotAsync(visionProfile, cancellation.Token), checkpoint,
                async state =>
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    var updated = await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                        .ExecuteUpdateAsync(setters => setters
                            .SetProperty(item => item.CheckpointJson, JsonSerializer.Serialize(state, DocumentJobService.Json))
                            .SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow), cancellation.Token);
                    if (updated == 0) throw new OperationCanceledException("PDF job was cancelled.");
                }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status, "completed")
                    .SetProperty(item => item.ResultJson, JsonSerializer.Serialize(result, DocumentJobService.Json))
                    .SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow), cancellation.Token);
            logger.LogInformation("PDF job completed. JobId={JobId} Pages={Pages} Concepts={Concepts}",
                job.Id, result.Source.PageCount, result.Concepts.Count);
        }
        catch (OperationCanceledException)
        {
            await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status,
                    stoppingToken.IsCancellationRequested ? "queued" : "cancelled"));
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "PDF job failed. JobId={JobId}", job.Id);
            var error = exception is DocumentImportException or LlmProviderRequestException or LlmProviderUnavailableException
                ? exception.Message : "PDF 분석 중 서버 오류가 발생했습니다. 서버 로그를 확인해 주세요.";
            await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status, "failed")
                    .SetProperty(item => item.Error, error)
                    .SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow));
        }
        finally { signals.Unregister(job.Id); }
        return true;
    }
}
