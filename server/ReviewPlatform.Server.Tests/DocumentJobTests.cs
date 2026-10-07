using System.Text;
using System.Text.Json;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DocumentJobTests : IAsyncLifetime
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"review-pdf-jobs-{Guid.NewGuid()}");
    private readonly List<ServiceProvider> providers = [];
    public ValueTask InitializeAsync() { Directory.CreateDirectory(root); return ValueTask.CompletedTask; }
    public async ValueTask DisposeAsync()
    {
        foreach (var provider in providers) await provider.DisposeAsync();
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }

    private async Task<ServiceProvider> CreateAsync(ILLMProvider fake, int pages = 3)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton<IConfiguration>(new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?>
            {
                ["Documents:StoragePath"] = "sources",
                ["Documents:MinimumFreeDiskSpaceMb"] = "0"
            }).Build());
        services.AddSingleton<IWebHostEnvironment>(new Environment(root));
        services.AddDbContext<SyncDbContext>(options => options.UseSqlite($"Data Source={Path.Combine(root, "jobs.db")};Pooling=False"));
        services.AddSingleton<ILLMProvider>(fake);
        services.AddSingleton<ILlmProviderResolver>(new FixedLlmProviderResolver(fake));
        services.AddSingleton<IPdfPageRenderer, Renderer>();
        services.AddSingleton<DocumentJobSignals>();
        services.AddScoped<DocumentProcessingService>(provider => new DocumentProcessingService(
            provider.GetRequiredService<IPdfPageRenderer>(),
            provider.GetRequiredService<IWebHostEnvironment>(), provider.GetRequiredService<IConfiguration>(),
            NullLogger<DocumentProcessingService>.Instance));
        services.AddScoped<DocumentJobService>();
        var result = services.BuildServiceProvider();
        providers.Add(result);
        using var scope = result.CreateScope();
        await ServerDatabaseInitializer.InitializeAsync(scope.ServiceProvider.GetRequiredService<SyncDbContext>());
        return result;
    }

    private static DocumentJobWorker Worker(ServiceProvider provider) => new(
        provider.GetRequiredService<IServiceScopeFactory>(), provider.GetRequiredService<DocumentJobSignals>(),
        NullLogger<DocumentJobWorker>.Instance);
    private static MemoryStream Pdf() => new(Encoding.ASCII.GetBytes("%PDF-1.7 test content"));
    private static MemoryStream RealPdf(int pages)
    {
        var builder = new PdfDocumentBuilder();
        for (var i = 0; i < pages; i++) builder.AddPage(600 + i, 400);
        return new(builder.Build());
    }


    [Fact]
    public async Task Upload_IsIdleAndPreservesOriginal_RejectsRemovedRoute()
    {
        var fake = new DirectProvider();
        var provider = await CreateAsync(fake);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var id = Guid.NewGuid().ToString();
        await using var pdf = RealPdf(3);
        var bytes = pdf.ToArray();
        var uploaded = await service.UploadAsync(id, "강의.pdf", pdf, pdf.Length, TestContext.Current.CancellationToken);
        Assert.Equal("awaiting_selection", uploaded.Status);
        Assert.Equal(3, uploaded.TotalPages);
        Assert.False(await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken));
        Assert.Empty(fake.PdfCalls);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(Path.Combine(root, "sources", $"{id}.pdf"), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.PreflightAsync(id, new("ocr"), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("queued")]
    [InlineData("awaiting_review")]
    [InlineData("failed")]
    [InlineData("cancelled")]
    public async Task LegacyJob_ReturnsSetup_AndNeverAutomaticallyCallsProvider(string status)
    {
        var fake = new DirectProvider();
        var provider = await CreateAsync(fake);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var db = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
        var id = Guid.NewGuid().ToString();
        await using var pdf = RealPdf(3);
        await service.UploadAsync(id, "강의.pdf", pdf, pdf.Length, TestContext.Current.CancellationToken);
        await db.DocumentJobs.Where(job => job.Id == id).ExecuteUpdateAsync(setters => setters
            .SetProperty(job => job.Status, status)
            .SetProperty(job => job.CheckpointJson, "{\"extractionMode\":\"ocr\",\"totalPages\":3}")
            .SetProperty(job => job.ConceptProfileJson, "obsolete profile"), TestContext.Current.CancellationToken);
        Assert.Equal("awaiting_selection", (await Get(provider, id)).Status);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Empty(fake.PdfCalls);
        Assert.True(File.Exists(Path.Combine(root, "sources", $"{id}.pdf")));
        await service.DeleteAsync(id, TestContext.Current.CancellationToken);
        await service.DeleteAsync(id, TestContext.Current.CancellationToken);
        Assert.Null(await service.GetAsync(id, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task DirectRoute_UsesRealSubsets_RestoresGlobalPages_AndNeverCallsOcr()
    {
        var fake = new DirectProvider();
        var provider = await CreateAsync(fake, 3);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var id = Guid.NewGuid().ToString();
        await using var pdf = RealPdf(3);
        await service.UploadAsync(id, "강의.pdf", pdf, pdf.Length, TestContext.Current.CancellationToken);
        var selection = new PdfExtractionSelection("direct", [2]);
        var check = await service.PreflightAsync(id, selection, TestContext.Current.CancellationToken);
        Assert.Equal("warning", check.Status); // Account TPM is explicitly an assumption.
        await Assert.ThrowsAsync<DocumentImportException>(() => service.StartExtractionAsync(id,
            selection with { Revision = check.Revision }, TestContext.Current.CancellationToken));
        var start = selection with { Revision = check.Revision, AcknowledgeWarnings = true };
        await service.StartExtractionAsync(id, start, TestContext.Current.CancellationToken);
        await service.StartExtractionAsync(id, start, TestContext.Current.CancellationToken); // Lost receipt is idempotent.
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(provider, id)).Status);
        Assert.Equal(new[] { 2, 1 }, fake.PdfCalls);
        Assert.Equal(new[] { 600d, 602d }, fake.FirstPageWidths);
        var result = JsonSerializer.Deserialize<ImportDocumentResponse>((await Result(provider, id))!, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        Assert.Equal("directPdf", result.Source.ExtractionMethod);
        Assert.Equal(new[] { 1, 2 }, result.Concepts[0].PageNumbers);
        Assert.Equal(new[] { 3 }, result.Concepts[1].PageNumbers);
    }

    [Fact]
    public async Task DirectPreflight_BlocksOversizedInput_UntilUserSplits_RejectsStaleRevision()
    {
        var fake = new DirectProvider { InputTokens = 600_000 };
        var provider = await CreateAsync(fake, 3);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var id = Guid.NewGuid().ToString();
        await using var pdf = RealPdf(3);
        await service.UploadAsync(id, "강의.pdf", pdf, pdf.Length, TestContext.Current.CancellationToken);
        var check = await service.PreflightAsync(id, new("direct"), TestContext.Current.CancellationToken);
        Assert.Equal("blocked", check.Status);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.StartExtractionAsync(id,
            new("direct", AcknowledgeWarnings: true, Revision: check.Revision), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.PreflightAsync(id,
            new("direct", [1]), TestContext.Current.CancellationToken));
        Assert.Equal("awaiting_selection", (await Get(provider, id)).Status);
        Assert.Empty(fake.PdfCalls);
    }

    [Theory]
    [InlineData(new[] { 2, 1 })]
    [InlineData(new[] { 1, 1 })]
    [InlineData(new[] { 3 })]
    [InlineData(new[] { 0 })]
    public void DirectSplit_RejectsInvalidBoundaries(int[] boundaries) =>
        Assert.Throws<DocumentImportException>(() => DocumentProcessingService.SelectedRanges(3, boundaries));

    [Fact]
    public async Task DirectFailure_PreservesCompletedChunk_AndOnlyResumesIncompletePart()
    {
        var fake = new DirectProvider { FailPdfCall = 2 };
        var provider = await CreateAsync(fake, 3);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var id = Guid.NewGuid().ToString();
        await using var pdf = RealPdf(3);
        await service.UploadAsync(id, "강의.pdf", pdf, pdf.Length, TestContext.Current.CancellationToken);
        var selection = new PdfExtractionSelection("direct", [2], AcknowledgeWarnings: true);
        var check = await service.PreflightAsync(id, selection, TestContext.Current.CancellationToken);
        await service.StartExtractionAsync(id, selection with { Revision = check.Revision }, TestContext.Current.CancellationToken);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var failed = await Get(provider, id);
        Assert.Equal("failed", failed.Status);
        Assert.Equal(1, failed.CompletedChunks);
        var overview = await service.ExtractionOverviewAsync(id, TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.PreflightAsync(id,
            selection with { SplitAfterPages = [1], Revision = overview.Revision }, TestContext.Current.CancellationToken));
        check = await service.PreflightAsync(id, selection with { Revision = overview.Revision }, TestContext.Current.CancellationToken);
        await service.StartExtractionAsync(id, selection with { Revision = check.Revision }, TestContext.Current.CancellationToken);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(provider, id)).Status);
        Assert.Equal(new[] { 2, 1, 1 }, fake.PdfCalls);
    }


    [Fact]
    public async Task LegacyPartialJob_DirectRestartDoesNotMergeOldDrafts_AndRetainsPdf()
    {
        var fake = new DirectProvider();
        var provider = await CreateAsync(fake);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var db = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
        var id = Guid.NewGuid().ToString();
        await using var pdf = RealPdf(3);
        var original = pdf.ToArray();
        await service.UploadAsync(id, "강의.pdf", pdf, pdf.Length, TestContext.Current.CancellationToken);
        var record = await db.DocumentJobs.SingleAsync(job => job.Id == id, TestContext.Current.CancellationToken);
        record.Status = "awaiting_review";
        record.CheckpointJson = """{"extractionMode":"ocr","totalPages":0,"chunks":[[{"title":"옛 미완료 초안","content":"이 내용은 섞이지 않는다.","pageNumbers":[1],"importance":"medium"}]]}""";
        await db.SaveChangesAsync(TestContext.Current.CancellationToken);
        var check = await service.PreflightAsync(id, new("direct"), TestContext.Current.CancellationToken);
        await service.StartExtractionAsync(id, new("direct", AcknowledgeWarnings: true, Revision: check.Revision), TestContext.Current.CancellationToken);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var result = JsonSerializer.Deserialize<ImportDocumentResponse>((await Result(provider, id))!, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        Assert.Single(result.Concepts);
        Assert.DoesNotContain(result.Concepts, concept => concept.Title == "옛 미완료 초안");
        Assert.Equal(original, await File.ReadAllBytesAsync(Path.Combine(root, "sources", $"{id}.pdf"), TestContext.Current.CancellationToken));
    }

    private sealed class DirectProvider : ILLMProvider, IDirectPdfConceptProvider
    {
        public string ProviderName => "openai";
        public string ModelName => "test-pdf";
        public int MaximumPdfOutputTokens => 64_000;
        public int? PdfContextTokens => 1_050_000;
        public string RateLimitKey { get; } = Guid.NewGuid().ToString();
        public long InputTokens { get; set; } = 100;
        public int FailPdfCall { get; set; }
        public List<int> PdfCalls { get; } = [];
        public List<double> FirstPageWidths { get; } = [];
        public Task<PdfTokenCount> CountPdfTokensAsync(DirectPdfInput input, CancellationToken cancellationToken)
        {
            using var pdf = PdfDocument.Open(input.PdfBytes);
            Assert.Equal(input.PageCount, pdf.NumberOfPages);
            return Task.FromResult(new PdfTokenCount(InputTokens));
        }
        public Task<IReadOnlyList<GeneratedConceptDraft>> ExtractPdfConceptsAsync(DirectPdfInput input, CancellationToken cancellationToken)
        {
            using var pdf = PdfDocument.Open(input.PdfBytes);
            PdfCalls.Add(pdf.NumberOfPages);
            if (PdfCalls.Count == FailPdfCall) throw new LlmProviderRequestException("테스트 일시 실패");
            FirstPageWidths.Add(pdf.GetPage(1).Width);
            return Task.FromResult<IReadOnlyList<GeneratedConceptDraft>>([
                new($"개념 {PdfCalls.Count}", "원본에 근거한 내용", Enumerable.Range(1, input.PageCount).ToList())]);
        }
        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(QuestionGenerationInput input, CancellationToken cancellationToken = default) => throw new InvalidOperationException("Must not generate questions");
    }

    private static async Task<DocumentJobResponse> Get(ServiceProvider provider, string id)
    {
        using var scope = provider.CreateScope();
        return (await scope.ServiceProvider.GetRequiredService<DocumentJobService>().GetAsync(id, TestContext.Current.CancellationToken))!;
    }
    private static async Task<string?> Result(ServiceProvider provider, string id)
    {
        using var scope = provider.CreateScope();
        return await scope.ServiceProvider.GetRequiredService<DocumentJobService>().GetResultAsync(id, TestContext.Current.CancellationToken);
    }

    private sealed class Renderer : IPdfPageRenderer
    {
        public Task<RenderedDocumentPage> RenderAsync(string path, int pageNumber, CancellationToken cancellationToken = default) =>
            Task.FromResult(new RenderedDocumentPage(pageNumber, "image/jpeg", [1, 2, 3], pageNumber.ToString()));
    }
    private sealed class Environment(string path) : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "Tests";
        public string EnvironmentName { get; set; } = "Testing";
        public string ContentRootPath { get; set; } = path;
        public string WebRootPath { get; set; } = path;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
    }
}
