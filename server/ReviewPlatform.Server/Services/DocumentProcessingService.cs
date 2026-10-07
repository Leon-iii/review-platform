using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public sealed partial class DocumentProcessingService
{
    private const int MaximumPageCount = 300;
    private const int TargetChunkCharacters = 8_000;
    private const int MaximumPagesPerConceptChunk = 8;
    private const int MinimumReliableCharactersPerPage = 10;
    private readonly IPdfTextExtractor textExtractor;
    private readonly IPdfPageRenderer pageRenderer;
    private readonly IDocumentPageTextCache pageTextCache;
    private readonly ILlmProviderResolver providerResolver;
    private readonly IWebHostEnvironment environment;
    private readonly IConfiguration configuration;
    private readonly ILogger<DocumentProcessingService> logger;
    private DocumentLimits Limits => configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();

    public DocumentProcessingService(
        IPdfTextExtractor textExtractor,
        IPdfPageRenderer pageRenderer,
        IDocumentPageTextCache pageTextCache,
        ILlmProviderResolver providerResolver,
        IWebHostEnvironment environment,
        IConfiguration configuration,
        ILogger<DocumentProcessingService> logger)
    {
        this.textExtractor = textExtractor;
        this.pageRenderer = pageRenderer;
        this.pageTextCache = pageTextCache;
        this.providerResolver = providerResolver;
        this.environment = environment;
        this.configuration = configuration;
        this.logger = logger;
    }

    public DocumentProcessingService(
        IPdfTextExtractor textExtractor,
        IPdfPageRenderer pageRenderer,
        IDocumentPageTextCache pageTextCache,
        ILLMProvider provider,
        IWebHostEnvironment environment,
        IConfiguration configuration,
        ILogger<DocumentProcessingService> logger)
        : this(
            textExtractor,
            pageRenderer,
            pageTextCache,
            new FixedLlmProviderResolver(provider),
            environment,
            configuration,
            logger)
    {
    }

    public async Task<ImportDocumentResponse> ImportPdfAsync(
        Stream content,
        string fileName,
        long length,
        CancellationToken cancellationToken = default)
    {
        if (length < 1 || length > Limits.MaximumFileSize)
        {
            throw new DocumentImportException(
                $"PDF 파일은 {Limits.MaximumFileSizeMb}MB 이하만 가져올 수 있습니다.");
        }
        if (!Path.GetExtension(fileName).Equals(
            ".pdf",
            StringComparison.OrdinalIgnoreCase))
        {
            throw new DocumentImportException("PDF 파일만 가져올 수 있습니다.");
        }

        var sourceId = Guid.NewGuid().ToString();
        var storageRoot = ResolveStorageRoot();
        Directory.CreateDirectory(storageRoot);
        var temporaryPath = Path.Combine(storageRoot, $".{sourceId}.upload");
        var finalPath = Path.Combine(storageRoot, $"{sourceId}.pdf");
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        ILLMProvider? conceptProvider = null;
        ILLMProvider? visionProvider = null;

        try
        {
            await using (var output = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                81920,
                FileOptions.Asynchronous))
            {
                await CopyBoundedAsync(content, output, length, Limits.MaximumFileSize, cancellationToken);
            }

            if (new FileInfo(temporaryPath).Length > Limits.MaximumFileSize)
            {
                throw new DocumentImportException(
                    $"PDF 파일은 {Limits.MaximumFileSizeMb}MB 이하만 가져올 수 있습니다.");
            }
            await ValidatePdfSignatureAsync(temporaryPath, cancellationToken);
            var contentHash = await ComputeHashAsync(
                temporaryPath,
                cancellationToken);
            var extraction = textExtractor.Extract(temporaryPath, cancellationToken,
                Limits.MaximumPages, Limits.MaximumExtractedCharacters);
            if (extraction.PageCount < 1 || extraction.PageCount > Limits.MaximumPages)
            {
                throw new DocumentImportException(
                    $"PDF는 최대 {Limits.MaximumPages}페이지까지 가져올 수 있습니다.");
            }

            var prepared = await PreparePagesAsync(
                temporaryPath,
                Path.GetFileName(fileName),
                extraction.Pages,
                async () => visionProvider ??=
                    await ResolveVisionProviderAsync(cancellationToken),
                cancellationToken);
            visionProvider = prepared.VisionProvider;
            var usablePages = LimitExtractedText(DocumentReviewContent.AnnotatedPages(prepared.Pages));
            if (usablePages.Sum(page => CountContentCharacters(page.Text)) < 20)
            {
                throw new DocumentImportException(
                    "PDF에서 학습할 수 있는 텍스트를 찾지 못했습니다. " +
                    "빈 페이지이거나 이미지가 너무 흐리지 않은지 확인해 주세요.");
            }

            conceptProvider = await providerResolver.ResolveAsync(
                LlmPurposes.ConceptExtraction,
                cancellationToken);
            var concepts = new List<GeneratedConceptDraft>();
            foreach (var chunk in BuildChunks(usablePages, conceptProvider))
            {
                var input = new ConceptExtractionInput(
                    sourceId,
                    Path.GetFileName(fileName),
                    chunk,
                    ConceptExtractionPrompt.Version);
                var generated = await conceptProvider.ExtractConceptsAsync(
                    input,
                    cancellationToken);
                concepts.AddRange(ValidateConcepts(generated, chunk));
            }

            var mergedConcepts = MergeDuplicateConcepts(concepts);
            if (mergedConcepts.Count == 0)
            {
                throw new DocumentImportException(
                    "PDF에서 검토할 학습 개념을 추출하지 못했습니다.");
            }

            File.Move(temporaryPath, finalPath);
            var importedAt = DateTimeOffset.UtcNow;
            logger.LogInformation(
                "PDF import succeeded. SourceId={SourceId} Provider={Provider} " +
                "Model={Model} PageCount={PageCount} ExtractedCharacters={ExtractedCharacters} " +
                "VisionPageCount={VisionPageCount} ConceptCount={ConceptCount} " +
                "DurationMs={DurationMs}",
                sourceId,
                conceptProvider.ProviderName,
                conceptProvider.ModelName,
                extraction.PageCount,
                usablePages.Sum(page => page.Text.Length),
                prepared.Metadata.Count(page =>
                    page.ExtractionMethod is DocumentExtractionMethods.VisionOcr or
                        DocumentExtractionMethods.Hybrid),
                mergedConcepts.Count,
                stopwatch.ElapsedMilliseconds);

            return new ImportDocumentResponse(
                new DocumentSourceMetadata(
                    sourceId,
                    Path.GetFileName(fileName),
                    contentHash,
                    extraction.PageCount,
                    DetermineExtractionMethod(prepared.Metadata),
                    importedAt),
                mergedConcepts,
                prepared.Metadata);
        }
        catch (Exception exception)
        {
            logger.LogError(
                exception,
                "PDF import failed. SourceId={SourceId} Provider={Provider} " +
                "Model={Model} FileSize={FileSize} DurationMs={DurationMs}",
                sourceId,
                conceptProvider?.ProviderName ?? visionProvider?.ProviderName ?? "unresolved",
                conceptProvider?.ModelName ?? visionProvider?.ModelName ?? "unresolved",
                length,
                stopwatch.ElapsedMilliseconds);
            TryDelete(temporaryPath);
            throw;
        }
    }

    // Completed pages/chunks are checkpointed independently, so retries and
    // server restarts never need to repeat successful LLM calls.
    public async Task<ImportDocumentResponse> ProcessStoredPdfAsync(
        string sourceId, string fileName, ILLMProvider conceptProvider,
        Func<Task<ILLMProvider>> resolveVisionProvider, DocumentCheckpoint checkpoint,
        Func<DocumentCheckpoint, Task> saveCheckpoint, CancellationToken cancellationToken)
    {
        var path = Path.Combine(ResolveStorageRoot(), $"{Guid.Parse(sourceId):D}.pdf");
        if (checkpoint.ConceptPromptVersion != ConceptExtractionPrompt.Version ||
            checkpoint.VisionPromptVersion != DocumentVisionPrompt.Version)
            throw new DocumentImportException("서버의 분석 지침 버전이 변경되었습니다. PDF를 새 작업으로 다시 업로드해 주세요.");
        checkpoint.Stage = "reading";
        await saveCheckpoint(checkpoint);
        var extraction = textExtractor.Extract(path, cancellationToken,
            Limits.MaximumPages, Limits.MaximumExtractedCharacters);
        if (extraction.PageCount < 1 || extraction.PageCount > Limits.MaximumPages)
            throw new DocumentImportException($"PDF는 최대 {Limits.MaximumPages}페이지까지 가져올 수 있습니다.");
        checkpoint.TotalPages = extraction.PageCount;
        checkpoint.Stage = "pages";
        await saveCheckpoint(checkpoint);
        var prepared = await PreparePagesAsync(path, fileName, extraction.Pages,
            resolveVisionProvider, cancellationToken, checkpoint, saveCheckpoint);
        if (checkpoint.ReviewBeforeConcepts && !checkpoint.ReviewConfirmed)
        {
            checkpoint.Stage = "awaiting_review";
            await saveCheckpoint(checkpoint);
            throw new DocumentReviewRequiredException();
        }
        var usablePages = LimitExtractedText(checkpoint.ReviewBeforeConcepts
            ? DocumentReviewContent.ConfirmedPages(checkpoint) : DocumentReviewContent.AnnotatedPages(prepared.Pages));
        if (usablePages.Sum(page => CountContentCharacters(page.Text)) < 20)
            throw new DocumentImportException("PDF에서 학습할 수 있는 텍스트를 찾지 못했습니다.");
        var chunks = BuildChunks(usablePages, conceptProvider);
        checkpoint.TotalChunks = chunks.Count;
        checkpoint.Stage = "concepts";
        await saveCheckpoint(checkpoint);
        for (var index = checkpoint.Chunks.Count; index < chunks.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var chunk = chunks[index];
            var generated = await conceptProvider.ExtractConceptsAsync(
                new ConceptExtractionInput(sourceId, fileName, chunk, ConceptExtractionPrompt.Version),
                cancellationToken);
            checkpoint.Chunks.Add(ValidateConcepts(generated, chunk).ToList());
            await saveCheckpoint(checkpoint);
        }
        var concepts = MergeDuplicateConcepts(checkpoint.Chunks.SelectMany(chunk => chunk).ToList());
        if (concepts.Count == 0)
            throw new DocumentImportException("PDF에서 검토할 학습 개념을 추출하지 못했습니다.");
        return new ImportDocumentResponse(new DocumentSourceMetadata(sourceId, fileName,
            await ComputeHashAsync(path, cancellationToken), extraction.PageCount,
            DetermineExtractionMethod(prepared.Metadata), DateTimeOffset.UtcNow), concepts, prepared.Metadata);
    }

    public Task<RenderedDocumentPage> RenderStoredPageAsync(string sourceId, int pageNumber,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(ResolveStorageRoot(), $"{Guid.Parse(sourceId):D}.pdf");
        if (!File.Exists(path))
            throw new DocumentImportException("서버에 원본 PDF 파일이 없습니다. 보관된 OCR 텍스트는 계속 열람할 수 있습니다.");
        return pageRenderer.RenderAsync(path, pageNumber, cancellationToken);
    }

    public async Task StoreUploadAsync(string sourceId, Stream content, string fileName,
        long length, CancellationToken cancellationToken)
    {
        if (!Guid.TryParseExact(sourceId, "D", out _) || fileName.Length is < 1 or > 200 ||
            !Path.GetExtension(fileName).Equals(".pdf", StringComparison.OrdinalIgnoreCase))
            throw new DocumentImportException("올바른 PDF 파일과 작업 ID를 지정해 주세요.");
        if (length < 1 || length > Limits.MaximumFileSize)
            throw new DocumentImportException($"PDF 파일은 {Limits.MaximumFileSizeMb}MB 이하만 가져올 수 있습니다.");
        var root = ResolveStorageRoot();
        Directory.CreateDirectory(root);
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(root))!);
        if (drive.AvailableFreeSpace < length + (long)Limits.MinimumFreeDiskSpaceMb * 1024 * 1024)
            throw new DocumentImportException("서버의 디스크 여유 공간이 부족합니다.");
        var temporary = Path.Combine(root, $".{sourceId}.{Guid.NewGuid():N}.upload");
        try
        {
            await using (var output = new FileStream(temporary, FileMode.CreateNew,
                FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous))
                await CopyBoundedAsync(content, output, length, Limits.MaximumFileSize, cancellationToken);
            await ValidatePdfSignatureAsync(temporary, cancellationToken);
            var final = Path.Combine(root, $"{sourceId}.pdf");
            if (File.Exists(final))
            {
                if (await ComputeHashAsync(final, cancellationToken) != await ComputeHashAsync(temporary, cancellationToken))
                    throw new DocumentImportException("동일한 작업 ID로 다른 PDF를 업로드할 수 없습니다.");
                File.Delete(temporary);
            }
            else File.Move(temporary, final);
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    internal static async Task CopyBoundedAsync(Stream input, Stream output,
        long expectedLength, long maximumLength, CancellationToken cancellationToken)
    {
        var buffer = new byte[81920];
        long written = 0;
        int count;
        while ((count = await input.ReadAsync(buffer, cancellationToken)) != 0)
        {
            written += count;
            if (written > maximumLength || written > expectedLength)
                throw new DocumentImportException("PDF 파일 크기가 업로드 제한을 초과했거나 전송 중 변경되었습니다.");
            await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
        }
        if (written != expectedLength)
            throw new DocumentImportException("PDF 업로드가 완료되지 않았습니다. 다시 시도해 주세요.");
    }

    public void DeletePdf(string sourceId)
    {
        if (!Guid.TryParse(sourceId, out var parsed) ||
            !parsed.ToString().Equals(sourceId, StringComparison.OrdinalIgnoreCase))
        {
            throw new DocumentImportException("올바르지 않은 PDF 자료 ID입니다.");
        }
        var path = Path.Combine(ResolveStorageRoot(), $"{sourceId}.pdf");
        try
        {
            if (File.Exists(path)) File.Delete(path);
            logger.LogInformation("PDF source deleted. SourceId={SourceId}", sourceId);
        }
        catch (IOException exception)
        {
            throw new DocumentImportException(
                "PDF 원본 파일을 삭제하지 못했습니다.",
                exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new DocumentImportException(
                "PDF 원본 파일을 삭제할 권한이 없습니다.",
                exception);
        }
    }

    private async Task<PreparedPages> PreparePagesAsync(
        string pdfPath,
        string fileName,
        IReadOnlyList<ExtractedDocumentPage> extractedPages,
        Func<Task<ILLMProvider>> resolveVisionProvider,
        CancellationToken cancellationToken,
        DocumentCheckpoint? checkpoint = null,
        Func<DocumentCheckpoint, Task>? saveCheckpoint = null)
    {
        var pagesRequiringVision = extractedPages
            .Where(page =>
                page.RequiresVision || !HasReliableTextLayer(page.Text))
            .Select(page => page.PageNumber)
            .ToHashSet();
        ILLMProvider? visionProvider = null;
        var pages = checkpoint?.Pages ?? new List<ExtractedDocumentPage>(extractedPages.Count);
        var metadata = checkpoint?.Metadata ?? new List<DocumentPageExtractionMetadata>(extractedPages.Count);
        var completed = pages.Select(page => page.PageNumber).ToHashSet();
        foreach (var page in extractedPages.OrderBy(page => page.PageNumber))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (completed.Contains(page.PageNumber)) continue;
            var hasReliableTextLayer = HasReliableTextLayer(page.Text);
            if (!pagesRequiringVision.Contains(page.PageNumber))
            {
                var textLayerText = page.Text.Trim();
                pages.Add(page with
                {
                    Text = textLayerText,
                    ExtractionMethod = DocumentExtractionMethods.TextLayer
                });
                metadata.Add(new DocumentPageExtractionMetadata(
                    page.PageNumber,
                    DocumentExtractionMethods.TextLayer,
                    HashText(textLayerText)));
                if (pages.Sum(item => (long)item.Text.Length) > Limits.MaximumExtractedCharacters)
                    throw new DocumentImportException("추출된 텍스트가 서버의 안전 제한을 초과했습니다. PDF를 나누어 가져와 주세요.");
                if (checkpoint is not null && saveCheckpoint is not null)
                    await saveCheckpoint(checkpoint);
                continue;
            }

            visionProvider ??= await resolveVisionProvider();
            var rendered = await pageRenderer.RenderAsync(
                pdfPath,
                page.PageNumber,
                cancellationToken);
            var cached = await pageTextCache.GetAsync(
                rendered.ContentHash,
                visionProvider.ProviderName,
                visionProvider.ModelName,
                DocumentVisionPrompt.Version,
                cancellationToken);
            DocumentVisionResult? result = null;
            if (cached is not null)
            {
                try { result = DocumentVisionOutput.Parse(cached, allowPlainText: true); }
                catch (Exception exception) when (exception is JsonException or LlmProviderRequestException)
                {
                    logger.LogWarning("Ignoring invalid document OCR cache. PageNumber={PageNumber}", page.PageNumber);
                }
            }
            if (result is null)
            {
                result = DocumentVisionOutput.Normalize(await visionProvider.ExtractPageContentAsync(
                    new DocumentVisionInput(
                        fileName,
                        page.PageNumber,
                        rendered.MimeType,
                        rendered.ImageBytes,
                        rendered.ContentHash,
                        DocumentVisionPrompt.Version),
                    cancellationToken));
                await pageTextCache.SetAsync(
                    rendered.ContentHash,
                    visionProvider.ProviderName,
                    visionProvider.ModelName,
                    DocumentVisionPrompt.Version,
                    JsonSerializer.Serialize(new { text = result.Regions is null ? result.Text : null, regions = result.Regions },
                        new JsonSerializerOptions(JsonSerializerDefaults.Web)),
                    cancellationToken);
            }
            var text = result.Text;
            if (text.Length > 50_000)
            {
                throw new LlmProviderRequestException(
                    $"LLM이 PDF {page.PageNumber}페이지에 너무 긴 OCR 결과를 반환했습니다.");
            }
            var extractionMethod = hasReliableTextLayer && text.Length > 0
                ? DocumentExtractionMethods.Hybrid
                : hasReliableTextLayer
                    ? DocumentExtractionMethods.TextLayer
                    : DocumentExtractionMethods.VisionOcr;
            var extractedText = extractionMethod == DocumentExtractionMethods.Hybrid
                ? $"{page.Text.Trim()}\n\n[페이지 시각 정보]\n{text}"
                : extractionMethod == DocumentExtractionMethods.TextLayer
                    ? page.Text.Trim()
                    : text;
            pages.Add(new ExtractedDocumentPage(
                page.PageNumber,
                extractedText,
                extractionMethod,
                Regions: result.Regions));
            metadata.Add(new DocumentPageExtractionMetadata(
                page.PageNumber,
                extractionMethod,
                rendered.ContentHash));
            if (pages.Sum(item => (long)item.Text.Length) > Limits.MaximumExtractedCharacters)
                throw new DocumentImportException("추출된 텍스트가 서버의 안전 제한을 초과했습니다. PDF를 나누어 가져와 주세요.");
            if (checkpoint is not null && saveCheckpoint is not null)
                await saveCheckpoint(checkpoint);
        }
        return new PreparedPages(pages, metadata, visionProvider);
    }

    private async Task<ILLMProvider> ResolveVisionProviderAsync(
        CancellationToken cancellationToken) =>
        await providerResolver.ResolveAsync(
            LlmPurposes.DocumentVision,
            cancellationToken);

    private static bool HasReliableTextLayer(string text)
    {
        var content = text.Where(character => !char.IsWhiteSpace(character)).ToList();
        if (content.Count < MinimumReliableCharactersPerPage) return false;
        var readable = content.Count(character =>
            char.IsLetterOrDigit(character) ||
            char.IsPunctuation(character) ||
            char.IsSymbol(character));
        return readable >= content.Count * 0.7;
    }

    private static string DetermineExtractionMethod(
        IReadOnlyList<DocumentPageExtractionMetadata> pages)
    {
        if (pages.Any(page =>
                page.ExtractionMethod == DocumentExtractionMethods.Hybrid))
        {
            return DocumentExtractionMethods.Hybrid;
        }
        var hasTextLayer = pages.Any(page =>
            page.ExtractionMethod == DocumentExtractionMethods.TextLayer);
        var hasVision = pages.Any(page =>
            page.ExtractionMethod is DocumentExtractionMethods.VisionOcr or
                DocumentExtractionMethods.Hybrid);
        if (hasTextLayer && hasVision) return DocumentExtractionMethods.Hybrid;
        return hasVision
            ? DocumentExtractionMethods.VisionOcr
            : DocumentExtractionMethods.TextLayer;
    }

    private static string HashText(string text) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)))
            .ToLowerInvariant();

    private string ResolveStorageRoot()
    {
        var configured = configuration["Documents:StoragePath"];
        if (string.IsNullOrWhiteSpace(configured))
        {
            return Path.Combine(environment.ContentRootPath, "App_Data", "sources");
        }
        return Path.IsPathRooted(configured)
            ? configured
            : Path.GetFullPath(Path.Combine(environment.ContentRootPath, configured));
    }

    private static async Task ValidatePdfSignatureAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var signature = new byte[5];
        await using var stream = File.OpenRead(path);
        var read = await stream.ReadAsync(signature, cancellationToken);
        if (read != signature.Length ||
            !signature.AsSpan().SequenceEqual("%PDF-"u8))
        {
            throw new DocumentImportException("올바른 PDF 파일이 아닙니다.");
        }
    }

    private static async Task<string> ComputeHashAsync(
        string path,
        CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private List<ExtractedDocumentPage> LimitExtractedText(
        IReadOnlyList<ExtractedDocumentPage> pages)
    {
        if (pages.Sum(page => (long)page.Text.Length) > Limits.MaximumExtractedCharacters)
            throw new DocumentImportException("추출된 텍스트가 서버의 안전 제한을 초과했습니다. PDF를 나누어 가져와 주세요.");
        return pages.ToList();
    }

    private static int CountContentCharacters(string value) =>
        value.Count(character => !char.IsWhiteSpace(character));

    private static IReadOnlyList<IReadOnlyList<ExtractedDocumentPage>> BuildChunks(
        IReadOnlyList<ExtractedDocumentPage> pages,
        ILLMProvider provider)
    {
        // Small batches are a local Ollama performance policy, not a cloud limit.
        var isLocal = provider.ProviderName == "ollama";
        // Cloud profiles retain their automatic policy. This larger bound only
        // splits long documents to keep a single request/result manageable.
        if (!isLocal && pages.Count <= 32 && pages.Sum(page => (long)page.Text.Length) <= 64_000)
            return [pages];
        var targetCharacters = !isLocal ? 64_000 : provider.ContextWindowTokens is int contextWindow
            ? Math.Max(1_024, (contextWindow / 2 - 1_000) * 2)
            : TargetChunkCharacters;
        targetCharacters = Math.Min(targetCharacters, 64_000);
        var maximumPages = !isLocal ? 32 : provider.ContextWindowTokens is null
            ? MaximumPagesPerConceptChunk
            : MaximumPageCount;
        var chunks = new List<IReadOnlyList<ExtractedDocumentPage>>();
        var current = new List<ExtractedDocumentPage>();
        var currentLength = 0;
        foreach (var page in pages.Where(page => !string.IsNullOrWhiteSpace(page.Text)))
        {
            foreach (var text in DocumentExtractionSegments.Split(page.Text, targetCharacters))
            {
                var segment = new ExtractedDocumentPage(
                    page.PageNumber,
                    text,
                    page.ExtractionMethod);
                if (current.Count > 0 &&
                    (currentLength + segment.Text.Length > targetCharacters ||
                     current.Count >= maximumPages))
                {
                    chunks.Add(current.ToList());
                    current.Clear();
                    currentLength = 0;
                }
                current.Add(segment);
                currentLength += segment.Text.Length;
            }
        }
        if (current.Count > 0) chunks.Add(current);
        return chunks;
    }

    private static IReadOnlyList<GeneratedConceptDraft> ValidateConcepts(
        IReadOnlyList<GeneratedConceptDraft> concepts,
        IReadOnlyList<ExtractedDocumentPage> pages)
    {
        var allowedPages = pages.Select(page => page.PageNumber).ToHashSet();
        var validated = new List<GeneratedConceptDraft>(concepts.Count);
        foreach (var concept in concepts)
        {
            var title = concept.Title.Trim();
            var content = concept.Content.Trim();
            var pageNumbers = concept.PageNumbers
                .Distinct()
                .Order()
                .ToList();
            var importance = ConceptImportanceLevels.Normalize(concept.Importance);
            if (title.Length is < 1 or > 200 ||
                content.Length is < 1 or > 8_000 ||
                pageNumbers.Count == 0 ||
                pageNumbers.Any(page => !allowedPages.Contains(page)) ||
                importance is null)
            {
                throw new LlmProviderRequestException(
                    "LLM이 올바르지 않은 개념 추출 결과를 반환했습니다.");
            }
            validated.Add(concept with
            {
                Title = title,
                Content = content,
                PageNumbers = pageNumbers,
                Importance = importance
            });
        }
        return validated;
    }

    private static IReadOnlyList<GeneratedConceptDraft> MergeDuplicateConcepts(
        IReadOnlyList<GeneratedConceptDraft> concepts)
    {
        return concepts
            .GroupBy(concept => concept.Title, StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var first = group.First();
                return first with
                {
                    PageNumbers = group
                        .SelectMany(concept => concept.PageNumbers)
                        .Distinct()
                        .Order()
                        .ToList()
                };
            })
            .OrderBy(concept => concept.PageNumbers.First())
            .ThenBy(concept => concept.Title, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // Best-effort cleanup; the original import failure is more useful.
        }
    }

    private sealed record PreparedPages(
        IReadOnlyList<ExtractedDocumentPage> Pages,
        IReadOnlyList<DocumentPageExtractionMetadata> Metadata,
        ILLMProvider? VisionProvider);
}
