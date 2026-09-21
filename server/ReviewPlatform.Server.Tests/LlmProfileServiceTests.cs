using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
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

    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        var options = new DbContextOptionsBuilder<SyncDbContext>()
            .UseSqlite(connection)
            .Options;
        database = new SyncDbContext(options);
        await ServerDatabaseInitializer.InitializeAsync(database);
        service = new LlmProfileService(
            database,
            Options.Create(new LlmOptions
            {
                Provider = "ollama",
                Model = "qwen3:8b",
                BaseUrl = "http://127.0.0.1:11434"
            }));
    }

    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync();
        await connection.DisposeAsync();
    }

    [Fact]
    public async Task FirstRead_SeedsBootstrapProfileForEveryPurpose()
    {
        var settings = await service.GetSettingsAsync(
            TestContext.Current.CancellationToken);

        var profile = Assert.Single(settings.Profiles);
        Assert.Equal("ollama", profile.Provider);
        Assert.Equal("qwen3-vl:8b-instruct", profile.Model);
        Assert.Equal(profile.Id,
            settings.Assignments[LlmPurposes.QuestionGeneration]);
        Assert.Equal(profile.Id,
            settings.Assignments[LlmPurposes.ConceptExtraction]);
        Assert.Equal(profile.Id,
            settings.Assignments[LlmPurposes.DocumentVision]);
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
                    "qwen3:4b",
                    "http://127.0.0.1:11434"),
                new LlmProfileInput(
                    "quality",
                    "정밀 개념 추출",
                    "ollama",
                    "qwen3:8b",
                    "http://127.0.0.1:11434")
            ],
            new Dictionary<string, string>
            {
                [LlmPurposes.QuestionGeneration] = "fast",
                [LlmPurposes.ConceptExtraction] = "quality",
                [LlmPurposes.DocumentVision] = "quality"
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
        Assert.Equal("qwen3:4b", questions.Model);
        Assert.Equal("qwen3:8b", concepts.Model);
        var vision = await service.GetActiveProfileAsync(
            LlmPurposes.DocumentVision,
            TestContext.Current.CancellationToken);
        Assert.Equal("qwen3:8b", vision.Model);
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
                    "qwen3:8b",
                    "http://127.0.0.1:11434")
            ],
            new Dictionary<string, string>
            {
                [LlmPurposes.QuestionGeneration] = "missing",
                [LlmPurposes.ConceptExtraction] = "only",
                [LlmPurposes.DocumentVision] = "only"
            });

        var exception = await Assert.ThrowsAsync<LlmProfileValidationException>(
            () => service.UpdateSettingsAsync(
                request,
                TestContext.Current.CancellationToken));

        Assert.Contains("존재하지 않는", exception.Message);
    }

    [Fact]
    public async Task ExistingDefaultProfile_AddsVisionPurposeAndUpgradesQwenModel()
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var profile = await database.LlmProfiles.SingleAsync(
            TestContext.Current.CancellationToken);
        profile.Model = "qwen3:8b";
        var visionAssignment = await database.LlmPurposeAssignments
            .SingleAsync(
                assignment => assignment.Purpose == LlmPurposes.DocumentVision,
                TestContext.Current.CancellationToken);
        database.LlmPurposeAssignments.Remove(visionAssignment);
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);

        var settings = await service.GetSettingsAsync(
            TestContext.Current.CancellationToken);

        Assert.Equal(
            "qwen3-vl:8b-instruct",
            Assert.Single(settings.Profiles).Model);
        Assert.Equal("default", settings.Assignments[LlmPurposes.DocumentVision]);
    }

    [Fact]
    public async Task UserSelectedModel_IsNotOverwrittenAfterVisionMigration()
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var profile = await database.LlmProfiles.SingleAsync(
            TestContext.Current.CancellationToken);
        profile.Model = "qwen3:8b";
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);

        var settings = await service.GetSettingsAsync(
            TestContext.Current.CancellationToken);

        Assert.Equal(
            "qwen3:8b",
            Assert.Single(settings.Profiles, profile => profile.Id == "default").Model);
        Assert.Contains(settings.Profiles, profile =>
            profile.Model == "qwen3-vl:8b-instruct");
    }

    [Fact]
    public async Task ManagedReasoningVisionProfile_IsUpgradedToInstructVariant()
    {
        await service.GetSettingsAsync(TestContext.Current.CancellationToken);
        var profile = await database.LlmProfiles.SingleAsync(
            TestContext.Current.CancellationToken);
        profile.Model = "qwen3-vl:8b";
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);

        var settings = await service.GetSettingsAsync(
            TestContext.Current.CancellationToken);

        Assert.Equal(
            "qwen3-vl:8b-instruct",
            Assert.Single(settings.Profiles).Model);
    }

    [Fact]
    public async Task Update_RejectsReasoningVariantForDocumentVision()
    {
        var request = new UpdateLlmProfileSettingsRequest(
            [
                new LlmProfileInput(
                    "reasoning-vision",
                    "추론형 비전",
                    "ollama",
                    "qwen3-vl:8b",
                    "http://127.0.0.1:11434")
            ],
            new Dictionary<string, string>
            {
                [LlmPurposes.QuestionGeneration] = "reasoning-vision",
                [LlmPurposes.ConceptExtraction] = "reasoning-vision",
                [LlmPurposes.DocumentVision] = "reasoning-vision"
            });

        var exception = await Assert.ThrowsAsync<LlmProfileValidationException>(
            () => service.UpdateSettingsAsync(
                request,
                TestContext.Current.CancellationToken));

        Assert.Contains("qwen3-vl:8b-instruct", exception.Message);
        Assert.Contains("thinking 필드", exception.Message);
    }
}
