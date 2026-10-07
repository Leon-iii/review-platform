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
        Stream content, long length, CancellationToken cancellationToken, bool reviewBeforeConcepts = false, bool prepareOnly = false)
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
            var vision = prepareOnly ? empty : await resolver.CaptureAsync(LlmPurposes.DocumentVision, cancellationToken);
            var concepts = prepareOnly ? empty : await resolver.CaptureAsync(LlmPurposes.ConceptExtraction, cancellationToken);
            await processing.StoreUploadAsync(id, content, fileName, length, cancellationToken);
            var checkpoint = new DocumentCheckpoint { ReviewBeforeConcepts = reviewBeforeConcepts };
            if (prepareOnly)
            {
                checkpoint.ExtractionMode = PdfExtractionModes.Unselected;
                checkpoint.Stage = "selection";
                try { checkpoint.TotalPages = processing.InspectStoredPdf(id).PageCount; }
                catch { processing.DeletePdf(id); throw; }
            }
            var record = new DocumentJobRecord
            {
                Id = id, FileName = Path.GetFileName(fileName),
                Status = prepareOnly ? "awaiting_selection" : "queued",
                CheckpointJson = JsonSerializer.Serialize(checkpoint, Json),
                VisionProfileJson = JsonSerializer.Serialize(vision, Json),
                ConceptProfileJson = JsonSerializer.Serialize(concepts, Json)
            };
            database.DocumentJobs.Add(record);
            await database.SaveChangesAsync(cancellationToken);
            if (!prepareOnly) signals.NotifyQueued();
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
            if (checkpoint.ExtractionMode == PdfExtractionModes.Unselected)
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

    public async Task<DocumentReviewPage> GetReviewPageAsync(string id, int pageNumber, CancellationToken cancellationToken)
    {
        var (record, checkpoint) = await ReviewStateAsync(id, cancellationToken, allowCompleted: true);
        var page = checkpoint.Pages.SingleOrDefault(page => page.PageNumber == pageNumber)
            ?? throw new DocumentImportException("올바르지 않은 검토 페이지입니다.");
        var edited = checkpoint.ReviewPages.TryGetValue(pageNumber, out var blocks);
        // Automatic extraction uses the full hybrid text, not the review editor's
        // canonical transcription. Preserve that distinction in the archive.
        var finalBlocks = blocks ?? DocumentReviewContent.DefaultBlocks(page,
            includeTextLayer: !checkpoint.ReviewBeforeConcepts);
        return new(pageNumber, checkpoint.TotalPages, page.Text,
            finalBlocks, checkpoint.ReviewRevision, edited,
            DocumentReviewContent.DefaultBlocks(page), ReadOnly: record.Status == "completed");
    }

    public async Task<RenderedDocumentPage> GetReviewImageAsync(string id, int pageNumber, CancellationToken cancellationToken)
    {
        await GetReviewPageAsync(id, pageNumber, cancellationToken);
        return await processing.RenderStoredPageAsync(id, pageNumber, cancellationToken);
    }

    public async Task<DocumentReviewPage> SaveReviewPageAsync(string id, int pageNumber,
        SaveDocumentReviewRequest request, CancellationToken cancellationToken)
    {
        var (record, checkpoint) = await ReviewStateAsync(id, cancellationToken);
        if (!checkpoint.Pages.Any(page => page.PageNumber == pageNumber))
            throw new DocumentImportException("올바르지 않은 검토 페이지입니다.");
        EnsureRevision(checkpoint, request.Revision);
        if (request.Blocks is null || request.Blocks.Count is < 1 or > 200 ||
            request.Blocks.Any(block => block is null || block.Text is null) ||
            request.Blocks.Sum(block => (long)block.Text.Length) > 50_000)
            throw new DocumentImportException("페이지 검토 내용은 최대 200개 영역, 50,000자까지 저장할 수 있습니다.");
        if (request.Blocks.Any(block => new[] { "[USER_INDEPENDENT_REGION_START]", "[USER_INDEPENDENT_REGION_END]",
            "[VISUAL_REGION_START]", "[VISUAL_REGION_END]", "[CONTENT_KIND:", "[/CONTENT_KIND]" }.Any(marker => block.Text.Contains(marker, StringComparison.Ordinal))))
            throw new DocumentImportException("영역 경계 표시는 직접 입력하지 말고 독립 영역 설정을 사용해 주세요.");
        if (request.Blocks.Any(block => !DocumentContentKinds.IsValid(block.Kind)))
            throw new DocumentImportException("영역 종류는 일반 텍스트, 도식, 표, 불명확 중 하나여야 합니다.");
        checkpoint.ReviewPages[pageNumber] = request.Blocks.ToList();
        ValidateReviewLength(checkpoint);
        checkpoint.ReviewRevision++;
        await UpdateReviewAsync(record, checkpoint, "awaiting_review", cancellationToken);
        return new(pageNumber, checkpoint.TotalPages, checkpoint.Pages.Single(page => page.PageNumber == pageNumber).Text,
            checkpoint.ReviewPages[pageNumber], checkpoint.ReviewRevision, true,
            DocumentReviewContent.DefaultBlocks(checkpoint.Pages.Single(page => page.PageNumber == pageNumber)));
    }

    public async Task<DocumentJobResponse> ConfirmReviewAsync(string id, ConfirmDocumentReviewRequest request,
        CancellationToken cancellationToken)
    {
        await signals.UploadGate.WaitAsync(cancellationToken);
        try
        {
            var record = await database.DocumentJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, cancellationToken)
                ?? throw new DocumentImportException("PDF 분석 작업을 찾을 수 없습니다.");
            var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, Json)!;
            // A lost confirmation response can safely be retried without queueing twice.
            if (checkpoint.ReviewConfirmed && record.Status is "queued" or "running" or "completed") return Response(record);
            EnsureReviewState(record, checkpoint);
            EnsureRevision(checkpoint, request.Revision);
            ValidateReviewLength(checkpoint);
            if (DocumentReviewContent.ContentCharacterCount(checkpoint) < 20)
                throw new DocumentImportException("개념을 추출할 학습 내용이 부족합니다. 제외한 영역을 확인해 주세요.");
            var limits = configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();
            if (await database.DocumentJobs.CountAsync(job => job.Status == "queued" || job.Status == "running", cancellationToken)
                >= limits.MaximumPendingJobs)
                throw new DocumentImportException("PDF 분석 대기열이 가득 찼습니다. 검토 내용은 보관되므로 잠시 후 다시 시작해 주세요.");
            checkpoint.ReviewConfirmed = true;
            checkpoint.ReviewRevision++;
            checkpoint.Stage = "concepts";
            await UpdateReviewAsync(record, checkpoint, "queued", cancellationToken);
            signals.NotifyQueued();
            return (await GetAsync(id, cancellationToken))!;
        }
        finally { signals.UploadGate.Release(); }
    }

    private async Task<(DocumentJobRecord, DocumentCheckpoint)> ReviewStateAsync(string id, CancellationToken cancellationToken,
        bool allowCompleted = false)
    {
        var record = await database.DocumentJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, cancellationToken)
            ?? throw new DocumentImportException("이 서버에 보관된 OCR 기록을 찾을 수 없습니다. 자료를 가져온 서버와 연결되어 있는지 확인해 주세요.");
        var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, Json)!;
        // Completed archives remain readable even after prompt versions change;
        // only editable/restartable review drafts require the current version.
        if (!allowCompleted || record.Status != "completed") EnsureReviewState(record, checkpoint);
        return (record, checkpoint);
    }

    private static void EnsureReviewState(DocumentJobRecord record, DocumentCheckpoint checkpoint)
    {
        if (record.Status != "awaiting_review" || !checkpoint.ReviewBeforeConcepts || checkpoint.ReviewConfirmed)
            throw new DocumentImportException("이 작업은 현재 OCR 검토 대기 상태가 아닙니다. 작업 상태를 새로고침해 주세요.");
        if (checkpoint.ConceptPromptVersion != ConceptExtractionPrompt.Version || checkpoint.VisionPromptVersion != DocumentVisionPrompt.Version)
            throw new DocumentImportException("서버의 분석 지침 버전이 변경되었습니다. PDF를 새 작업으로 다시 업로드해 주세요.");
    }

    private static void EnsureRevision(DocumentCheckpoint checkpoint, int revision)
    {
        if (revision != checkpoint.ReviewRevision)
            throw new DocumentImportException("다른 화면에서 검토 내용이 변경되었습니다. 새로고침한 뒤 다시 수정해 주세요.");
    }

    private void ValidateReviewLength(DocumentCheckpoint checkpoint)
    {
        var limits = configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();
        if (DocumentReviewContent.ConfirmedPages(checkpoint).Sum(page => (long)page.Text.Length) > limits.MaximumExtractedCharacters)
            throw new DocumentImportException("검토 내용이 서버의 텍스트 안전 제한을 초과했습니다.");
    }

    private async Task UpdateReviewAsync(DocumentJobRecord original, DocumentCheckpoint checkpoint, string status,
        CancellationToken cancellationToken)
    {
        var updated = await database.DocumentJobs.Where(job => job.Id == original.Id && job.Status == "awaiting_review" &&
            job.CheckpointJson == original.CheckpointJson).ExecuteUpdateAsync(setters => setters
                .SetProperty(job => job.CheckpointJson, JsonSerializer.Serialize(checkpoint, Json))
                .SetProperty(job => job.Status, status).SetProperty(job => job.Error, (string?)null)
                .SetProperty(job => job.UpdatedAt, DateTimeOffset.UtcNow), cancellationToken);
        if (updated == 0) throw new DocumentImportException("작업 상태 또는 검토 내용이 변경되었습니다. 새로고침해 주세요.");
    }

    private static DocumentJobResponse Response(DocumentJobRecord record)
    {
        var checkpoint = JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, Json)!;
        return new(record.Id, record.FileName, record.Status, checkpoint.Stage,
            checkpoint.Pages.Count, checkpoint.TotalPages, checkpoint.Chunks.Count, checkpoint.TotalChunks,
            record.Error, record.UpdatedAt,
            JsonSerializer.Deserialize<LlmProfileDto>(record.VisionProfileJson, Json)!.Model,
            JsonSerializer.Deserialize<LlmProfileDto>(record.ConceptProfileJson, Json)!.Model,
            checkpoint.ReviewBeforeConcepts, checkpoint.ReviewConfirmed, checkpoint.ExtractionMode);
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
            var result = checkpoint.ExtractionMode == PdfExtractionModes.Direct
                ? await processing.ProcessDirectPdfAsync(job.Id, job.FileName, concepts, checkpoint, Save, cancellation.Token)
                : await processing.ProcessStoredPdfAsync(job.Id, job.FileName, concepts,
                    () => resolver.ResolveSnapshotAsync(visionProfile, cancellation.Token), checkpoint, Save, cancellation.Token);
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
        catch (DocumentReviewRequiredException)
        {
            await database.DocumentJobs.Where(item => item.Id == job.Id && item.Status == "running")
                .ExecuteUpdateAsync(setters => setters.SetProperty(item => item.Status, "awaiting_review")
                    .SetProperty(item => item.UpdatedAt, DateTimeOffset.UtcNow));
            logger.LogInformation("PDF job awaiting user review. JobId={JobId}", job.Id);
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
