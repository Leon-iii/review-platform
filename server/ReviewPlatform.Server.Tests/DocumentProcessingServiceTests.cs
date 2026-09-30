using System.Text;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DocumentProcessingServiceTests : IAsyncLifetime
{
    private readonly string temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"review-platform-document-{Guid.NewGuid()}");

    public ValueTask InitializeAsync()
    {
        Directory.CreateDirectory(temporaryDirectory);
        return ValueTask.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
        return ValueTask.CompletedTask;
    }

    [Fact]
    public async Task TextPdf_IsStoredAndConceptPagesArePreserved()
    {
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            2,
            [
                new ExtractedDocumentPage(1, "가우스 법칙은 폐곡면의 전기선속을 설명한다."),
                new ExtractedDocumentPage(2, "내부 전하와 전기선속은 서로 비례한다.")
            ]));
        var provider = new FakeConceptProvider(
        [
            new GeneratedConceptDraft(
                "가우스 법칙",
                "전기선속과 전하의 관계를 폐곡면을 기준으로 설명한다.",
                [2, 1])
        ]);
        var service = CreateService(extractor, provider);
        await using var content = PdfLikeStream();

        var response = await service.ImportPdfAsync(
            content,
            "전자기학.pdf",
            content.Length,
            TestContext.Current.CancellationToken);

        Assert.Equal(2, response.Source.PageCount);
        Assert.Equal("textLayer", response.Source.ExtractionMethod);
        Assert.All(response.Pages, page =>
            Assert.Equal("textLayer", page.ExtractionMethod));
        Assert.Equal(64, response.Source.ContentHash.Length);
        var concept = Assert.Single(response.Concepts);
        Assert.Equal([1, 2], concept.PageNumbers);
        Assert.Equal("held", concept.Status);
        Assert.True(File.Exists(Path.Combine(
            temporaryDirectory,
            "sources",
            $"{response.Source.Id}.pdf")));
    }

    [Fact]
    public async Task DeletePdf_RemovesStoredSourceFile()
    {
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            1,
            [new ExtractedDocumentPage(
                1,
                "삭제할 수 있는 충분한 길이의 학습 자료 내용을 포함하고 있습니다.")]));
        var provider = new FakeConceptProvider(
        [
            new GeneratedConceptDraft(
                "삭제 테스트",
                "저장된 PDF 원본 파일을 삭제한다.",
                [1])
        ]);
        var service = CreateService(extractor, provider);
        await using var content = PdfLikeStream();
        var response = await service.ImportPdfAsync(
            content,
            "삭제.pdf",
            content.Length,
            TestContext.Current.CancellationToken);
        var path = Path.Combine(
            temporaryDirectory,
            "sources",
            $"{response.Source.Id}.pdf");
        Assert.True(File.Exists(path));

        service.DeletePdf(response.Source.Id);

        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task PdfWithoutTextLayer_UsesVisionOcrAndStoresResult()
    {
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            1,
            [new ExtractedDocumentPage(1, "  ")]));
        var provider = new FakeConceptProvider(
            [
                new GeneratedConceptDraft(
                    "사칙연산",
                    "이미지에서 추출한 사칙연산 설명",
                    [1])
            ],
            new DocumentVisionResult(
                "사칙연산은 덧셈, 뺄셈, 곱셈, 나눗셈으로 구성된다."));
        var renderer = new FakePdfPageRenderer();
        var service = CreateService(extractor, provider, renderer);
        await using var content = PdfLikeStream();

        var response = await service.ImportPdfAsync(
            content,
            "스캔.pdf",
            content.Length,
            TestContext.Current.CancellationToken);

        Assert.Equal("visionOcr", response.Source.ExtractionMethod);
        Assert.Equal("visionOcr", Assert.Single(response.Pages).ExtractionMethod);
        Assert.Equal(1, provider.VisionCallCount);
        Assert.Equal(1, provider.ConceptCallCount);
        Assert.Equal(1, renderer.CallCount);
    }

    [Fact]
    public async Task MixedPdf_ReportsHybridExtraction()
    {
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            2,
            [
                new ExtractedDocumentPage(
                    1,
                    "텍스트 레이어에서 읽은 충분한 길이의 학습 내용입니다."),
                new ExtractedDocumentPage(2, string.Empty)
            ]));
        var provider = new FakeConceptProvider(
            [
                new GeneratedConceptDraft(
                    "혼합 문서",
                    "텍스트와 이미지 페이지를 모두 근거로 삼는다.",
                    [1, 2])
            ],
            new DocumentVisionResult(
                "이미지 페이지에서 추출한 충분한 길이의 학습 내용입니다."));
        var service = CreateService(extractor, provider);
        await using var content = PdfLikeStream();

        var response = await service.ImportPdfAsync(
            content,
            "혼합.pdf",
            content.Length,
            TestContext.Current.CancellationToken);

        Assert.Equal("hybrid", response.Source.ExtractionMethod);
        Assert.Equal(
            ["textLayer", "visionOcr"],
            response.Pages.Select(page => page.ExtractionMethod));
    }

    [Fact]
    public async Task LargePdf_ExtractsConceptsInPageBoundedChunks()
    {
        var pages = Enumerable.Range(1, 18)
            .Select(page => new ExtractedDocumentPage(
                page,
                $"{page}페이지의 충분한 학습 개념 설명 내용입니다."))
            .ToList();
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            pages.Count,
            pages));
        var provider = new ChunkRecordingProvider();
        var service = CreateService(extractor, provider);
        await using var content = PdfLikeStream();

        var response = await service.ImportPdfAsync(
            content,
            "긴 자료.pdf",
            content.Length,
            TestContext.Current.CancellationToken);

        Assert.Equal(3, provider.Inputs.Count);
        Assert.All(provider.Inputs, input =>
            Assert.InRange(input.Pages.Count, 1, 8));
        Assert.Equal(18, provider.Inputs.Sum(input => input.Pages.Count));
        Assert.Equal(3, response.Concepts.Count);
    }

    [Fact]
    public async Task RepeatedVisionPage_ReusesCachedOcrText()
    {
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            1,
            [new ExtractedDocumentPage(1, string.Empty)]));
        var provider = new FakeConceptProvider(
            [
                new GeneratedConceptDraft(
                    "캐시",
                    "같은 이미지의 OCR 결과를 재사용한다.",
                    [1])
            ],
            new DocumentVisionResult(
                "캐시에 저장할 충분한 길이의 OCR 학습 내용입니다."));
        var cache = new MemoryPageTextCache();
        var service = CreateService(
            extractor,
            provider,
            cache: cache);

        await using (var first = PdfLikeStream())
        {
            await service.ImportPdfAsync(
                first,
                "첫번째.pdf",
                first.Length,
                TestContext.Current.CancellationToken);
        }
        await using (var second = PdfLikeStream())
        {
            await service.ImportPdfAsync(
                second,
                "두번째.pdf",
                second.Length,
                TestContext.Current.CancellationToken);
        }

        Assert.Equal(1, provider.VisionCallCount);
        Assert.Equal(2, provider.ConceptCallCount);
    }

    [Fact]
    public async Task VisualPageWithTextLayer_CombinesTextAndVisionContent()
    {
        var extractor = new FakePdfTextExtractor(new PdfTextExtractionResult(
            1,
            [
                new ExtractedDocumentPage(
                    1,
                    "텍스트 레이어에 포함된 충분한 길이의 설명입니다.",
                    RequiresVision: true)
            ]));
        var provider = new FakeConceptProvider(
            [
                new GeneratedConceptDraft(
                    "도표",
                    "두 추출 결과를 함께 사용한다.",
                    [1])
            ],
            new DocumentVisionResult("도표의 화살표는 증가 관계를 나타낸다."));
        var service = CreateService(extractor, provider);
        await using var content = PdfLikeStream();

        var response = await service.ImportPdfAsync(
            content,
            "도표.pdf",
            content.Length,
            TestContext.Current.CancellationToken);

        Assert.Equal("hybrid", response.Source.ExtractionMethod);
        Assert.Equal("hybrid", Assert.Single(response.Pages).ExtractionMethod);
        Assert.Equal(1, provider.VisionCallCount);
    }

    private DocumentProcessingService CreateService(
        IPdfTextExtractor extractor,
        ILLMProvider provider,
        IPdfPageRenderer? renderer = null,
        IDocumentPageTextCache? cache = null)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Documents:StoragePath"] = "sources"
            })
            .Build();
        return new DocumentProcessingService(
            extractor,
            renderer ?? new FakePdfPageRenderer(),
            cache ?? new NullDocumentPageTextCache(),
            provider,
            new FakeEnvironment(temporaryDirectory),
            configuration,
            NullLogger<DocumentProcessingService>.Instance);
    }

    private static MemoryStream PdfLikeStream() =>
        new(Encoding.ASCII.GetBytes("%PDF-1.7 test content"));

    private sealed class FakePdfTextExtractor(PdfTextExtractionResult result)
        : IPdfTextExtractor
    {
        public PdfTextExtractionResult Extract(string path) => result;
    }

    private sealed class FakeConceptProvider(
        IReadOnlyList<GeneratedConceptDraft> concepts,
        DocumentVisionResult? visionResult = null) : ILLMProvider
    {
        public string ProviderName => "fake";

        public string ModelName => "fake-model";

        public int ConceptCallCount { get; private set; }

        public int VisionCallCount { get; private set; }

        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<GeneratedQuestionDraft>>([]);

        public Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(
            ConceptExtractionInput input,
            CancellationToken cancellationToken = default)
        {
            ConceptCallCount++;
            return Task.FromResult(concepts);
        }

        public Task<DocumentVisionResult> ExtractPageContentAsync(
            DocumentVisionInput input,
            CancellationToken cancellationToken = default)
        {
            VisionCallCount++;
            return Task.FromResult(visionResult ??
                throw new InvalidOperationException("Vision was not expected."));
        }
    }

    private sealed class ChunkRecordingProvider : ILLMProvider
    {
        public string ProviderName => "fake";

        public string ModelName => "fake-model";

        public List<ConceptExtractionInput> Inputs { get; } = [];

        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<GeneratedQuestionDraft>>([]);

        public Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(
            ConceptExtractionInput input,
            CancellationToken cancellationToken = default)
        {
            Inputs.Add(input);
            var page = input.Pages[0].PageNumber;
            return Task.FromResult<IReadOnlyList<GeneratedConceptDraft>>(
            [
                new GeneratedConceptDraft(
                    $"개념 {page}",
                    "청크별 개념 추출을 검증하는 세부 설명",
                    [page])
            ]);
        }

        public Task<DocumentVisionResult> ExtractPageContentAsync(
            DocumentVisionInput input,
            CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Vision was not expected.");
    }

    private sealed class FakePdfPageRenderer : IPdfPageRenderer
    {
        public int CallCount { get; private set; }

        public Task<RenderedDocumentPage> RenderAsync(
            string path,
            int pageNumber,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return Task.FromResult(new RenderedDocumentPage(
                pageNumber,
                "image/jpeg",
                [1, 2, 3],
                new string('a', 64)));
        }
    }

    private sealed class MemoryPageTextCache : IDocumentPageTextCache
    {
        private readonly Dictionary<string, string> entries = [];

        public Task<string?> GetAsync(
            string imageHash,
            string provider,
            string model,
            string promptVersion,
            CancellationToken cancellationToken = default)
        {
            entries.TryGetValue(Key(imageHash, provider, model, promptVersion),
                out var text);
            return Task.FromResult(text);
        }

        public Task SetAsync(
            string imageHash,
            string provider,
            string model,
            string promptVersion,
            string text,
            CancellationToken cancellationToken = default)
        {
            entries[Key(imageHash, provider, model, promptVersion)] = text;
            return Task.CompletedTask;
        }

        private static string Key(
            string imageHash,
            string provider,
            string model,
            string promptVersion) =>
            $"{imageHash}|{provider}|{model}|{promptVersion}";
    }

    private sealed class FakeEnvironment(string contentRootPath)
        : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "ReviewPlatform.Server.Tests";
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
        public string WebRootPath { get; set; } = contentRootPath;
        public string EnvironmentName { get; set; } = "Testing";
        public string ContentRootPath { get; set; } = contentRootPath;
        public IFileProvider ContentRootFileProvider { get; set; } =
            new NullFileProvider();
    }
}
