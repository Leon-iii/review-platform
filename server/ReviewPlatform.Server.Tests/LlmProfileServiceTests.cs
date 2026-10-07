using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Logging.Abstractions;
using System.Net;
using System.Text;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class LlmProfileServiceTests : IAsyncLifetime
{
    private readonly SqliteConnection connection = new("Data Source=:memory:");
    private SyncDbContext database = null!;
    private LlmProfileService service = null!;
    private MemoryApiKeyStore apiKeys = null!;

    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        var options = new DbContextOptionsBuilder<SyncDbContext>()
            .UseSqlite(connection)
            .Options;
        database = new SyncDbContext(options);
        await ServerDatabaseInitializer.InitializeAsync(database);
        apiKeys = new MemoryApiKeyStore();
        service = new LlmProfileService(
            database,
            Options.Create(new LlmOptions
            {
                Provider = "ollama",
                Model = "qwen3:8b",
                BaseUrl = "http://127.0.0.1:11434"
            }),
            apiKeys,
            new OllamaModelMetadataService(new MetadataHttpClientFactory()));
    }

    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync();
        await connection.DisposeAsync();
    }

    [Theory]
    [InlineData("gpt-6-luna", "max")]
    [InlineData("gpt-5.6-terra", "xhigh")]
    [InlineData("gpt-5.4-mini-2026-03-17", "none")]
    [InlineData("gpt-5.5-pro", "high")]
    [InlineData("o3-pro", null)]
    public async Task NewlyRegisteredModels_PreserveEffortOnRead(string model, string? effort)
    {
        var assignments = LlmPurposes.All.ToDictionary(p => p, _ => "cloud");
        await service.UpdateSettingsAsync(new UpdateLlmProfileSettingsRequest(
            [new LlmProfileInput("cloud", "새 모델", "openai", model, ReasoningEffort: effort)],
            assignments), TestContext.Current.CancellationToken);
        Assert.Equal(effort, (await service.GetSettingsAsync(
            TestContext.Current.CancellationToken)).Profiles.Single(p => p.Id == "cloud").ReasoningEffort);
        Assert.Equal(effort, (await service.GetActiveProfileAsync(
            LlmPurposes.QuestionGeneration, TestContext.Current.CancellationToken)).ReasoningEffort);
    }

    [Theory]
    [InlineData("gpt-5.4-pro")]
    [InlineData("o1-mini")]
    [InlineData("o4-mini-deep-research")]
    public async Task KnownIncompatibleModels_AreRejectedWithoutChangingProfiles(string model)
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var request = new UpdateLlmProfileSettingsRequest(
            [new LlmProfileInput("new", "테스트", "openai", model)],
            LlmPurposes.All.ToDictionary(p => p, _ => "new"));
        await Assert.ThrowsAsync<LlmProfileValidationException>(() =>
            service.UpdateSettingsAsync(request, TestContext.Current.CancellationToken));
        Assert.Equal("default", (await service.GetActiveProfileAsync(
            LlmPurposes.QuestionGeneration, TestContext.Current.CancellationToken)).Id);
    }


    [Fact]
    public async Task LegacyVisionAssignment_IsNotExposed_AndExistingProfilesRemain()
    {
        var existing = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var profile = existing.Profiles.Single();
        database.LlmPurposeAssignments.Add(new ReviewPlatform.Server.Data.LlmPurposeAssignmentRecord { Purpose = "documentVision", ProfileId = profile.Id });
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);
        var settings = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(3, settings.Assignments.Count);
        Assert.DoesNotContain("documentVision", settings.Assignments.Keys);
        Assert.Equal(profile, settings.Profiles.Single());
        Assert.True(await database.LlmPurposeAssignments.AnyAsync(a => a.Purpose == "documentVision", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task FirstRead_SeedsBootstrapProfileForEveryPurpose()
    {
        var settings = await service.GetSettingsAsync(
            TestContext.Current.CancellationToken);

        var profile = Assert.Single(settings.Profiles);
        Assert.Equal("ollama", profile.Provider);
        Assert.Equal("qwen3-vl:8b-instruct", profile.Model);
        Assert.Equal(120, profile.MaximumQuestionsPerRequest);
        Assert.Equal(profile.Id,
            settings.Assignments[LlmPurposes.QuestionGeneration]);
        Assert.Equal(profile.Id,
            settings.Assignments[LlmPurposes.ConceptExtraction]);
        Assert.Equal(profile.Id,
            settings.Assignments[LlmPurposes.ConceptRevision]);
        Assert.Equal(3, settings.Assignments.Count);
    }

    [Fact]
    public async Task Update_PreservesReasoningEffortOnReadAndResetsWithAuto()
    {
        var assignments = LlmPurposes.All.ToDictionary(purpose => purpose, _ => "cloud");
        await service.UpdateSettingsAsync(new UpdateLlmProfileSettingsRequest(
            [new LlmProfileInput("cloud", "추론", "openai", "gpt-5-mini",
                ReasoningEffort: " high ")], assignments),
            TestContext.Current.CancellationToken);
        var active = await service.GetActiveProfileAsync(LlmPurposes.ConceptRevision,
            TestContext.Current.CancellationToken);
        Assert.Equal("high", active.ReasoningEffort);
        var settings = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        Assert.Equal("high", settings.Profiles.Single(p => p.Id == "cloud").ReasoningEffort);

        await service.UpdateSettingsAsync(new UpdateLlmProfileSettingsRequest(
            [new LlmProfileInput("cloud", "새 모델", "openai", "gpt-7-future")],
            assignments), TestContext.Current.CancellationToken);
        active = await service.GetActiveProfileAsync(LlmPurposes.ConceptRevision,
            TestContext.Current.CancellationToken);
        Assert.Null(active.ReasoningEffort);
    }

    [Theory]
    [InlineData("openai", "gpt-5-mini", "none")]
    [InlineData("openai", "gpt-4o-mini", "low")]
    [InlineData("openai", "gpt-7-future", "high")]
    [InlineData("ollama", "qwen3:8b", "high")]
    public async Task Update_RejectsUnsupportedReasoningBeforeChangingProfiles(
        string provider, string model, string effort)
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var request = new UpdateLlmProfileSettingsRequest(
            [new LlmProfileInput("new", "테스트", provider, model, ReasoningEffort: effort)],
            LlmPurposes.All.ToDictionary(p => p, _ => "new"));
        await Assert.ThrowsAsync<LlmProfileValidationException>(() =>
            service.UpdateSettingsAsync(request, TestContext.Current.CancellationToken));
        Assert.Equal("default", (await service.GetActiveProfileAsync(
            LlmPurposes.QuestionGeneration, TestContext.Current.CancellationToken)).Id);
    }

    [Fact]
    public async Task BootstrapOllamaAddress_IsAlwaysServerLocal()
    {
        var customService = new LlmProfileService(
            database,
            Options.Create(new LlmOptions
            {
                Provider = "ollama",
                Model = "qwen3:8b",
                BaseUrl = "http://remote-computer:11434"
            }),
            apiKeys,
            new OllamaModelMetadataService(new MetadataHttpClientFactory()));

        await customService.GetSettingsAsync(TestContext.Current.CancellationToken);

        var stored = await database.LlmProfiles.SingleAsync(
            TestContext.Current.CancellationToken);
        Assert.Equal(LlmOptions.LocalOllamaBaseUrl, stored.BaseUrl);
    }

    [Fact]
    public async Task Update_AllowsDifferentProfilesPerPurposeAtRuntime()
    {
        var request = new UpdateLlmProfileSettingsRequest(
            [
                new LlmProfileInput(
                    "fast",
                    "빠른 문제 생성",
                    "ollama",
                    "qwen3:4b"),
                new LlmProfileInput(
                    "quality",
                    "정밀 개념 추출",
                    "ollama",
                    "qwen3:8b")
            ],
            new Dictionary<string, string>
            {
                [LlmPurposes.QuestionGeneration] = "fast",
                [LlmPurposes.ConceptExtraction] = "quality",
                [LlmPurposes.ConceptRevision] = "fast",
            });

        await service.UpdateSettingsAsync(
            request,
            TestContext.Current.CancellationToken);

        var questions = await service.GetActiveProfileAsync(
            LlmPurposes.QuestionGeneration,
            TestContext.Current.CancellationToken);
        var concepts = await service.GetActiveProfileAsync(
            LlmPurposes.ConceptExtraction,
            TestContext.Current.CancellationToken);
        var revisions = await service.GetActiveProfileAsync(
            LlmPurposes.ConceptRevision,
            TestContext.Current.CancellationToken);
        Assert.Equal("qwen3:4b", questions.Model);
        Assert.Equal("qwen3:8b", concepts.Model);
        Assert.Equal("qwen3:4b", revisions.Model);
    }

    [Fact]
    public async Task Update_RejectsAssignmentToMissingProfile()
    {
        var request = new UpdateLlmProfileSettingsRequest(
            [
                new LlmProfileInput(
                    "only",
                    "유일한 프로필",
                    "ollama",
                    "qwen3:8b")
            ],
            new Dictionary<string, string>
            {
                [LlmPurposes.QuestionGeneration] = "missing",
                [LlmPurposes.ConceptExtraction] = "only",
                [LlmPurposes.ConceptRevision] = "only",
            });

        var exception = await Assert.ThrowsAsync<LlmProfileValidationException>(
            () => service.UpdateSettingsAsync(
                request,
                TestContext.Current.CancellationToken));

        Assert.Contains("존재하지 않는", exception.Message);
    }





    [Fact]
    public async Task ContextWindow_PersistsPerProfileAndReachesActiveProfile()
    {
        var initial = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var request = new UpdateLlmProfileSettingsRequest(
            initial.Profiles.Select(profile => new LlmProfileInput(
                profile.Id, profile.Name, profile.Provider, profile.Model, 32_768)).ToList(),
            initial.Assignments);
        await service.UpdateSettingsAsync(request, TestContext.Current.CancellationToken);

        database.ChangeTracker.Clear();
        var saved = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(32_768, Assert.Single(saved.Profiles).ContextWindowTokens);
        var active = await service.GetActiveProfileAsync(
            LlmPurposes.ConceptExtraction, TestContext.Current.CancellationToken);
        Assert.Equal(32_768, active.ContextWindowTokens);
    }

    [Theory]
    [InlineData("ollama", 65_536)]
    [InlineData("ollama", 1_024)]
    [InlineData("openai", 8_192)]
    public async Task ContextWindow_RejectsUnsupportedValueWithoutChangingProfile(
        string provider, int tokens)
    {
        var initial = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var request = new UpdateLlmProfileSettingsRequest(
            initial.Profiles.Select(profile => new LlmProfileInput(
                profile.Id, profile.Name, provider, profile.Model, tokens)).ToList(),
            initial.Assignments);
        await Assert.ThrowsAsync<LlmProfileValidationException>(() =>
            service.UpdateSettingsAsync(request, TestContext.Current.CancellationToken));
        Assert.Null(Assert.Single((await service.GetSettingsAsync(
            TestContext.Current.CancellationToken)).Profiles).ContextWindowTokens);
    }

    [Fact]
    public async Task IndependentPurposeSettings_PersistWithoutRecreatingUnusedProfiles()
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var profiles = LlmPurposes.All.Select(purpose => new LlmProfileInput(
            $"purpose-{purpose}", purpose, "openai", "gpt-5-mini",
            ReasoningEffort: purpose == LlmPurposes.QuestionGeneration ? "high" : "low"))
            .ToList();
        var assignments = LlmPurposes.All.ToDictionary(
            purpose => purpose, purpose => $"purpose-{purpose}");
        await service.UpdateSettingsAsync(new UpdateLlmProfileSettingsRequest(
            profiles, assignments, new Dictionary<string, string?> { ["openai"] = "test-key" }),
            TestContext.Current.CancellationToken);

        database.ChangeTracker.Clear();
        for (var index = 0; index < 2; index++)
        {
            var settings = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
            Assert.Equal(3, settings.Profiles.Count);
            Assert.True(settings.ApiKeyConfigured["openai"]);
            Assert.DoesNotContain(settings.Profiles, profile => profile.Id == "default");
            foreach (var purpose in LlmPurposes.All)
            {
                var active = await service.GetActiveProfileAsync(purpose,
                    TestContext.Current.CancellationToken);
                Assert.Equal($"purpose-{purpose}", active.Id);
                Assert.Equal(purpose == LlmPurposes.QuestionGeneration ? "high" : "low",
                    active.ReasoningEffort);
            }
        }
    }

    [Theory]
    [InlineData("ollama", "qwen3-vl:8b-instruct", 40)]
    [InlineData("openai", "gpt-5-mini", 100)]
    [InlineData("openai", "gpt-5-mini", 101)]
    [InlineData("ollama", "qwen3-vl:8b-instruct", 200)]
    public async Task QuestionLimit_PersistsAndAppliesToNextRequestWithoutRestart(
        string provider, string model, int limit)
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var resolver = new RuntimeLlmProviderResolver(service, apiKeys,
            new MetadataHttpClientFactory(), NullLoggerFactory.Instance);
        var before = await resolver.ResolveAsync(LlmPurposes.QuestionGeneration,
            TestContext.Current.CancellationToken);
        var profiles = LlmPurposes.All.Select(purpose => new LlmProfileInput(
            $"purpose-{purpose}", purpose, provider, model,
            MaximumQuestionsPerRequest: purpose == LlmPurposes.QuestionGeneration ? limit : 120)).ToList();
        await service.UpdateSettingsAsync(new UpdateLlmProfileSettingsRequest(profiles,
            LlmPurposes.All.ToDictionary(p => p, p => $"purpose-{p}")),
            TestContext.Current.CancellationToken);
        database.ChangeTracker.Clear();
        var stored = await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(limit, stored.Profiles.Single(p => p.Id == "purpose-questionGeneration").MaximumQuestionsPerRequest);
        var after = await resolver.ResolveAsync(LlmPurposes.QuestionGeneration,
            TestContext.Current.CancellationToken);
        Assert.Equal(limit, after.MaximumQuestionsPerRequest);
        Assert.Equal(120, before.MaximumQuestionsPerRequest);
        Assert.Equal(120, (await service.GetActiveProfileAsync(LlmPurposes.ConceptExtraction,
            TestContext.Current.CancellationToken)).MaximumQuestionsPerRequest);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public async Task QuestionLimit_RejectsInvalidValueWithoutChangingProfiles(int limit)
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<LlmProfileValidationException>(() => service.UpdateSettingsAsync(
            new UpdateLlmProfileSettingsRequest(
                [new LlmProfileInput("new", "문제 생성", "openai", "gpt-5-mini", MaximumQuestionsPerRequest: limit)],
                LlmPurposes.All.ToDictionary(p => p, _ => "new")), TestContext.Current.CancellationToken));
        Assert.Equal(120, (await service.GetActiveProfileAsync(LlmPurposes.QuestionGeneration,
            TestContext.Current.CancellationToken)).MaximumQuestionsPerRequest);
    }

    [Fact]
    public async Task CapturedProfile_ResolvesOriginalProviderAndModel_AfterSettingsChange()
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var resolver = new RuntimeLlmProviderResolver(service, apiKeys,
            new MetadataHttpClientFactory(), NullLoggerFactory.Instance);
        var captured = await resolver.CaptureAsync(LlmPurposes.ConceptExtraction, TestContext.Current.CancellationToken);
        var profiles = LlmPurposes.All.Select(purpose => new LlmProfileInput(
            $"purpose-{purpose}", purpose, "openai", "gpt-5-mini")).ToList();
        await service.UpdateSettingsAsync(new UpdateLlmProfileSettingsRequest(profiles,
            LlmPurposes.All.ToDictionary(purpose => purpose, purpose => $"purpose-{purpose}")),
            TestContext.Current.CancellationToken);
        var pinned = await resolver.ResolveSnapshotAsync(captured, TestContext.Current.CancellationToken);
        var current = await resolver.ResolveAsync(LlmPurposes.ConceptExtraction, TestContext.Current.CancellationToken);
        Assert.Equal(captured.Provider, pinned.ProviderName);
        Assert.Equal(captured.Model, pinned.ModelName);
        Assert.Equal(captured.ContextWindowTokens, pinned.ContextWindowTokens);
        Assert.Equal("openai", current.ProviderName);
        Assert.Equal("gpt-5-mini", current.ModelName);
    }

    private sealed class MetadataHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(new MetadataHandler());
    }

    private sealed class MetadataHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960}}""",
                    Encoding.UTF8, "application/json")
            });
    }

    private sealed class MemoryApiKeyStore : ILlmApiKeyStore
    {
        private readonly Dictionary<string, string> values = [];

        public Task EnsureBootstrapKeysAsync(
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task<string> GetAsync(
            string provider,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(values.GetValueOrDefault(provider, string.Empty));

        public Task<IReadOnlyDictionary<string, bool>> GetConfiguredAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyDictionary<string, bool>>(
                LlmApiKeyProviders.All.ToDictionary(
                    provider => provider,
                    values.ContainsKey,
                    StringComparer.Ordinal));

        public Task UpdateAsync(
            IReadOnlyDictionary<string, string?>? apiKeys,
            CancellationToken cancellationToken = default)
        {
            if (apiKeys is null) return Task.CompletedTask;
            foreach (var pair in apiKeys)
            {
                if (!string.IsNullOrWhiteSpace(pair.Value))
                {
                    values[pair.Key] = pair.Value.Trim();
                }
            }
            return Task.CompletedTask;
        }
    }
}
