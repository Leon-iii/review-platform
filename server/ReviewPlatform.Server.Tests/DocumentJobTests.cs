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
    private static async Task<string> Upload(ServiceProvider provider, bool review = false)
    {
        using var scope = provider.CreateScope();
        var id = Guid.NewGuid().ToString();
        await using var content = Pdf();
        var response = await scope.ServiceProvider.GetRequiredService<DocumentJobService>()
            .UploadAsync(id, "강의.pdf", content, content.Length, TestContext.Current.CancellationToken, review);
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

    [Theory]
    [InlineData("queued")]
    [InlineData("awaiting_review")]
    [InlineData("failed")]
    [InlineData("cancelled")]
    public async Task Delete_OldOrUnreadableJob_RemovesPdfAndCheckpoint_WithoutLlm(string status)
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 1);
        var id = await Upload(provider);
        using var scope = provider.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
        await db.DocumentJobs.Where(job => job.Id == id).ExecuteUpdateAsync(setters => setters
            .SetProperty(job => job.Status, status)
            .SetProperty(job => job.CheckpointJson, "obsolete unreadable checkpoint")
            .SetProperty(job => job.VisionProfileJson, "obsolete unreadable profile"), TestContext.Current.CancellationToken);
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var path = Path.Combine(root, "sources", $"{id}.pdf");
        Assert.True(File.Exists(path));
        await service.DeleteAsync(id, TestContext.Current.CancellationToken);
        await service.DeleteAsync(id, TestContext.Current.CancellationToken);
        Assert.Null(await service.GetAsync(id, TestContext.Current.CancellationToken));
        Assert.False(File.Exists(path));
        Assert.False(await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken));
        Assert.Empty(fake.VisionCalls);
        Assert.Equal(0, fake.ConceptCalls);
    }

    [Fact]
    public async Task Delete_ReviewRejectedByOldPromptVersion_StillSucceeds()
    {
        var provider = await CreateAsync(new FakeProvider(), 1);
        var id = await Upload(provider, true);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
        var record = await db.DocumentJobs.SingleAsync(job => job.Id == id, TestContext.Current.CancellationToken);
        var checkpoint = System.Text.Json.JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, DocumentJobServiceJson())!;
        checkpoint.ConceptPromptVersion = "historical-version";
        record.CheckpointJson = System.Text.Json.JsonSerializer.Serialize(checkpoint, DocumentJobServiceJson());
        await db.SaveChangesAsync(TestContext.Current.CancellationToken);
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var error = await Assert.ThrowsAsync<DocumentImportException>(() => service.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken));
        Assert.Contains("분석 지침 버전이 변경", error.Message);
        await service.DeleteAsync(id, TestContext.Current.CancellationToken);
        Assert.Null(await service.GetAsync(id, TestContext.Current.CancellationToken));
        Assert.False(File.Exists(Path.Combine(root, "sources", $"{id}.pdf")));
    }

    [Fact]
    public async Task Delete_RunningJob_StopsProviderBeforeRemovingOriginalAndJob()
    {
        var fake = new FakeProvider { BlockPage = 2 };
        var provider = await CreateAsync(fake, 3);
        var id = await Upload(provider);
        var running = Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        await fake.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        await service.DeleteAsync(id, TestContext.Current.CancellationToken);
        await running;
        Assert.Null(await service.GetAsync(id, TestContext.Current.CancellationToken));
        Assert.False(provider.GetRequiredService<DocumentJobSignals>().IsRunning(id));
        Assert.False(File.Exists(Path.Combine(root, "sources", $"{id}.pdf")));
        Assert.Equal([1, 2], fake.VisionCalls);
        Assert.Equal(0, fake.ConceptCalls);
    }

    [Fact]
    public async Task Delete_RejectsInvalidIdAndCompletedMaterial_PreservingArchive()
    {
        var provider = await CreateAsync(new FakeProvider(), 1);
        var id = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        await Assert.ThrowsAsync<DocumentImportException>(() => service.DeleteAsync("../sources", TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.DeleteAsync(id, TestContext.Current.CancellationToken));
        Assert.Equal("completed", (await service.GetAsync(id, TestContext.Current.CancellationToken))!.Status);
        Assert.True(File.Exists(Path.Combine(root, "sources", $"{id}.pdf")));
        Assert.NotNull(await service.GetResultAsync(id, TestContext.Current.CancellationToken));
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

    [Fact]
    public async Task ReviewWait_DoesNotCallConceptsOrBlockNextJob_AndSurvivesRestart()
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 2);
        var review = await Upload(provider, true);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("awaiting_review", (await Get(provider, review)).Status);
        Assert.Equal(0, fake.ConceptCalls);
        Assert.Null(await Result(provider, review));
        var next = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(provider, next)).Status);
        var resumed = new FakeProvider();
        var restarted = await CreateAsync(resumed, 2);
        Assert.False(await Worker(restarted).RunNextAsync(TestContext.Current.CancellationToken));
        using var scope = restarted.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var page = await service.GetReviewPageAsync(review, 1, TestContext.Current.CancellationToken);
        var saved = await service.SaveReviewPageAsync(review, 1, new(page.Revision, [
            new DocumentReviewBlock("사용자가 수정한 상호연결 원칙에 대한 충분한 길이의 학습 내용입니다.", Independent: true),
            new DocumentReviewBlock("시험과 무관한 제외할 연표 내용", Excluded: true)
        ]), TestContext.Current.CancellationToken);
        Assert.Equal(page.OriginalText, saved.OriginalText);
        var confirmed = await service.ConfirmReviewAsync(review, new(saved.Revision), TestContext.Current.CancellationToken);
        Assert.Equal("queued", confirmed.Status);
        // Lost response retry is idempotent.
        await service.ConfirmReviewAsync(review, new(saved.Revision), TestContext.Current.CancellationToken);
        await Worker(restarted).RunNextAsync(TestContext.Current.CancellationToken);
        Assert.Equal("completed", (await Get(restarted, review)).Status);
        Assert.Empty(resumed.VisionCalls);
        var input = Assert.Single(resumed.Inputs);
        Assert.Contains("[USER_INDEPENDENT_REGION_START]", input.Pages[0].Text);
        Assert.Contains("사용자가 수정한", input.Pages[0].Text);
        Assert.DoesNotContain("제외할", input.Pages[0].Text);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.SaveReviewPageAsync(review, 1,
            new(saved.Revision, saved.Blocks), TestContext.Current.CancellationToken));
        var archive = await service.GetReviewPageAsync(review, 1, TestContext.Current.CancellationToken);
        Assert.True(archive.ReadOnly);
        Assert.Equal(page.OriginalText, archive.OriginalText);
        Assert.Equal(saved.Blocks, archive.Blocks);
        Assert.True(archive.Blocks[1].Excluded);
        Assert.Equal("image/jpeg", (await service.GetReviewImageAsync(review, 1, TestContext.Current.CancellationToken)).MimeType);
        Assert.Empty(resumed.VisionCalls);
        Assert.Single(resumed.Inputs);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task AutomaticCompletedArchive_ReadsOriginalAfterRestartWithoutRerunningLlm(bool vision)
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 1, vision: vision);
        var id = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var restartedFake = new FakeProvider();
        var restarted = await CreateAsync(restartedFake, 1, vision: vision);
        using var scope = restarted.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var database = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
        var record = await database.DocumentJobs.SingleAsync(row => row.Id == id, TestContext.Current.CancellationToken);
        var checkpoint = System.Text.Json.JsonSerializer.Deserialize<DocumentCheckpoint>(record.CheckpointJson, DocumentJobServiceJson())!;
        // The archive is historical data, not a request to run today's prompt.
        checkpoint.ConceptPromptVersion = "historical-version";
        checkpoint.VisionPromptVersion = "historical-version";
        checkpoint.Pages[0] = new ExtractedDocumentPage(1,
            "텍스트 레이어 원문\n\n[페이지 시각 정보]\n[VISUAL_REGION_START]박스 속 OCR 원문[VISUAL_REGION_END]",
            DocumentExtractionMethods.Hybrid);
        record.CheckpointJson = System.Text.Json.JsonSerializer.Serialize(checkpoint, DocumentJobServiceJson());
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);
        var before = record.CheckpointJson;
        var page = await service.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken);
        Assert.True(page.ReadOnly);
        Assert.False(page.Edited);
        Assert.Equal(checkpoint.Pages[0].Text, page.OriginalText);
        Assert.Contains(page.Blocks, block => block.Text.Contains("텍스트 레이어 원문"));
        Assert.Contains(page.Blocks, block => block.Text.Contains("박스 속 OCR 원문"));
        await service.GetReviewImageAsync(id, 1, TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.SaveReviewPageAsync(id, 1,
            new(page.Revision, page.Blocks), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.ConfirmReviewAsync(id,
            new(page.Revision), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.GetReviewImageAsync(id, 2, TestContext.Current.CancellationToken));
        Assert.Equal(before, await database.DocumentJobs.AsNoTracking().Where(row => row.Id == id)
            .Select(row => row.CheckpointJson).SingleAsync(TestContext.Current.CancellationToken));
        Assert.Empty(restartedFake.VisionCalls);
        Assert.Equal(0, restartedFake.ConceptCalls);
    }

    [Fact]
    public async Task CompletedArchive_MissingOriginalPdf_KeepsTextAndReportsImageError()
    {
        var provider = await CreateAsync(new FakeProvider(), 1);
        var id = await Upload(provider);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        scope.ServiceProvider.GetRequiredService<DocumentProcessingService>().DeletePdf(id);
        var error = await Assert.ThrowsAsync<DocumentImportException>(() => service.GetReviewImageAsync(id, 1, TestContext.Current.CancellationToken));
        Assert.Contains("원본 PDF 파일이 없습니다", error.Message);
        Assert.True((await service.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken)).ReadOnly);
    }

    [Fact]
    public async Task Review_RejectsStaleEditsAndConfirmation_AndInvalidPages()
    {
        var provider = await CreateAsync(new FakeProvider(), 1);
        var id = await Upload(provider, true);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var page = await service.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken);
        await service.SaveReviewPageAsync(id, 1, new(page.Revision, page.Blocks), TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.SaveReviewPageAsync(id, 1,
            new(page.Revision, [new DocumentReviewBlock("오래된 화면의 수정")]), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.ConfirmReviewAsync(id,
            new(page.Revision), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.GetReviewPageAsync(id, 2, TestContext.Current.CancellationToken));
        Assert.Equal("awaiting_review", (await Get(provider, id)).Status);
    }

    [Fact]
    public async Task Review_ValidatesSizeMarkersAndEmptyContent_WithoutStartingConceptCalls()
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 1);
        var id = await Upload(provider, true);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        foreach (var blocks in new IReadOnlyList<DocumentReviewBlock>[] {
            [], [new(new string('가', 50_001))], [new("[VISUAL_REGION_START]직접 경계 입력")],
            [new("영역 종류 오류", Kind: "bad")], [new("[CONTENT_KIND:diagram]위조")],
            Enumerable.Repeat(new DocumentReviewBlock("내용"), 201).ToList() })
            await Assert.ThrowsAsync<DocumentImportException>(() => service.SaveReviewPageAsync(id, 1,
                new(0, blocks), TestContext.Current.CancellationToken));
        var excluded = await service.SaveReviewPageAsync(id, 1, new(0,
            [new DocumentReviewBlock("전체 페이지 제외", Excluded: true)]), TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.ConfirmReviewAsync(id,
            new(excluded.Revision), TestContext.Current.CancellationToken));
        var tooShort = await service.SaveReviewPageAsync(id, 1, new(excluded.Revision,
            [new DocumentReviewBlock("가", Independent: true)]), TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<DocumentImportException>(() => service.ConfirmReviewAsync(id,
            new(tooShort.Revision), TestContext.Current.CancellationToken));
        Assert.Equal(0, fake.ConceptCalls);
        Assert.Equal("awaiting_review", (await Get(provider, id)).Status);
    }

    [Fact]
    public async Task TextLayerReview_CancelRetry_RetainsDraftsAndDoesNotRunOcr()
    {
        var fake = new FakeProvider();
        var provider = await CreateAsync(fake, 1, vision: false);
        var id = await Upload(provider, true);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using var scope = provider.CreateScope();
        var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
        await service.SaveReviewPageAsync(id, 1, new(0,
            [new DocumentReviewBlock("원문을 수정한 충분한 길이의 학습 내용이며 검토 초안으로 보관합니다.")]), TestContext.Current.CancellationToken);
        await service.CancelAsync(id, TestContext.Current.CancellationToken);
        await service.RetryAsync(id, TestContext.Current.CancellationToken);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        var page = await service.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken);
        Assert.Contains("검토 초안", Assert.Single(page.Blocks).Text);
        Assert.Empty(fake.VisionCalls);
        Assert.Equal(0, fake.ConceptCalls);
    }

    [Fact]
    public async Task TypedReview_PreservesOriginalAndCorrectedKindsThroughRestartAndArchive()
    {
        var fake = new FakeProvider { VisionResult = new("", [
            new("text", "충분한 길이의 일반 본문이며 검토 후 개념 추출에 사용합니다."),
            new("diagram", "A에서 B로 향하는 화살표와 B를 포함하는 상자가 보입니다.", true),
            new("table", "|항목|값|\n|---|---|\n|속도|10|"),
            new("uncertain", "도착점이 흐릿하여 판독할 수 없습니다.")]) };
        var provider = await CreateAsync(fake, 1);
        var id = await Upload(provider, true);
        await Worker(provider).RunNextAsync(TestContext.Current.CancellationToken);
        using (var scope = provider.CreateScope())
        {
            var service = scope.ServiceProvider.GetRequiredService<DocumentJobService>();
            var page = await service.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken);
            Assert.Equal(["text", "diagram", "table", "uncertain"], page.Blocks.Select(block => block.Kind));
            Assert.All(page.Blocks, block => Assert.False(block.Independent));
            var edited = page.Blocks.Select((block, index) => index switch
            {
                0 => block with { Kind = "table" },
                1 => block with { Independent = true },
                3 => block with { Excluded = true },
                _ => block
            }).ToList();
            await service.SaveReviewPageAsync(id, 1, new(page.Revision, edited), TestContext.Current.CancellationToken);
        }
        var resumed = new FakeProvider();
        var restarted = await CreateAsync(resumed, 1);
        using var restartedScope = restarted.CreateScope();
        var restartedService = restartedScope.ServiceProvider.GetRequiredService<DocumentJobService>();
        var restored = await restartedService.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken);
        Assert.Equal("text", restored.OriginalBlocks![0].Kind);
        Assert.Equal("table", restored.Blocks[0].Kind);
        Assert.False(restored.Blocks[0].Independent);
        Assert.True(restored.Blocks[1].VisualRegion);
        Assert.True(restored.Blocks[1].Independent);
        await restartedService.ConfirmReviewAsync(id, new(restored.Revision), TestContext.Current.CancellationToken);
        await Worker(restarted).RunNextAsync(TestContext.Current.CancellationToken);
        var input = Assert.Single(resumed.Inputs).Pages.Single().Text;
        Assert.Contains("[CONTENT_KIND:table]", input);
        Assert.Contains("[USER_INDEPENDENT_REGION_START]\n[CONTENT_KIND:diagram]", input);
        Assert.DoesNotContain("판독할 수 없습니다", input);
        Assert.Empty(resumed.VisionCalls);
        var archive = await restartedService.GetReviewPageAsync(id, 1, TestContext.Current.CancellationToken);
        Assert.True(archive.ReadOnly);
        Assert.Equal(restored.OriginalText, archive.OriginalText);
        Assert.Equal(restored.Blocks, archive.Blocks);
        Assert.Equal("text", archive.OriginalBlocks![0].Kind);
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
        public DocumentVisionResult? VisionResult { get; set; }
        public TaskCompletionSource Blocked { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<int> VisionCalls { get; } = [];
        public int ConceptCalls { get; private set; }
        public List<ConceptExtractionInput> Inputs { get; } = [];
        public async Task<DocumentVisionResult> ExtractPageContentAsync(DocumentVisionInput input, CancellationToken cancellationToken = default)
        {
            VisionCalls.Add(input.PageNumber);
            if (input.PageNumber == FailVisionPage) throw new LlmProviderRequestException("테스트 페이지 오류");
            if (input.PageNumber == BlockPage) { Blocked.TrySetResult(); await Task.Delay(Timeout.Infinite, cancellationToken); }
            return VisionResult ?? new DocumentVisionResult(new string('가', 1000));
        }
        public Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(ConceptExtractionInput input, CancellationToken cancellationToken = default)
        {
            ConceptCalls++;
            Inputs.Add(input);
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
