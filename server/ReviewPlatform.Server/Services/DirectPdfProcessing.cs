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
    public int? DirectOutputBudget(IDirectPdfConceptProvider provider, long? inputTokens = null)
    {
        if (provider.MaximumPdfOutputTokens is not int maximum) return null;
        if (provider.PdfContextTokens is int context && inputTokens is long input)
            return (int)Math.Max(0, Math.Min(maximum, context - input - DirectLimits.ContextMarginTokens));
        return maximum;
    }
    public int DirectOutputSafetyThreshold => DirectLimits.OutputSafetyThresholdTokens;
    public int ConfiguredDirectTpm => Math.Max(1, DirectLimits.TokensPerMinute);

    public async Task<PdfPreflightPart> InspectDirectPartAsync(string id, string fileName,
        int totalPages, PdfPageRange range, IDirectPdfConceptProvider provider, CancellationToken cancellationToken)
    {
        var bytes = ReadSelectedPdf(id, range, totalPages);
        var budget = DirectOutputBudget(provider);
        var estimate = directPdfTelemetry?.Estimate(provider.PdfEstimationProfile, range.PageCount)
            ?? new PdfOutputEstimate(null, null, null, 0, "insufficient");
        var expected = estimate.Tokens;
        PdfPreflightPart Result(long? input, string state, IReadOnlyList<string> notes) =>
            new(range, bytes.LongLength, input, budget, expected, state, notes, DirectOutputSafetyThreshold, estimate);
        var messages = new List<string>();
        var status = "ready";
        // Individual native PDF inputs must be strictly below 50 MB.
        if (bytes.LongLength >= 50L * 1024 * 1024)
            return Result(null, "blocked", ["이 묶음은 OpenAI PDF 파일 입력의 50MB 제한을 넘습니다. 분할 지점을 선택해 주세요."]);
        if (budget is null)
            return Result(null, "unknown", ["이 모델의 API 출력 한도가 미등록되어 요청할 수 없습니다. 지원 정보가 등록된 모델을 선택해 주세요."]);
        PdfTokenCount count;
        try { count = await provider.CountPdfTokensAsync(new(id, fileName, bytes, range.PageCount, budget.Value), cancellationToken); }
        catch (PdfRateLimitException)
        { return Result(null, "waiting", ["입력 점검 API의 일시적 한도에 도달했습니다. 잠시 후 다시 점검해 주세요."]); }
        catch (LlmProviderRequestException e)
        { return Result(null, "unknown", [e.Message, "입력량 확인에 실패했습니다. 재점검하거나 불확실성을 확인한 뒤 진행할 수 있습니다."]); }
        budget = DirectOutputBudget(provider, count.InputTokens);
        var tpm = count.TokenLimit ?? ConfiguredDirectTpm;
        if (count.InputTokens > tpm || count.InputTokens > DirectLimits.InputSafetyLimit || budget < 16)
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
        if (expected >= DirectOutputSafetyThreshold)
        { if (status == "ready") status = "warning"; messages.Add("안전 기준 초과: 예상 출력이 분할 권장 기준에 도달했습니다. 분할을 권장하지만 확인 후 진행할 수 있고, 이 기준에서 응답을 강제로 자르지 않습니다."); }
        if (estimate.UpperTokens >= budget * 0.8)
        { if (status == "ready") status = "warning"; messages.Add("응답 잘림 위험: 실측 기반 예상 범위가 실제 API 출력 한도에 근접합니다. 분할을 강하게 권장합니다."); }
        if (estimate.Tokens is null)
        { if (status == "ready") status = "warning"; messages.Add("예측 자료 부족: 동일 모델·추론 수준·지침의 서로 다른 PDF 묶음 정상 완료 표본이 5개 이상 필요합니다. 출력 분량은 아직 예측할 수 없습니다."); }
        else if (estimate.Confidence == "low")
        { if (status == "ready") status = "warning"; messages.Add("예측 신뢰도 낮음: 현재 페이지 수가 실측 표본 범위 밖입니다. 실제 출력은 예상 범위를 벗어날 수 있습니다."); }
        if (status is not ("blocked" or "unknown") && count.RemainingTokens is int remaining && remaining < count.InputTokens + budget)
        { status = "waiting"; messages.Add("전체 한도에는 들어가지만 현재 API 여유가 부족합니다. 분할할 필요 없이 대기 후 재점검합니다."); }
        return Result(count.InputTokens, status, messages);
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
        if (checkpoint.Preflight?.BudgetPolicyVersion != DirectPdfBudgetPolicy.Version)
            throw new PdfSelectionRequiredException("PDF 출력 한도 정책이 변경되었습니다. 완료된 묶음은 유지되며 추출 설정에서 다시 점검해 주세요.");
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
            if (check.Status == "blocked" || check.OutputBudget is null) await RequireSelection(string.Join("\n", check.Messages));
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
                    var reservation = (check.InputTokens ?? ConfiguredDirectTpm / 2) + check.OutputBudget!.Value;
                    DirectNextRequest[provider.RateLimitKey] = DateTimeOffset.UtcNow.AddSeconds(
                        Math.Max(1, 60d * reservation / ConfiguredDirectTpm));
                    generated = await provider.ExtractPdfConceptsAsync(new(id, fileName,
                        ReadSelectedPdf(id, range, overview.PageCount), range.PageCount, check.OutputBudget!.Value,
                        $"{overview.ContentHash}:{range.FirstPage}:{range.LastPage}"), cancellationToken);
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
