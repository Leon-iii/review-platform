using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class QuestionConceptImportanceTests : IAsyncLifetime
{
    private readonly SqliteConnection connection = new("Data Source=:memory:");
    private SyncDbContext database = null!;
    private static QuestionGenerationConcept Concept(string id, string importance) =>
        new(id, $"개념 {id}", $"{id} 개념의 정답을 결정하는 충분히 긴 학습 내용입니다.", importance);

    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        database = new SyncDbContext(new DbContextOptionsBuilder<SyncDbContext>()
            .UseSqlite(connection).Options);
        await ServerDatabaseInitializer.InitializeAsync(database);
    }
    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync();
        await connection.DisposeAsync();
    }

    [Theory]
    [InlineData("low", 1, 1, 2, 3, 3)]
    [InlineData("medium", 1, 3, 4, 5, 7)]
    [InlineData("high", 2, 4, 6, 8, 10)]
    public void AutomaticAllocatesImportanceWithoutChangingDifficulty(
        string density, int a, int b, int c, int d, int e)
    {
        var concepts = new[] { "veryLow", "low", "medium", "high", "veryHigh" }
            .Select((importance, i) => Concept(i.ToString(), importance)).ToArray();
        var plans = QuestionConceptAllocator.Allocate(concepts, true, true, density, 0, 120);
        Assert.Equal(new[] { a, b, c, d, e }, plans.Select(plan => plan.QuestionCount));
    }

    [Fact]
    public void ManualFixedTotalPreservesCoverageAndWeight()
    {
        var plans = QuestionConceptAllocator.Allocate(
            [Concept("low", "veryLow"), Concept("high", "veryHigh")], true, false, null, 20, 120);
        Assert.Equal(new[] { 4, 16 }, plans.Select(p => p.QuestionCount));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(5)]
    [InlineData(10)]
    public void CapNeverExceededAndCoverageIsPrioritized(int limit)
    {
        var plans = QuestionConceptAllocator.Allocate(
            [Concept("low", "veryLow"), Concept("mid", "medium"), Concept("high", "veryHigh")],
            true, true, "high", 0, limit);
        Assert.Equal(limit, plans.Sum(p => p.QuestionCount));
        if (limit >= 3) Assert.All(plans, p => Assert.True(p.QuestionCount >= 1));
        if (limit == 1) Assert.Equal(new[] { 0, 0, 1 }, plans.Select(p => p.QuestionCount));
    }

    [Fact]
    public void DisabledImportanceAllocatesEqually()
    {
        var concepts = new[] { Concept("low", "veryLow"), Concept("high", "veryHigh") };
        Assert.Equal(new[] { 4, 4 }, QuestionConceptAllocator.Allocate(
            concepts, false, true, "medium", 0, 120).Select(p => p.QuestionCount));
        Assert.Equal(new[] { 10, 10 }, QuestionConceptAllocator.Allocate(
            concepts, false, false, null, 20, 120).Select(p => p.QuestionCount));
    }

    [Fact]
    public void InvalidOrDuplicateConceptsRejected()
    {
        Assert.Throws<QuestionGenerationRequestException>(() => QuestionConceptAllocator.Allocate(
            [Concept("same", "medium"), Concept("same", "medium")], true, true, "low", 0, 120));
        Assert.Throws<QuestionGenerationRequestException>(() => QuestionConceptAllocator.Allocate(
            [Concept("bad", "invalid")], true, true, "low", 0, 120));
        Assert.Throws<QuestionGenerationRequestException>(() => QuestionConceptAllocator.Allocate(
            [], true, true, "low", 0, 120));
    }

    [Fact]
    public async Task StructuredMappingAndAllocationAreValidatedAndPersisted()
    {
        var provider = new PlannedProvider();
        var response = await new QuestionGenerationService(database, provider)
            .GenerateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.Equal(8, response.Questions.Count);
        Assert.Equal(1, response.Questions.Count(q => q.PrimaryConceptId == "low"));
        Assert.Equal(7, response.Questions.Count(q => q.PrimaryConceptId == "high"));
        Assert.All(response.Questions, q => { Assert.Equal(1, q.Difficulty); Assert.Equal("draft", q.Status); });
        var input = provider.LastInput!;
        Assert.Equal(8, input.QuestionBudgetForTokenLimit);
        Assert.Equal(8, input.MinimumOutputQuestions);
        var prompt = QuestionGenerationPrompt.BuildUserPrompt(input);
        Assert.Contains("CONCEPT ALLOCATION", prompt);
        Assert.Contains("\"questionCount\":7", prompt);
        var schema = QuestionGenerationPrompt.BuildQuestionSchema(input);
        var item = schema["properties"]!["questions"]!["items"]!;
        Assert.Contains("primaryConceptId", item["required"]!.AsArray().Select(n => n!.GetValue<string>()));
        Assert.Equal(new[] { "low", "high" }, item["properties"]!["primaryConceptId"]!["enum"]!
            .AsArray().Select(n => n!.GetValue<string>()));
        var record = await database.AiGenerationRecords.SingleAsync(TestContext.Current.CancellationToken);
        Assert.Contains("primaryConceptId", record.OutputJson!);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("invented")]
    [InlineData("allocation")]
    public async Task BadConceptMappingRejectsEntireResponse(string failure)
    {
        var provider = new PlannedProvider { Failure = failure };
        await Assert.ThrowsAsync<LlmOutputValidationException>(() =>
            new QuestionGenerationService(database, provider).GenerateAsync(Request(), TestContext.Current.CancellationToken));
        var record = await database.AiGenerationRecords.SingleAsync(TestContext.Current.CancellationToken);
        Assert.Equal("failed", record.Status);
        Assert.Null(record.OutputJson);
    }

    private static GenerateQuestionsRequest Request() => new(
        "구조화된 개념으로 생성할 충분히 긴 학습 내용입니다.", null, ["shortAnswer"], "자료",
        "automatic", "medium", 4, 5,
        [Concept("low", "veryLow"), Concept("high", "veryHigh")], true);

    private sealed class PlannedProvider : ILLMProvider
    {
        public string ProviderName => "fake";
        public string ModelName => "fake";
        public string? Failure { get; init; }
        public QuestionGenerationInput? LastInput { get; private set; }
        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input, CancellationToken cancellationToken = default)
        {
            LastInput = input;
            var questions = input.ConceptPlans!.SelectMany(p => Enumerable.Range(0, p.QuestionCount)
                .Select(i => new GeneratedQuestionDraft("shortAnswer", $"{p.Concept.Title} 문제 {i}",
                    [], ["정답"], "해설", 1, [input.SourceReference], p.Concept.Id))).ToList();
            questions[0] = questions[0] with { PrimaryConceptId = Failure switch
                { "missing" => null, "invented" => "not-input", "allocation" => "high", _ => questions[0].PrimaryConceptId } };
            return Task.FromResult<IReadOnlyList<GeneratedQuestionDraft>>(questions);
        }
    }
}
