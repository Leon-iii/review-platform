using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;
public sealed partial class DocumentJobService
{
    private async Task<(DocumentJobRecord Record, DocumentCheckpoint Checkpoint)> ExtractionStateAsync(string id, CancellationToken token)
    {
        var record = await database.DocumentJobs.AsNoTracking().SingleOrDefaultAsync(job => job.Id == id, token)
            ?? throw new DocumentImportException("PDF 작업을 찾을 수 없습니다.");
        return (record, JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, Json)!);
    }
    public async Task<PdfExtractionOverview> ExtractionOverviewAsync(string id, CancellationToken token)
    {
        var (_, checkpoint) = await ExtractionStateAsync(id, token);
        var file = processing.InspectStoredPdf(id);
        var profile = await resolver.CaptureAsync(LlmPurposes.ConceptExtraction, token);
        var direct = profile.Provider == "openai" ? await resolver.ResolveSnapshotAsync(profile, token) as IDirectPdfConceptProvider : null;
        return new(id, (await GetAsync(id, token))!.FileName, file.FileSize, file.PageCount, file.ContentHash,
            checkpoint.ExtractionMode, checkpoint.ExtractionRevision, profile.Model, profile.Provider,
            direct is null ? 0 : processing.DirectOutputBudget(direct),
            processing.ConfiguredDirectTpm, checkpoint.SplitAfterPages,
            checkpoint.Preflight?.Model == profile.Model && checkpoint.Preflight.Provider == profile.Provider ? checkpoint.Preflight : null);
    }
    public async Task<RenderedDocumentPage> ExtractionImageAsync(string id, int page, CancellationToken token)
    {
        await ExtractionStateAsync(id, token);
        var file = processing.InspectStoredPdf(id);
        if (page < 1 || page > file.PageCount) throw new DocumentImportException("올바르지 않은 PDF 페이지입니다.");
        return await processing.RenderStoredPageAsync(id, page, token);
    }
    private static void EnsureEditable(DocumentJobRecord record, DocumentCheckpoint checkpoint, PdfExtractionSelection selection)
    {
        if (record.Status is not ("awaiting_selection" or "awaiting_review" or "failed" or "cancelled"))
            throw new DocumentImportException("이미 시작된 작업입니다. 작업 상태를 새로고침해 주세요.");
        if (selection.Revision != checkpoint.ExtractionRevision)
            throw new DocumentImportException("다른 화면에서 추출 설정이 변경되었습니다. 새로고침해 주세요.");
        if (selection.Mode != PdfExtractionModes.Direct)
            throw new DocumentImportException("PDF 직접 추출만 지원합니다. 앱을 업데이트해 주세요.");
        if (checkpoint.Chunks.Count > 0 && checkpoint.ExtractionMode == PdfExtractionModes.Direct && selection.Mode != checkpoint.ExtractionMode)
            throw new DocumentImportException("완료된 묶음이 있어 추출 방식을 변경할 수 없습니다. 원본을 새 작업으로 업로드해 주세요.");
    }
    public async Task<PdfExtractionPreflight> PreflightAsync(string id, PdfExtractionSelection selection, CancellationToken token)
    {
        await signals.UploadGate.WaitAsync(token);
        try
        {
            var (record, checkpoint) = await ExtractionStateAsync(id, token);
            EnsureEditable(record, checkpoint, selection);
            var profile = await resolver.CaptureAsync(LlmPurposes.ConceptExtraction, token);
            var llm = await resolver.ResolveSnapshotAsync(profile, token);
            if (llm is not IDirectPdfConceptProvider provider)
                throw new DocumentImportException("직접 추출에는 OpenAI PDF 입력 모델이 필요합니다. PDF 개념 추출 모델을 변경해 주세요.");
            checkpoint.TotalPages = processing.InspectStoredPdf(id).PageCount;
            var ranges = DocumentProcessingService.SelectedRanges(checkpoint.TotalPages, selection.SplitAfterPages);
            var oldRanges = DocumentProcessingService.SelectedRanges(checkpoint.TotalPages, checkpoint.SplitAfterPages);
            if (checkpoint.ExtractionMode == PdfExtractionModes.Direct && checkpoint.Chunks.Count > 0 && !ranges.Take(checkpoint.Chunks.Count).SequenceEqual(oldRanges.Take(checkpoint.Chunks.Count)))
                throw new DocumentImportException("이미 완료된 묶음의 경계는 변경할 수 없습니다. 미완료 범위의 분할 지점을 지정해 주세요.");
            var parts = new List<PdfPreflightPart>();
            foreach (var range in ranges)
                parts.Add(await processing.InspectDirectPartAsync(id, record.FileName, checkpoint.TotalPages, range, provider, token));
            if (checkpoint.ExtractionMode != PdfExtractionModes.Direct)
            {
                // Legacy partial results are not combined with a new direct-PDF run.
                checkpoint.Chunks.Clear();
                checkpoint.TotalChunks = 0;
            }
            checkpoint.ExtractionMode = selection.Mode;
            checkpoint.SplitAfterPages = (selection.SplitAfterPages ?? []).ToList();
            checkpoint.DirectPromptVersion = DirectPdfConceptPrompt.Version;
            checkpoint.ExtractionRevision++;
            checkpoint.Preflight = new(profile.Model, profile.Provider, checkpoint.ExtractionRevision,
                DocumentProcessingService.PreflightStatus(parts), parts);
            // Store profile together with the check. Start rejects stale model settings.
            var changed = await database.DocumentJobs.Where(job => job.Id == id && job.CheckpointJson == record.CheckpointJson && job.Status == record.Status)
                .ExecuteUpdateAsync(setters => setters.SetProperty(job => job.CheckpointJson, JsonSerializer.Serialize(checkpoint, Json))
                    .SetProperty(job => job.ConceptProfileJson, JsonSerializer.Serialize(profile, Json))
                    .SetProperty(job => job.UpdatedAt, DateTimeOffset.UtcNow), token);
            if (changed == 0) throw new DocumentImportException("작업 상태가 변경되었습니다. 새로고침해 주세요.");
            return checkpoint.Preflight;
        }
        finally { signals.UploadGate.Release(); }
    }
    public async Task<DocumentJobResponse> StartExtractionAsync(string id, PdfExtractionSelection selection, CancellationToken token)
    {
        await signals.UploadGate.WaitAsync(token);
        try
        {
            var (record, checkpoint) = await ExtractionStateAsync(id, token);
            // Idempotent recovery from a lost start receipt.
            if (record.Status is "queued" or "running" or "completed") return Response(record);
            EnsureEditable(record, checkpoint, selection);
            var profile = await resolver.CaptureAsync(LlmPurposes.ConceptExtraction, token);
            if (selection.Mode == PdfExtractionModes.Direct)
            {
                if (checkpoint.Preflight is null || checkpoint.Preflight.Status == "blocked" ||
                    checkpoint.Preflight.Parts.Any(part => part.Status == "waiting" && part.InputTokens is null) ||
                    !checkpoint.SplitAfterPages.SequenceEqual(selection.SplitAfterPages ?? []) ||
                    !SameProfile(JsonSerializer.Deserialize<LlmProfileDto>(record.ConceptProfileJson, Json)!, profile))
                    throw new DocumentImportException("직접 추출 사전 점검을 먼저 수행해 주세요. 모델 또는 분할 지점이 변경되면 다시 점검해야 합니다.");
                if (checkpoint.Preflight.Status != "ready" && !selection.AcknowledgeWarnings)
                    throw new DocumentImportException("사전 점검의 경고·불확실성을 확인한 뒤 진행해 주세요.");
            }
            if (await database.DocumentJobs.CountAsync(job => job.Status == "queued" || job.Status == "running", token)
                >= (configuration.GetSection("Documents").Get<DocumentLimits>() ?? new()).MaximumPendingJobs)
                throw new DocumentImportException("PDF 대기열이 가득 찼습니다. 잠시 후 다시 시작해 주세요.");
            checkpoint.ExtractionMode = selection.Mode;
            checkpoint.Stage = "preflight";
            checkpoint.ExtractionRevision++;
            var changed = await database.DocumentJobs.Where(job => job.Id == id && job.CheckpointJson == record.CheckpointJson && job.Status == record.Status)
                .ExecuteUpdateAsync(setters => setters.SetProperty(job => job.Status, "queued")
                    .SetProperty(job => job.CheckpointJson, JsonSerializer.Serialize(checkpoint, Json))
                    .SetProperty(job => job.ConceptProfileJson, JsonSerializer.Serialize(profile, Json))
                    .SetProperty(job => job.Error, (string?)null).SetProperty(job => job.UpdatedAt, DateTimeOffset.UtcNow), token);
            if (changed == 0) throw new DocumentImportException("작업 상태가 변경되었습니다. 새로고침해 주세요.");
            signals.NotifyQueued();
            return (await GetAsync(id, token))!;
        }
        finally { signals.UploadGate.Release(); }
    }
    private static bool SameProfile(LlmProfileDto a, LlmProfileDto b) =>
        a.Id == b.Id && a.Provider == b.Provider && a.Model == b.Model && a.ContextWindowTokens == b.ContextWindowTokens && a.ReasoningEffort == b.ReasoningEffort;
}
