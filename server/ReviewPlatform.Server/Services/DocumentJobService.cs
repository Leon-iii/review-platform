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
    private sealed record RunningJob(CancellationTokenSource Source, TaskCompletionSource Stopped);
    private readonly ConcurrentDictionary<string, RunningJob> running = new();
    public bool IsRunning(string id) => running.ContainsKey(id);
    public void Register(string id, CancellationTokenSource source) => running[id] = new(
        source, new(TaskCreationOptions.RunContinuationsAsynchronously));
    public void Unregister(string id)
    {
        if (running.TryRemove(id, out var job)) job.Stopped.TrySetResult();
    }
    public void Cancel(string id)
    {
        if (running.TryGetValue(id, out var job))
            try { job.Source.Cancel(); } catch (ObjectDisposedException) { }
    }
    public async Task CancelAndWaitAsync(string id, CancellationToken cancellationToken)
    {
        if (!running.TryGetValue(id, out var job)) return;
        try { job.Source.Cancel(); } catch (ObjectDisposedException) { }
        try { await job.Stopped.Task.WaitAsync(TimeSpan.FromSeconds(20), cancellationToken); }
        catch (TimeoutException exception)
        {
            throw new DocumentImportException("PDF 작업을 중단하는 중입니다. 잠시 후 다시 삭제해 주세요.", exception);
        }
    }
}

public sealed partial class DocumentJobService(
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
            var empty = new LlmProfileDto("", "", "", "", DateTimeOffset.UtcNow);
            await processing.StoreUploadAsync(id, content, fileName, length, cancellationToken);
            var checkpoint = new DocumentCheckpoint { Stage = "selection" };
            try { checkpoint.TotalPages = processing.InspectStoredPdf(id).PageCount; }
            catch { processing.DeletePdf(id); throw; }
            var record = new DocumentJobRecord
            {
                Id = id, FileName = Path.GetFileName(fileName),
                Status = "awaiting_selection",
                CheckpointJson = JsonSerializer.Serialize(checkpoint, Json),
                // Retain the legacy DB column without scheduling an image-text operation.
                VisionProfileJson = JsonSerializer.Serialize(empty, Json),
                ConceptProfileJson = JsonSerializer.Serialize(empty, Json)
            };
            database.DocumentJobs.Add(record);
            await database.SaveChangesAsync(cancellationToken);
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

    public async Task DeleteAsync(string id, CancellationToken cancellationToken)
    {
        if (!Guid.TryParseExact(id, "D", out _))
            throw new DocumentImportException("올바르지 않은 PDF 작업 ID입니다.");
        await signals.UploadGate.WaitAsync(cancellationToken);
        try
        {
            // Do not parse checkpoints/profiles: incompatible old jobs must remain deletable.
            await database.DocumentJobs.Where(job => job.Id == id && job.Status != "completed")
                .ExecuteUpdateAsync(setters => setters.SetProperty(job => job.Status, "cancelled"), cancellationToken);
            var status = await database.DocumentJobs.AsNoTracking().Where(job => job.Id == id)
                .Select(job => job.Status).SingleOrDefaultAsync(cancellationToken);
            if (status is null) return; // Idempotent after a lost deletion receipt.
            if (status == "completed")
                throw new DocumentImportException("분석이 완료된 자료는 폴더의 자료 삭제 메뉴를 사용해 주세요.");
            await signals.CancelAndWaitAsync(id, cancellationToken);
            // The worker is stopped before deleting its open PDF. If removal fails,
            // retain the cancelled row so the user can retry without resuming analysis.
            processing.DeletePdf(id);
            await database.DocumentJobs.Where(job => job.Id == id).ExecuteDeleteAsync(cancellationToken);
        }
        finally { signals.UploadGate.Release(); }
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
            var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, Json)!;
            if (checkpoint.ExtractionMode != PdfExtractionModes.Direct)
            {
                await database.DocumentJobs.Where(job => job.Id == id).ExecuteUpdateAsync(setters => setters.SetProperty(job => job.Status, "awaiting_selection"), cancellationToken);
                return await GetAsync(id, cancellationToken);
            }
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
        var needsSelection = record.Status != "completed" && checkpoint.ExtractionMode != PdfExtractionModes.Direct;
        return new(record.Id, record.FileName, needsSelection ? "awaiting_selection" : record.Status,
            needsSelection ? "selection" : checkpoint.Stage, 0, checkpoint.TotalPages,
            needsSelection ? 0 : checkpoint.Chunks.Count, needsSelection ? 0 : checkpoint.TotalChunks,
            record.Error, record.UpdatedAt,
            needsSelection ? "" : JsonSerializer.Deserialize<LlmProfileDto>(record.ConceptProfileJson, Json)!.Model,
            checkpoint.ExtractionMode);
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
            var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(job.CheckpointJson, DocumentJobService.Json)!;
            if (checkpoint.ExtractionMode != PdfExtractionModes.Direct)
                throw new PdfSelectionRequiredException("PDF 직접 추출 사전 점검이 필요합니다. 추출 설정에서 다시 점검해 주세요.");
            var resolver = services.GetRequiredService<ILlmProviderResolver>();
            var conceptProfile = JsonSerializer.Deserialize<LlmProfileDto>(job.ConceptProfileJson, DocumentJobService.Json)!;
            var concepts = await resolver.ResolveSnapshotAsync(conceptProfile, cancellation.Token);
            async Task Save(DocumentCheckpoint state)
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    var updated = await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                        .ExecuteUpdateAsync(setters => setters
                            .SetProperty(item => item.CheckpointJson, JsonSerializer.Serialize(state, DocumentJobService.Json))
                            .SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow), cancellation.Token);
                    if (updated == 0) throw new OperationCanceledException("PDF job was cancelled.");
                }
            var processing = services.GetRequiredService<DocumentProcessingService>();
            var result = await processing.ProcessDirectPdfAsync(job.Id, job.FileName, concepts, checkpoint, Save, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status, "completed")
                    .SetProperty(item => item.ResultJson, JsonSerializer.Serialize(result, DocumentJobService.Json))
                    .SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow), cancellation.Token);
            logger.LogInformation("PDF job completed. JobId={JobId} Pages={Pages} Concepts={Concepts}",
                job.Id, result.Source.PageCount, result.Concepts.Count);
        }
        catch (PdfSelectionRequiredException exception)
        {
            await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status, "awaiting_selection")
                    .SetProperty(item => item.Error, exception.Message).SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow));
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
