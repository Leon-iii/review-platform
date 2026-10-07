using System.Collections.Concurrent;
using System.Security.Cryptography;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;

namespace ReviewPlatform.Server.Services;

public sealed record StoredPdfOverview(int PageCount, long FileSize, string ContentHash);
public sealed partial class DocumentProcessingService
{
    private DirectPdfLimits DirectLimits => configuration.GetSection("Documents:DirectPdf").Get<DirectPdfLimits>() ?? new();
    private string StoredPdfPath(string id)
    {
        if (!Guid.TryParseExact(id, "D", out _)) throw new DocumentImportException("올바르지 않은 PDF 작업 ID입니다.");
        return Path.Combine(ResolveStorageRoot(), $"{id}.pdf");
    }
    public StoredPdfOverview InspectStoredPdf(string id)
    {
        try
        {
            var path = StoredPdfPath(id);
            using var pdf = PdfDocument.Open(path);
            if (pdf.NumberOfPages < 1 || pdf.NumberOfPages > Limits.MaximumPages)
                throw new DocumentImportException($"PDF는 최대 {Limits.MaximumPages}페이지까지 가져올 수 있습니다.");
            using var stream = File.OpenRead(path);
            return new(pdf.NumberOfPages, stream.Length, Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant());
        }
        catch (DocumentImportException) { throw; }
        catch (Exception e) { throw new DocumentImportException("PDF 파일을 읽지 못했습니다. 손상되었거나 암호화된 파일인지 확인해 주세요.", e); }
    }
    public static IReadOnlyList<PdfPageRange> SelectedRanges(int pageCount, IReadOnlyList<int>? boundaries)
    {
        boundaries ??= [];
        if (boundaries.Count > pageCount - 1 || boundaries.Any(page => page < 1 || page >= pageCount) ||
            !boundaries.SequenceEqual(boundaries.Distinct().Order()))
            throw new DocumentImportException("분할 지점은 마지막 페이지를 제외한 페이지 번호를 오름차순으로 지정해 주세요.");
        var ranges = new List<PdfPageRange>();
        var first = 1;
        foreach (var last in boundaries.Append(pageCount)) { ranges.Add(new(first, last)); first = last + 1; }
        return ranges;
    }
    public byte[] ReadSelectedPdf(string id, PdfPageRange range, int totalPages)
    {
        var path = StoredPdfPath(id);
        if (range.FirstPage == 1 && range.LastPage == totalPages) return File.ReadAllBytes(path);
        try
        {
            using var document = PdfDocument.Open(path);
            var builder = new PdfDocumentBuilder();
            for (var page = range.FirstPage; page <= range.LastPage; page++) builder.AddPage(document, page);
            return builder.Build();
        }
        catch (Exception e) { throw new DocumentImportException("선택한 페이지의 PDF를 만들지 못했습니다. 원본은 보관됩니다.", e); }
    }
    public int DirectOutputBudget(IDirectPdfConceptProvider provider) =>
        Math.Clamp(DirectLimits.MaximumOutputTokens, 1, provider.MaximumPdfOutputTokens);
    public int ConfiguredDirectTpm => Math.Max(1, DirectLimits.TokensPerMinute);

    public async Task<PdfPreflightPart> InspectDirectPartAsync(string id, string fileName,
        int totalPages, PdfPageRange range, IDirectPdfConceptProvider provider, CancellationToken cancellationToken)
    {
        var bytes = ReadSelectedPdf(id, range, totalPages);
        var budget = DirectOutputBudget(provider);
        var expected = (long)range.PageCount * Math.Max(1, DirectLimits.EstimatedOutputTokensPerPage);
        var messages = new List<string>();
        var status = "ready";
        // Individual native PDF inputs must be strictly below 50 MB.
        if (bytes.LongLength >= 50L * 1024 * 1024)
            return new(range, bytes.LongLength, null, budget, expected, "blocked", ["이 묶음은 OpenAI PDF 파일 입력의 50MB 제한을 넘습니다. 분할 지점을 선택해 주세요."]);
        PdfTokenCount count;
        try { count = await provider.CountPdfTokensAsync(new(id, fileName, bytes, range.PageCount, budget), cancellationToken); }
        catch (PdfRateLimitException)
        { return new(range, bytes.LongLength, null, budget, expected, "waiting", ["입력 점검 API의 일시적 한도에 도달했습니다. 잠시 후 다시 점검해 주세요."]); }
        catch (LlmProviderRequestException e)
        { return new(range, bytes.LongLength, null, budget, expected, "unknown", [e.Message, "입력량 확인에 실패했습니다. 재점검하거나 불확실성을 확인한 뒤 진행할 수 있습니다."]); }
        var tpm = count.TokenLimit ?? ConfiguredDirectTpm;
        if (count.InputTokens > tpm || count.InputTokens > DirectLimits.InputSafetyLimit ||
            provider.PdfContextTokens is int context && count.InputTokens + budget + DirectLimits.ContextMarginTokens > context)
        {
            status = "blocked";
            messages.Add("입력량이 TPM 또는 입력·컨텍스트 안전 한도를 넘습니다. 개념 경계를 보고 직접 분할해 주세요.");
        }
        else if (count.InputTokens + budget > tpm * 0.8)
        {
            status = "warning";
            messages.Add("입력·출력 예산이 TPM에 근접합니다. 이는 보수적인 앱 점검 기준이며 API의 정확한 TPM 계산식은 아닙니다.");
        }
        if (provider.PdfContextTokens is null)
        { if (status == "ready") status = "unknown"; messages.Add("이 모델의 컨텍스트 한도는 등록되어 있지 않습니다."); }
        if (count.TokenLimit is null)
        { if (status == "ready") status = "warning"; messages.Add($"TPM은 서버 설정 {tpm:N0} 기준입니다. 계정의 실제 한도·다른 앱 사용량은 확인되지 않았습니다."); }
        if (expected >= budget * 0.8)
        { if (status == "ready") status = "warning"; messages.Add("출력 부족 우려: 페이지당 출력량 가정에 따른 낮은 신뢰도의 추정입니다. 분할을 권장합니다."); }
        if (status is not ("blocked" or "unknown") && count.RemainingTokens is int remaining && remaining < count.InputTokens + budget)
        { status = "waiting"; messages.Add("전체 한도에는 들어가지만 현재 API 여유가 부족합니다. 분할할 필요 없이 대기 후 재점검합니다."); }
        return new(range, bytes.LongLength, count.InputTokens, budget, expected, status, messages);
    }
    public static string PreflightStatus(IEnumerable<PdfPreflightPart> parts)
    {
        var states = parts.Select(part => part.Status).ToHashSet();
        return new[] { "blocked", "unknown", "waiting", "warning", "ready" }.First(states.Contains);
    }
    // Direct-only pacing does not alter other LLM workflows. Shared/account-wide
    // external traffic remains unknown and is handled by upstream 429 feedback.
    private static readonly ConcurrentDictionary<string, DateTimeOffset> DirectNextRequest = new();
    public async Task<ImportDocumentResponse> ProcessDirectPdfAsync(string id, string fileName,
        ILLMProvider llm, DocumentCheckpoint checkpoint, Func<DocumentCheckpoint, Task> save, CancellationToken cancellationToken)
    {
        if (llm is not IDirectPdfConceptProvider provider)
            throw new LlmProviderUnavailableException("PDF 직접 추출은 OpenAI PDF 입력을 지원하는 모델이 필요합니다.");
        if (checkpoint.DirectPromptVersion != DirectPdfConceptPrompt.Version)
            throw new DocumentImportException("직접 추출 지침이 변경되었습니다. 추출 화면에서 다시 점검해 주세요.");
        var overview = InspectStoredPdf(id);
        var ranges = SelectedRanges(overview.PageCount, checkpoint.SplitAfterPages);
        checkpoint.TotalPages = overview.PageCount;
        checkpoint.TotalChunks = ranges.Count;
        async Task RequireSelection(string message)
        {
            checkpoint.Preflight = null;
            await save(checkpoint);
            throw new PdfSelectionRequiredException(message);
        }
        for (var index = checkpoint.Chunks.Count; index < ranges.Count; index++)
        {
            var range = ranges[index];
            checkpoint.Stage = "preflight";
            await save(checkpoint);
            var check = await InspectDirectPartAsync(id, fileName, overview.PageCount, range, provider, cancellationToken);
            if (check.Status == "blocked") await RequireSelection(string.Join("\n", check.Messages));
            if (check.Status == "waiting" && check.InputTokens is null)
                await RequireSelection("입력 점검 API의 한도 회복 후 다시 점검해 주세요. 아직 개념 추출은 시작하지 않았습니다.");
            if (check.Status == "unknown" && checkpoint.Preflight?.Status != "unknown")
                await RequireSelection("입력량 확인에 실패했습니다. 추출 화면에서 다시 점검해 주세요.");
            if (check.Status == "waiting")
            {
                checkpoint.Stage = "rate_wait";
                await save(checkpoint);
                await Task.Delay(TimeSpan.FromSeconds(60), cancellationToken);
            }
            if (DirectNextRequest.TryGetValue(provider.RateLimitKey, out var next) && next > DateTimeOffset.UtcNow)
            {
                checkpoint.Stage = "rate_wait";
                await save(checkpoint);
                var delay = next - DateTimeOffset.UtcNow;
                if (delay > TimeSpan.Zero) await Task.Delay(delay, cancellationToken);
            }
            IReadOnlyList<GeneratedConceptDraft>? generated = null;
            for (var attempt = 0; attempt < 4; attempt++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    checkpoint.Stage = "direct_concepts";
                    await save(checkpoint);
                    var reservation = (check.InputTokens ?? ConfiguredDirectTpm / 2) + check.OutputBudget;
                    DirectNextRequest[provider.RateLimitKey] = DateTimeOffset.UtcNow.AddSeconds(
                        Math.Max(1, 60d * reservation / ConfiguredDirectTpm));
                    generated = await provider.ExtractPdfConceptsAsync(new(id, fileName,
                        ReadSelectedPdf(id, range, overview.PageCount), range.PageCount, check.OutputBudget), cancellationToken);
                    break;
                }
                catch (PdfRateLimitException e) when (attempt < 3)
                {
                    checkpoint.Stage = "rate_wait";
                    await save(checkpoint);
                    await Task.Delay(e.Delay + TimeSpan.FromMilliseconds(Random.Shared.Next(100, 600)), cancellationToken);
                }
            }
            var localPages = Enumerable.Range(1, range.PageCount);
            var validated = ValidateConcepts(generated!, localPages);
            if (validated.Count == 0) throw new DocumentImportException("이 묶음에서 개념을 추출하지 못했습니다.");
            checkpoint.Chunks.Add(validated.Select(concept => concept with
            { PageNumbers = concept.PageNumbers.Select(page => page + range.FirstPage - 1).ToArray() }).ToList());
            await save(checkpoint);
        }
        var concepts = MergeDuplicateConcepts(checkpoint.Chunks.SelectMany(chunk => chunk).ToList());
        return new(new(id, fileName, overview.ContentHash, overview.PageCount, "directPdf", DateTimeOffset.UtcNow), concepts, []);
    }
}
