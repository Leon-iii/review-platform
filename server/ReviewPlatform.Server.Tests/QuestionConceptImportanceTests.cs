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
        Assert.Equal(7, input.QuestionBudgetForTokenLimit);
        Assert.Equal(7, input.MinimumOutputQuestions);
        Assert.Equal(2, provider.Inputs.Count);
        Assert.All(provider.Inputs, call => { Assert.Single(call.ConceptPlans!); Assert.Empty(call.SourceText); });
        Assert.Equal([5], provider.Inputs[0].ConceptPlans!.Single().TargetDifficulties);
        Assert.Equal([4, 4, 4, 5, 5, 5, 5], provider.Inputs[1].ConceptPlans!.Single().TargetDifficulties);
        var prompt = QuestionGenerationPrompt.BuildUserPrompt(input);
        Assert.DoesNotContain("CONCEPT ALLOCATION", prompt);
        Assert.Contains("\"questionCount\":7", prompt);
        var schema = QuestionGenerationPrompt.BuildQuestionSchema(input);
        var item = schema["properties"]!["questions"]!["items"]!;
        Assert.DoesNotContain("primaryConceptId", item["required"]!.AsArray().Select(n => n!.GetValue<string>()));
        Assert.Null(item["properties"]!["primaryConceptId"]);
        Assert.DoesNotContain("Set primaryConceptId", QuestionGenerationPrompt.ConceptSystemPrompt);
        var record = await database.AiGenerationRecords.SingleAsync(TestContext.Current.CancellationToken);
        Assert.Contains("primaryConceptId", record.OutputJson!);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("invented")]
    [InlineData("allocation")]
    public async Task ServerOwnsConceptMappingRegardlessOfModelEcho(string failure)
    {
        var provider = new PlannedProvider { Failure = failure };
        var response = await new QuestionGenerationService(database, provider)
            .GenerateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.Equal(1, response.Questions.Count(q => q.PrimaryConceptId == "low"));
        Assert.Equal(7, response.Questions.Count(q => q.PrimaryConceptId == "high"));
        var record = await database.AiGenerationRecords.SingleAsync(TestContext.Current.CancellationToken);
        Assert.Equal("succeeded", record.Status);
        Assert.NotNull(record.OutputJson);
    }

    [Fact]
    public void AutomaticPerConceptCapDoesNotOmitConceptsOrTruncateJob()
    {
        var plans = QuestionConceptAllocator.Allocate(
            Enumerable.Range(0, 80).Select(i => Concept(i.ToString(), "veryHigh")).ToArray(),
            true, true, "high", 0, 3, perConceptRequests: true);
        Assert.Equal(240, plans.Sum(p => p.QuestionCount));
        Assert.All(plans, p => Assert.Equal(3, p.QuestionCount));
    }

    [Fact]
    public void AggregateContentLimitNoLongerAppliesToSeparateRequests()
    {
        var concepts = Enumerable.Range(0, 10).Select(i =>
            new QuestionGenerationConcept(i.ToString(), "제목", new string('가', 8000))).ToArray();
        Assert.Equal(10, QuestionConceptAllocator.Allocate(concepts, false, true,
            "low", 0, 120, perConceptRequests: true).Count);
    }

    [Fact]
    public async Task PartialFailurePreservesValidatedSuccessAndReportsProgress()
    {
        var progress = new List<QuestionGenerationProgress>();
        var provider = new PlannedProvider { FailedConceptId = "low" };
        var response = await new QuestionGenerationService(database, provider)
            .GenerateAsync(Request() with { SourceText = null }, TestContext.Current.CancellationToken,
                value => { progress.Add(value); return Task.CompletedTask; });
        Assert.Equal(7, response.Questions.Count);
        Assert.Equal("low", Assert.Single(response.Failures!).ConceptId);
        Assert.Equal(2, progress[^1].CompletedConcepts);
        Assert.Equal(1, progress[^1].FailedConcepts);
        Assert.Equal("partial", (await database.AiGenerationRecords.SingleAsync(
            TestContext.Current.CancellationToken)).Status);
    }

    [Fact]
    public async Task BadCountFailsOnlyAffectedConceptWithoutAutomaticRetry()
    {
        var provider = new PlannedProvider { BadCountConceptId = "low" };
        var response = await new QuestionGenerationService(database, provider)
            .GenerateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.Equal(7, response.Questions.Count);
        Assert.Single(response.Failures!);
        Assert.Equal(2, provider.Inputs.Count);
    }

    [Fact]
    public async Task AllFailedConceptsProduceAnErrorAndFailureHistory()
    {
        var provider = new PlannedProvider { FailedConceptId = "all" };
        await Assert.ThrowsAsync<LlmOutputValidationException>(() =>
            new QuestionGenerationService(database, provider).GenerateAsync(Request(), TestContext.Current.CancellationToken));
        Assert.Equal("failed", (await database.AiGenerationRecords.SingleAsync(
            TestContext.Current.CancellationToken)).Status);
    }

    [Fact]
    public void SchemaAndCommonPrefixAreIdenticalAcrossConceptsTypesCountsAndSources()
    {
        var first = new QuestionGenerationInput("", 1, ["shortAnswer"], "자료1", "v11",
            ConceptPlans: [new(Concept("one", "low"), 1)], BindConceptOnServer: true);
        var second = first with { QuestionCount = 7, QuestionTypes = ["trueFalse"], SourceLabel = "자료2",
            ConceptPlans = [new(Concept("two", "high"), 7)] };
        Assert.Equal(QuestionGenerationPrompt.BuildQuestionSchema(first).ToJsonString(),
            QuestionGenerationPrompt.BuildQuestionSchema(second).ToJsonString());
        Assert.Equal(QuestionGenerationPrompt.GetSystemPrompt(first), QuestionGenerationPrompt.GetSystemPrompt(second));
        Assert.DoesNotContain("two", QuestionGenerationPrompt.BuildUserPrompt(first));
        Assert.DoesNotContain("sourceIds", QuestionGenerationPrompt.BuildQuestionSchema(first).ToJsonString());
        Assert.Contains("as broadly as correctness allows", QuestionGenerationPrompt.GetSystemPrompt(first));
        var description = QuestionGenerationPrompt.BuildQuestionSchema(first)["properties"]!["questions"]!["items"]!["properties"]!["acceptableAnswers"]!["description"]!.GetValue<string>();
        Assert.Contains("as many unambiguously valid synonyms", description);
    }

    private static GenerateQuestionsRequest Request() => new(
        "구조화된 개념으로 생성할 충분히 긴 학습 내용입니다.", null, ["shortAnswer"], "자료",
        "automatic", "medium", 4, 5,
        [Concept("low", "veryLow"), Concept("high", "veryHigh")], true);

    [Fact]
    public async Task ManualTotalCanExceedPerCallLimitWhenSplitAcrossConcepts()
    {
        var provider = new PlannedProvider { MaximumQuestionsPerRequest = 1 };
        var response = await new QuestionGenerationService(database, provider)
            .GenerateAsync(Request() with { GenerationMode = "manual", QuestionCount = 2 }, TestContext.Current.CancellationToken);
        Assert.Equal(2, response.Questions.Count);
        Assert.Equal(2, provider.Inputs.Count);
        Assert.All(provider.Inputs, call => Assert.Equal(1, call.QuestionCount));
    }

    [Fact]
    public async Task ManualTotalBelowCoverageSkipsZeroPlansWithoutProviderCalls()
    {
        var provider = new PlannedProvider();
        var response = await new QuestionGenerationService(database, provider)
            .GenerateAsync(Request() with { GenerationMode = "manual", QuestionCount = 1 }, TestContext.Current.CancellationToken);
        Assert.Single(provider.Inputs);
        Assert.Equal("high", Assert.Single(response.Questions).PrimaryConceptId);
    }

    [Fact]
    public async Task CancellationPreservesCompletedConceptCheckpointAndStopsFurtherCalls()
    {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var provider = new PlannedProvider();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new QuestionGenerationService(database, provider).GenerateAsync(Request(), cancellation.Token,
                progress => { if (progress.CompletedConcepts == 1) cancellation.Cancel(); return Task.CompletedTask; }));
        Assert.Single(provider.Inputs);
        var record = await database.AiGenerationRecords.SingleAsync(TestContext.Current.CancellationToken);
        Assert.Equal("canceled", record.Status);
        Assert.Contains("\"primaryConceptId\":\"low\"", record.OutputJson!);
    }

    private sealed class PlannedProvider : ILLMProvider
    {
        public string ProviderName => "fake";
        public string ModelName => "fake";
        public int MaximumQuestionsPerRequest { get; init; } = 120;
        public string? Failure { get; init; }
        public string? FailedConceptId { get; init; }
        public string? BadCountConceptId { get; init; }
        public List<QuestionGenerationInput> Inputs { get; } = [];
        public QuestionGenerationInput? LastInput { get; private set; }
        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input, CancellationToken cancellationToken = default)
        {
            LastInput = input;
            Inputs.Add(input);
            if (FailedConceptId == "all" || input.ConceptPlans!.Single().Concept.Id == FailedConceptId)
                throw new LlmProviderRequestException("테스트 요청 실패");
            var questions = input.ConceptPlans!.SelectMany(p => Enumerable.Range(0, p.QuestionCount)
                .Select(i => new GeneratedQuestionDraft("shortAnswer", $"{p.Concept.Title} 문제 {i}",
                    [], ["정답"], "해설", 1, [input.SourceReference], p.Concept.Id))).ToList();
            questions[0] = questions[0] with { PrimaryConceptId = Failure switch
                { "missing" => null, "invented" => "not-input", "allocation" => "high", _ => questions[0].PrimaryConceptId } };
            if (input.ConceptPlans!.Single().Concept.Id == BadCountConceptId) questions.Clear();
            return Task.FromResult<IReadOnlyList<GeneratedQuestionDraft>>(questions);
        }
    }
}
