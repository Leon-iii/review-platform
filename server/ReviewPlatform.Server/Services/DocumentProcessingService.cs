using System.Security.Cryptography;
using System.Text;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public sealed class DocumentProcessingService
{
    private const long MaximumFileSize = 25 * 1024 * 1024;
    private const int MaximumPageCount = 300;
    private const int MaximumTotalCharacters = 300_000;
    private const int TargetChunkCharacters = 8_000;
    private const int MaximumPagesPerConceptChunk = 8;
    private const int MinimumReliableCharactersPerPage = 10;
    private const int MaximumVisionPagesPerImport = 50;
    private readonly IPdfTextExtractor textExtractor;
    private readonly IPdfPageRenderer pageRenderer;
    private readonly IDocumentPageTextCache pageTextCache;
    private readonly ILlmProviderResolver providerResolver;
    private readonly IWebHostEnvironment environment;
    private readonly IConfiguration configuration;
    private readonly ILogger<DocumentProcessingService> logger;

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
        if (length is < 1 or > MaximumFileSize)
        {
            throw new DocumentImportException(
                "PDF 파일은 25MB 이하만 가져올 수 있습니다.");
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
                await content.CopyToAsync(output, cancellationToken);
            }

            if (new FileInfo(temporaryPath).Length > MaximumFileSize)
            {
                throw new DocumentImportException(
                    "PDF 파일은 25MB 이하만 가져올 수 있습니다.");
            }
            await ValidatePdfSignatureAsync(temporaryPath, cancellationToken);
            var contentHash = await ComputeHashAsync(
                temporaryPath,
                cancellationToken);
            var extraction = textExtractor.Extract(temporaryPath);
            if (extraction.PageCount is < 1 or > MaximumPageCount)
            {
                throw new DocumentImportException(
                    $"PDF는 최대 {MaximumPageCount}페이지까지 가져올 수 있습니다.");
            }

            var prepared = await PreparePagesAsync(
                temporaryPath,
                Path.GetFileName(fileName),
                extraction.Pages,
                async () => visionProvider ??=
                    await ResolveVisionProviderAsync(cancellationToken),
                cancellationToken);
            visionProvider = prepared.VisionProvider;
            var usablePages = LimitExtractedText(prepared.Pages);
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
            foreach (var chunk in BuildChunks(usablePages))
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
        CancellationToken cancellationToken)
    {
        var pagesRequiringVision = extractedPages
            .Where(page =>
                page.RequiresVision || !HasReliableTextLayer(page.Text))
            .Select(page => page.PageNumber)
            .ToHashSet();
        if (pagesRequiringVision.Count > MaximumVisionPagesPerImport)
        {
            throw new DocumentImportException(
                $"이미지 분석이 필요한 페이지가 너무 많습니다. " +
                $"현재 한 번에 최대 {MaximumVisionPagesPerImport}페이지까지 처리할 수 있습니다.");
        }

        ILLMProvider? visionProvider = null;
        var pages = new List<ExtractedDocumentPage>(extractedPages.Count);
        var metadata = new List<DocumentPageExtractionMetadata>(
            extractedPages.Count);
        foreach (var page in extractedPages.OrderBy(page => page.PageNumber))
        {
            cancellationToken.ThrowIfCancellationRequested();
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
                continue;
            }

            visionProvider ??= await resolveVisionProvider();
            var rendered = await pageRenderer.RenderAsync(
                pdfPath,
                page.PageNumber,
                cancellationToken);
            var text = await pageTextCache.GetAsync(
                rendered.ContentHash,
                visionProvider.ProviderName,
                visionProvider.ModelName,
                DocumentVisionPrompt.Version,
                cancellationToken);
            if (text is null)
            {
                var result = await visionProvider.ExtractPageContentAsync(
                    new DocumentVisionInput(
                        fileName,
                        page.PageNumber,
                        rendered.MimeType,
                        rendered.ImageBytes,
                        rendered.ContentHash,
                        DocumentVisionPrompt.Version),
                    cancellationToken);
                text = result.Text.Trim();
                await pageTextCache.SetAsync(
                    rendered.ContentHash,
                    visionProvider.ProviderName,
                    visionProvider.ModelName,
                    DocumentVisionPrompt.Version,
                    text,
                    cancellationToken);
            }
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
                extractionMethod));
            metadata.Add(new DocumentPageExtractionMetadata(
                page.PageNumber,
                extractionMethod,
                rendered.ContentHash));
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

    private static List<ExtractedDocumentPage> LimitExtractedText(
        IReadOnlyList<ExtractedDocumentPage> pages)
    {
        var result = new List<ExtractedDocumentPage>(pages.Count);
        var remaining = MaximumTotalCharacters;
        foreach (var page in pages)
        {
            if (remaining <= 0) break;
            var text = page.Text.Length <= remaining
                ? page.Text
                : page.Text[..remaining];
            result.Add(page with { Text = text });
            remaining -= text.Length;
        }
        return result;
    }

    private static int CountContentCharacters(string value) =>
        value.Count(character => !char.IsWhiteSpace(character));

    private static IReadOnlyList<IReadOnlyList<ExtractedDocumentPage>> BuildChunks(
        IReadOnlyList<ExtractedDocumentPage> pages)
    {
        var chunks = new List<IReadOnlyList<ExtractedDocumentPage>>();
        var current = new List<ExtractedDocumentPage>();
        var currentLength = 0;
        foreach (var page in pages.Where(page => !string.IsNullOrWhiteSpace(page.Text)))
        {
            for (var offset = 0; offset < page.Text.Length; offset += TargetChunkCharacters)
            {
                var segmentLength = Math.Min(
                    TargetChunkCharacters,
                    page.Text.Length - offset);
                var segment = new ExtractedDocumentPage(
                    page.PageNumber,
                    page.Text.Substring(offset, segmentLength),
                    page.ExtractionMethod);
                if (current.Count > 0 &&
                    (currentLength + segment.Text.Length > TargetChunkCharacters ||
                     current.Count >= MaximumPagesPerConceptChunk))
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
            var importance = concept.Importance.Trim().ToLowerInvariant();
            if (title.Length is < 1 or > 200 ||
                content.Length is < 1 or > 8_000 ||
                pageNumbers.Count == 0 ||
                pageNumbers.Any(page => !allowedPages.Contains(page)) ||
                importance is not "low" and not "medium" and not "high")
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
