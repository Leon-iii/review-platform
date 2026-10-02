using System.Text;
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

    private async Task<ServiceProvider> CreateAsync(FakeProvider fake, int pages = 61,
        int maximumCharacters = 3_000_000, bool vision = true)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton<IConfiguration>(new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?>
            {
                ["Documents:StoragePath"] = "sources",
                ["Documents:MinimumFreeDiskSpaceMb"] = "0",
                ["Documents:MaximumExtractedCharacters"] = maximumCharacters.ToString()
            }).Build());
        services.AddSingleton<IWebHostEnvironment>(new Environment(root));
        services.AddDbContext<SyncDbContext>(options => options.UseSqlite($"Data Source={Path.Combine(root, "jobs.db")};Pooling=False"));
        services.AddSingleton<ILLMProvider>(fake);
        services.AddSingleton<ILlmProviderResolver>(new FixedLlmProviderResolver(fake));
        services.AddSingleton<IPdfTextExtractor>(new Extractor(pages, vision));
        services.AddSingleton<IPdfPageRenderer, Renderer>();
        services.AddSingleton<IDocumentPageTextCache, NullDocumentPageTextCache>();
        services.AddSingleton<DocumentJobSignals>();
        services.AddScoped<DocumentProcessingService>(provider => new DocumentProcessingService(
            provider.GetRequiredService<IPdfTextExtractor>(), provider.GetRequiredService<IPdfPageRenderer>(),
            provider.GetRequiredService<IDocumentPageTextCache>(), provider.GetRequiredService<ILlmProviderResolver>(),
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
    private static async Task<string> Upload(ServiceProvider provider)
    {
        using var scope = provider.CreateScope();
        var id = Guid.NewGuid().ToString();
        await using var content = Pdf();
        var response = await scope.ServiceProvider.GetRequiredService<DocumentJobService>()
            .UploadAsync(id, "강의.pdf", content, content.Length, TestContext.Current.CancellationToken);
        Assert.Equal("queued", response.Status);
        return id;
    }
    private static async Task<DocumentJobResponse> Get(ServiceProvider provider, string id)
    {
        using var scope = provider.CreateScope();
        return (await scope.ServiceProvider.GetRequiredService<DocumentJobService>()
            .GetAsync(id, TestContext.Current.CancellationToken))!;
    }
    private static async Task Retry(ServiceProvider provider, string id)
    {
        using var scope = provider.CreateScope();
        await scope.ServiceProvider.GetRequiredService<DocumentJobService>().RetryAsync(id, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task MoreThan50VisionPages_CompletesAsOneSource_WithIdempotentReceipt()
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake);
        var id = await Upload(provider);
        using (var scope = provider.CreateScope())
        {
            await using var content = Pdf();
            var repeated = await scope.ServiceProvider.GetRequiredService<DocumentJobService>()
                .UploadAsync(id, "강의.pdf", content, content.Length, TestContext.Current.CancellationToken);
            Assert.Equal(id, repeated.Id);
            Assert.Equal(1, await scope.ServiceProvider.GetRequiredService<SyncDbContext>().DocumentJobs.CountAsync(TestContext.Current.CancellationToken));
        }
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var job = await Get(provider, id);
        Assert.Equal("completed", job.Status);
        Assert.Equal(61, job.CompletedPages);
        Assert.Equal(61, fake.VisionCalls.Count);
        using var results = provider.CreateScope();
        var json = await results.ServiceProvider.GetRequiredService<DocumentJobService>()
            .GetResultAsync(id, TestContext.Current.CancellationToken);
        var result = System.Text.Json.JsonSerializer.Deserialize<ImportDocumentResponse>(json!, DocumentJobServiceJson());
        Assert.Equal(id, result!.Source.Id);
        Assert.Equal(61, result.Source.PageCount);
        Assert.All(result.Concepts, concept => Assert.Equal("held", concept.Status));
        Assert.False(await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken));
    }
    private static System.Text.Json.JsonSerializerOptions DocumentJobServiceJson() => new(System.Text.Json.JsonSerializerDefaults.Web);

    [Fact]
    public async Task FailedPage_RestartAndRetry_OnlyProcessesRemainingPages()
    {
        var first = new FakeProvider { FailVisionPage = 3 };
        var provider = await CreateAsync(first, 6);
        var id = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var failed = await Get(provider, id);
        Assert.Equal("failed", failed.Status);
        Assert.Equal(2, failed.CompletedPages);
        Assert.Null(await Result(provider, id));
        var resumed = new FakeProvider();
        var restarted = await CreateAsync(resumed, 6);
        await Retry(restarted, id);
        await Worker(restarted).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(restarted, id)).Status);
        Assert.Equal([3, 4, 5, 6], resumed.VisionCalls);
    }

    [Fact]
    public async Task FailedConceptChunk_Retry_DoesNotRepeatOcrOrCompletedChunk()
    {
        var fake = new FakeProvider { FailConceptCall = 2 };
        var provider = await CreateAsync(fake, 18);
        var id = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, (await Get(provider, id)).CompletedChunks);
        Assert.Equal("failed", (await Get(provider, id)).Status);
        fake.FailConceptCall = 0;
        await Retry(provider, id);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(provider, id)).Status);
        Assert.Equal(18, fake.VisionCalls.Count);
        Assert.Equal(4, fake.ConceptCalls); // success, failure, remaining two
    }

    [Fact]
    public async Task Cancel_InterruptsProvider_AndCanResumeWithoutRepeatingCompletedPages()
    {
        var fake = new FakeProvider { BlockPage = 2 };
        var provider = await CreateAsync(fake, 3);
        var id = await Upload(provider);
        var running = Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        await fake.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        using (var scope = provider.CreateScope())
            await scope.ServiceProvider.GetRequiredService<DocumentJobService>().CancelAsync(id, TestContext.Current.CancellationToken);
        await running;
        Assert.Equal("cancelled", (await Get(provider, id)).Status);
        Assert.Equal(1, (await Get(provider, id)).CompletedPages);
        fake.BlockPage = 0;
        await Retry(provider, id);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal([1, 2, 2, 3], fake.VisionCalls);
        Assert.Equal("completed", (await Get(provider, id)).Status);
    }

    [Fact]
    public async Task Shutdown_QueuesUnfinishedJob_AndRetainsCheckpoint()
    {
        var fake = new FakeProvider { BlockPage = 2 };
        var provider = await CreateAsync(fake, 3);
        var id = await Upload(provider);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var running = Worker(provider).RunNextAsync(stop.Token);
        await fake.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        stop.Cancel();
        await running;
        Assert.Equal("queued", (await Get(provider, id)).Status);
        Assert.Equal(1, (await Get(provider, id)).CompletedPages);
        fake.BlockPage = 0;
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(provider, id)).Status);
    }

    [Fact]
    public async Task CharacterSafetyLimit_FailsExplicitly_InsteadOfSilentlyDroppingPages()
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 3, 100, false);
        var id = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var job = await Get(provider, id);
        Assert.Equal("failed", job.Status);
        Assert.Contains("안전 제한", job.Error);
        Assert.Equal(0, fake.ConceptCalls);
    }

    [Fact]
    public async Task Upload_RejectsChangedLengthAndInvalidSignature_WithoutQueuing()
    {
        var provider = await CreateAsync(new FakeProvider());
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        await using var content = Pdf();
        await Assert.ThrowsAsync<DocumentImportException>(() => service.UploadAsync(Guid.NewGuid().ToString(),
            "강의.pdf", content, 1, TestContext.Current.CancellationToken));
        await using var notPdf = new MemoryStream([1, 2, 3]);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.UploadAsync(Guid.NewGuid().ToString(),
            "강의.pdf", notPdf, 3, TestContext.Current.CancellationToken));
        Assert.Empty(await scope.ServiceProvider.GetRequiredService<SyncDbContext>().DocumentJobs.ToListAsync(TestContext.Current.CancellationToken));
        Assert.Empty(Directory.GetFiles(Path.Combine(root, "sources")));
    }

    [Fact]
    public async Task PendingLimit_AppliesToNewUploadsAndRetries()
    {
        var provider = await CreateAsync(new FakeProvider(), 1);
        provider.GetRequiredService<IConfiguration>()["Documents:MaximumPendingJobs"] = "1";
        var first = await Upload(provider);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        await using var content = Pdf();
        await Assert.ThrowsAsync<DocumentImportException>(() => service.UploadAsync(Guid.NewGuid().ToString(),
            "자료.pdf", content, content.Length, TestContext.Current.CancellationToken));
        await service.CancelAsync(first, TestContext.Current.CancellationToken);
        var second = await Upload(provider);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.RetryAsync(first, TestContext.Current.CancellationToken));
        Assert.Equal("cancelled", (await Get(provider, first)).Status);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(provider, second)).Status);
        await Retry(provider, first);
        Assert.Equal("queued", (await Get(provider, first)).Status);
    }

    [Fact]
    public async Task ChangedPromptVersion_DoesNotMixOldAndNewAnalysisResults()
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 1);
        var id = await Upload(provider);
        using (var scope = provider.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
            var job = await database.DocumentJobs.SingleAsync(row => row.Id == id, TestContext.Current.CancellationToken);
            var checkpoint = System.Text.Json.JsonSerializer.Deserialize<DocumentCheckpoint>(job.CheckpointJson, DocumentJobServiceJson())!;
            checkpoint.ConceptPromptVersion = "older-version";
            job.CheckpointJson = System.Text.Json.JsonSerializer.Serialize(checkpoint, DocumentJobServiceJson());
            await database.SaveChangesAsync(TestContext.Current.CancellationToken);
        }
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("failed", (await Get(provider, id)).Status);
        Assert.Contains("지침 버전", (await Get(provider, id)).Error);
        Assert.Empty(fake.VisionCalls);
        Assert.Equal(0, fake.ConceptCalls);
    }

    private static async Task<string?> Result(ServiceProvider provider, string id)
    {
        using var scope = provider.CreateScope();
        return await scope.ServiceProvider.GetRequiredService<DocumentJobService>().GetResultAsync(id, TestContext.Current.CancellationToken);
    }

    private sealed class Extractor(int pages, bool vision) : IPdfTextExtractor
    {
        public PdfTextExtractionResult Extract(string path) => new(pages,
            Enumerable.Range(1, pages).Select(page => new ExtractedDocumentPage(page,
                vision ? "" : new string('가', 100))).ToList());
    }
    private sealed class Renderer : IPdfPageRenderer
    {
        public Task<RenderedDocumentPage> RenderAsync(string path, int pageNumber, CancellationToken cancellationToken = default) =>
            Task.FromResult(new RenderedDocumentPage(pageNumber, "image/jpeg", [1, 2, 3], pageNumber.ToString()));
    }
    private sealed class FakeProvider : ILLMProvider
    {
        public string ProviderName => "ollama";
        public string ModelName => "test-pinned-model";
        public int FailVisionPage { get; set; }
        public int FailConceptCall { get; set; }
        public int BlockPage { get; set; }
        public TaskCompletionSource Blocked { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<int> VisionCalls { get; } = [];
        public int ConceptCalls { get; private set; }
        public async Task<DocumentVisionResult> ExtractPageContentAsync(DocumentVisionInput input, CancellationToken cancellationToken = default)
        {
            VisionCalls.Add(input.PageNumber);
            if (input.PageNumber == FailVisionPage) throw new LlmProviderRequestException("테스트 페이지 오류");
            if (input.PageNumber == BlockPage) { Blocked.TrySetResult(); await Task.Delay(Timeout.Infinite, cancellationToken); }
            return new DocumentVisionResult(new string('가', 1000));
        }
        public Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(ConceptExtractionInput input, CancellationToken cancellationToken = default)
        {
            ConceptCalls++;
            if (ConceptCalls == FailConceptCall) throw new LlmProviderRequestException("테스트 개념 오류");
            return Task.FromResult<IReadOnlyList<GeneratedConceptDraft>>([
                new GeneratedConceptDraft($"개념 {input.Pages[0].PageNumber}", "학습 내용", input.Pages.Select(page => page.PageNumber).ToList())]);
        }
        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(QuestionGenerationInput input, CancellationToken cancellationToken = default) => throw new NotSupportedException();
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
