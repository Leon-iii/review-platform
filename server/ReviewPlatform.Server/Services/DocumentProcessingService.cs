using System.Security.Cryptography;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using UglyToad.PdfPig;

namespace ReviewPlatform.Server.Services;

public sealed partial class DocumentProcessingService
{
    private readonly IPdfPageRenderer pageRenderer;
    private readonly IWebHostEnvironment environment;
    private readonly IConfiguration configuration;
    private readonly ILogger<DocumentProcessingService> logger;
    private readonly DirectPdfTelemetryStore? directPdfTelemetry;
    private DocumentLimits Limits => configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();

    public DocumentProcessingService(IPdfPageRenderer pageRenderer, IWebHostEnvironment environment,
        IConfiguration configuration, ILogger<DocumentProcessingService> logger,
        DirectPdfTelemetryStore? directPdfTelemetry = null)
    {
        this.pageRenderer = pageRenderer;
        this.environment = environment;
        this.configuration = configuration;
        this.logger = logger;
        this.directPdfTelemetry = directPdfTelemetry;
    }

    public Task<RenderedDocumentPage> RenderStoredPageAsync(string sourceId, int pageNumber,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(ResolveStorageRoot(), $"{Guid.Parse(sourceId):D}.pdf");
        if (!File.Exists(path))
            throw new DocumentImportException("서버에 원본 PDF 파일이 없습니다. 추출된 개념은 계속 열람할 수 있습니다.");
        return pageRenderer.RenderAsync(path, pageNumber, cancellationToken);
    }

    // Source previews must not depend on job checkpoints, prompt versions,
    // current model settings or current import limits.
    public async Task<RenderedDocumentPage> SourceImageAsync(string sourceId, int pageNumber,
        CancellationToken cancellationToken)
    {
        if (!Guid.TryParseExact(sourceId, "D", out _))
            throw new DocumentImportException("올바르지 않은 PDF 자료 ID입니다.");
        var path = Path.Combine(ResolveStorageRoot(), $"{sourceId}.pdf");
        if (!File.Exists(path))
            throw new DocumentImportException("원본 PDF를 찾을 수 없습니다. 개념은 계속 열람할 수 있습니다.");
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            using var pdf = PdfDocument.Open(path);
            if (pageNumber < 1 || pageNumber > pdf.NumberOfPages)
                throw new DocumentImportException("올바르지 않은 PDF 출처 페이지입니다.");
        }
        catch (DocumentImportException) { throw; }
        catch (Exception exception)
        {
            throw new DocumentImportException("원본 PDF를 읽지 못했습니다. 파일이 손상되었거나 암호화되어 있는지 확인해 주세요.", exception);
        }
        return await pageRenderer.RenderAsync(path, pageNumber, cancellationToken);
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

    internal static IReadOnlyList<GeneratedConceptDraft> ValidateConcepts(
        IReadOnlyList<GeneratedConceptDraft> concepts,
        IEnumerable<int> pages)
    {
        var allowedPages = pages.ToHashSet();
        var validated = new List<GeneratedConceptDraft>(concepts.Count);
        foreach (var concept in concepts)
        {
            if (concept is null || concept.Title is null || concept.Content is null || concept.PageNumbers is null)
                throw new LlmProviderRequestException("LLM이 올바르지 않은 개념 추출 결과를 반환했습니다.");
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

}
