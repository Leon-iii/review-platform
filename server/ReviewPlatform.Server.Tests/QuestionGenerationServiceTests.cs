using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class QuestionGenerationServiceTests : IAsyncLifetime
{
    private readonly SqliteConnection connection = new("Data Source=:memory:");
    private SyncDbContext database = null!;

    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        var options = new DbContextOptionsBuilder<SyncDbContext>()
            .UseSqlite(connection)
            .Options;
        database = new SyncDbContext(options);
        await ServerDatabaseInitializer.InitializeAsync(database);
    }

    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync();
        await connection.DisposeAsync();
    }

    [Fact]
    public async Task ValidProviderOutput_ReturnsDraftsAndStoresProvenance()
    {
        var provider = new FakeLlmProvider(
        [
            MultipleChoiceQuestion(),
            ShortAnswerQuestion()
        ]);
        var service = new QuestionGenerationService(database, provider);
        var sourceText = "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.";

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            sourceText,
            2,
            ["multipleChoice", "shortAnswer"],
            "전자기학 노트"), TestContext.Current.CancellationToken);

        Assert.Equal(2, response.Questions.Count);
        Assert.All(response.Questions, question => Assert.Equal("draft", question.Status));
        Assert.Equal("fake", response.Metadata.Provider);
        Assert.Equal("fake-model", response.Metadata.Model);
        Assert.Equal(QuestionGenerationService.PromptVersion,
            response.Metadata.PromptVersion);
        Assert.Equal(64, response.Metadata.InputHash.Length);

        var record = await database.AiGenerationRecords.SingleAsync(
            TestContext.Current.CancellationToken);
        Assert.Equal("succeeded", record.Status);
        Assert.Equal(response.Metadata.InputHash, record.InputHash);
        Assert.DoesNotContain(sourceText, record.OutputJson ?? string.Empty);
        Assert.Null(record.Error);
    }

    [Fact]
    public async Task InvalidRequest_DoesNotCallProviderOrCreateHistory()
    {
        var provider = new FakeLlmProvider([ShortAnswerQuestion()]);
        var logger = new RecordingLogger<QuestionGenerationService>();
        var service = new QuestionGenerationService(database, provider, logger);

        await Assert.ThrowsAsync<QuestionGenerationRequestException>(() =>
            service.GenerateAsync(new GenerateQuestionsRequest(
                "짧음",
                1,
                ["shortAnswer"],
                null), TestContext.Current.CancellationToken));

        Assert.Equal(0, provider.CallCount);
        Assert.Empty(await database.AiGenerationRecords.ToListAsync(
            TestContext.Current.CancellationToken));
        var entry = Assert.Single(logger.Entries);
        Assert.Equal(LogLevel.Warning, entry.Level);
        Assert.IsType<QuestionGenerationRequestException>(entry.Exception);
        Assert.Contains("SourceLength=2", entry.Message);
        Assert.DoesNotContain("짧음", entry.Message);
    }

    [Fact]
    public async Task AutomaticDensity_IsIncludedInLlmInstructions()
    {
        var provider = new FakeLlmProvider(
        [
            ShortAnswerQuestion(),
            ShortAnswerQuestion() with { Prompt = "가우스 법칙은 어떤 면을 기준으로 하는가?" }
        ]);
        var service = new QuestionGenerationService(database, provider);

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.",
            null,
            ["shortAnswer"],
            "전자기학 노트",
            "automatic",
            "low"), TestContext.Current.CancellationToken);

        Assert.Equal(2, response.Questions.Count);
        var input = Assert.IsType<QuestionGenerationInput>(provider.LastInput);
        Assert.True(input.IsAutomatic);
        Assert.Equal(1, input.MinimumQuestionsPerConcept);
        Assert.Equal(2, input.MaximumQuestionsPerConcept);
        var prompt = QuestionGenerationPrompt.BuildUserPrompt(input);
        Assert.Contains("1-2 questions for EACH identified concept", prompt);
        Assert.Contains("there is no fixed total", prompt);
        var schema = QuestionGenerationPrompt.BuildQuestionSchema(input);
        var questionArray = schema["properties"]!["questions"]!;
        Assert.Equal(1, questionArray["minItems"]!.GetValue<int>());
        Assert.Equal(QuestionGenerationInput.MaximumAutomaticQuestionCount,
            questionArray["maxItems"]!.GetValue<int>());
    }

    [Fact]
    public async Task InvalidAutomaticDensity_IsRejectedBeforeProviderCall()
    {
        var provider = new FakeLlmProvider([ShortAnswerQuestion()]);
        var service = new QuestionGenerationService(database, provider);

        await Assert.ThrowsAsync<QuestionGenerationRequestException>(() =>
            service.GenerateAsync(new GenerateQuestionsRequest(
                "자동 생성을 검증하기 위한 충분히 긴 학습 자료이다.",
                null,
                ["shortAnswer"],
                null,
                "automatic",
                "extra"), TestContext.Current.CancellationToken));

        Assert.Equal(0, provider.CallCount);
    }

    [Fact]
    public async Task PartialProviderOutput_IsRejectedAndRecordedAsFailure()
    {
        var provider = new FakeLlmProvider([ShortAnswerQuestion()]);
        var logger = new RecordingLogger<QuestionGenerationService>();
        var service = new QuestionGenerationService(database, provider, logger);
        const string sourceText = "충분히 긴 학습 자료를 이용해 두 문제를 생성한다.";

        await Assert.ThrowsAsync<LlmOutputValidationException>(() =>
            service.GenerateAsync(new GenerateQuestionsRequest(
                sourceText,
                2,
                ["shortAnswer"],
                null), TestContext.Current.CancellationToken));

        var record = await database.AiGenerationRecords.SingleAsync(
            TestContext.Current.CancellationToken);
        Assert.Equal("failed", record.Status);
        Assert.Null(record.OutputJson);
        Assert.Contains("다른 수", record.Error);

        var entry = Assert.Single(logger.Entries);
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.IsType<LlmOutputValidationException>(entry.Exception);
        Assert.Contains("Stage=output-validation", entry.Message);
        Assert.Contains("Provider=fake", entry.Message);
        Assert.Contains("Model=fake-model", entry.Message);
        Assert.Contains($"PromptVersion={QuestionGenerationService.PromptVersion}",
            entry.Message);
        Assert.Contains($"InputHash={record.InputHash}", entry.Message);
        Assert.Contains("ProviderOutputCount=1", entry.Message);
        Assert.DoesNotContain(sourceText, entry.Message);
    }

    [Fact]
    public async Task InvalidMultipleChoice_IsRejectedAsAWhole()
    {
        var invalid = MultipleChoiceQuestion() with
        {
            Choices =
            [
                new GeneratedQuestionChoice("정답 1", true),
                new GeneratedQuestionChoice("정답 2", true)
            ]
        };
        var logger = new RecordingLogger<QuestionGenerationService>();
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([invalid]),
            logger);

        await Assert.ThrowsAsync<LlmOutputValidationException>(() =>
            service.GenerateAsync(new GenerateQuestionsRequest(
                "객관식 문제를 만들기에 충분한 학습 자료 내용이다.",
                1,
                ["multipleChoice"],
                null), TestContext.Current.CancellationToken));

        Assert.Equal("failed", (await database.AiGenerationRecords.SingleAsync(
            TestContext.Current.CancellationToken)).Status);
        var logEntry = Assert.Single(logger.Entries);
        Assert.Contains("ValidationQuestionNumber=1", logEntry.Message);
        Assert.Contains("CorrectFlagCount=2", logEntry.Message);
    }

    [Fact]
    public async Task MultipleChoiceWithRedundantAcceptableAnswer_IsCanonicalized()
    {
        var redundantAnswer = MultipleChoiceQuestion() with
        {
            AcceptableAnswers = ["폐곡면의 선속과 내부 전하를 연결한다."]
        };
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([redundantAnswer]));

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            "객관식 정답 표현을 정규화하기 위한 충분히 긴 학습 자료 내용이다.",
            1,
            ["multipleChoice"],
            null), TestContext.Current.CancellationToken);

        var question = Assert.Single(response.Questions);
        Assert.Empty(question.AcceptableAnswers);
        Assert.Single(question.Choices, choice => choice.IsCorrect);
    }

    [Fact]
    public async Task MultipleChoiceAnswerTextWithoutCorrectFlag_IsRecovered()
    {
        var answerInWrongField = MultipleChoiceQuestion() with
        {
            Choices = MultipleChoiceQuestion().Choices
                .Select(choice => choice with { IsCorrect = false })
                .ToList(),
            AcceptableAnswers = ["폐곡면의 선속과 내부 전하를 연결한다."]
        };
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([answerInWrongField]));

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            "객관식 정답 플래그를 복구하기 위한 충분히 긴 학습 자료 내용이다.",
            1,
            ["multipleChoice"],
            null), TestContext.Current.CancellationToken);

        var question = Assert.Single(response.Questions);
        Assert.Empty(question.AcceptableAnswers);
        var correctChoice = Assert.Single(
            question.Choices,
            choice => choice.IsCorrect);
        Assert.Equal(
            "폐곡면의 선속과 내부 전하를 연결한다.",
            correctChoice.Text);
    }

    [Fact]
    public async Task ValidTrueFalseQuestion_IsAccepted()
    {
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([TrueFalseQuestion()]));

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            "지구는 태양 주위를 공전하며 한 바퀴 도는 데 약 1년이 걸린다.",
            1,
            ["trueFalse"],
            null), TestContext.Current.CancellationToken);

        var question = Assert.Single(response.Questions);
        Assert.Equal("trueFalse", question.Type);
        Assert.Equal(["O", "X"], question.Choices.Select(choice => choice.Text));
        Assert.Single(question.Choices, choice => choice.IsCorrect);
    }

    [Fact]
    public async Task LocalizedTrueFalseChoices_AreCanonicalized()
    {
        var localized = TrueFalseQuestion() with
        {
            Choices =
            [
                new GeneratedQuestionChoice("참", true),
                new GeneratedQuestionChoice("거짓", false)
            ]
        };
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([localized]));

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            "O/X 문제를 만들기에 충분한 길이의 학습 자료 내용이다.",
            1,
            ["trueFalse"],
            null), TestContext.Current.CancellationToken);

        var choices = Assert.Single(response.Questions).Choices;
        Assert.Equal(["O", "X"], choices.Select(choice => choice.Text));
        Assert.True(choices[0].IsCorrect);
        Assert.False(choices[1].IsCorrect);
    }

    [Fact]
    public async Task TrueFalseAnswerInAcceptableAnswers_IsCanonicalized()
    {
        var answerOnly = TrueFalseQuestion() with
        {
            Choices = [],
            AcceptableAnswers = ["정답: X"]
        };
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([answerOnly]));

        var response = await service.GenerateAsync(new GenerateQuestionsRequest(
            "O/X 문제의 정답 복구를 검증하기 위한 충분히 긴 학습 자료이다.",
            1,
            ["trueFalse"],
            null), TestContext.Current.CancellationToken);

        var question = Assert.Single(response.Questions);
        Assert.Empty(question.AcceptableAnswers);
        Assert.False(question.Choices[0].IsCorrect);
        Assert.True(question.Choices[1].IsCorrect);
    }

    [Fact]
    public async Task AmbiguousTrueFalseAnswer_IsRejected()
    {
        var ambiguous = TrueFalseQuestion() with
        {
            Choices =
            [
                new GeneratedQuestionChoice("찬성", false),
                new GeneratedQuestionChoice("반대", false)
            ]
        };
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([ambiguous]));

        await Assert.ThrowsAsync<LlmOutputValidationException>(() =>
            service.GenerateAsync(new GenerateQuestionsRequest(
                "모호한 O/X 출력을 거부하기 위한 충분히 긴 학습 자료이다.",
                1,
                ["trueFalse"],
                null), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task MissingSourceReference_IsRejectedAsAWhole()
    {
        var invalid = ShortAnswerQuestion() with { SourceIds = [] };
        var service = new QuestionGenerationService(
            database,
            new FakeLlmProvider([invalid]));

        var exception = await Assert.ThrowsAsync<LlmOutputValidationException>(() =>
            service.GenerateAsync(new GenerateQuestionsRequest(
                "학습자료 참조가 반드시 필요한 충분히 긴 내용이다.",
                1,
                ["shortAnswer"],
                null), TestContext.Current.CancellationToken));

        Assert.Contains("학습자료 참조", exception.Message);
        Assert.Equal("failed", (await database.AiGenerationRecords.SingleAsync(
            TestContext.Current.CancellationToken)).Status);
    }

    private static GeneratedQuestionDraft MultipleChoiceQuestion() => new(
        "multipleChoice",
        "가우스 법칙의 설명으로 옳은 것은?",
        [
            new GeneratedQuestionChoice("폐곡면의 선속과 내부 전하를 연결한다.", true),
            new GeneratedQuestionChoice("자기장의 회전만 설명한다.", false)
        ],
        [],
        "가우스 법칙의 정의를 확인한다.",
        2,
        ["provided-source"]);

    private static GeneratedQuestionDraft ShortAnswerQuestion() => new(
        "shortAnswer",
        "폐곡면의 전기선속과 내부 전하를 연결하는 법칙은?",
        [],
        ["가우스 법칙"],
        "가우스 법칙의 이름을 묻는다.",
        1,
        ["provided-source"]);

    private static GeneratedQuestionDraft TrueFalseQuestion() => new(
        "trueFalse",
        "지구는 태양 주위를 공전한다.",
        [
            new GeneratedQuestionChoice("O", true),
            new GeneratedQuestionChoice("X", false)
        ],
        [],
        "학습 자료에 명시된 사실이다.",
        1,
        ["provided-source"]);

    private sealed class FakeLlmProvider(
        IReadOnlyList<GeneratedQuestionDraft> questions) : ILLMProvider
    {
        public string ProviderName => "fake";

        public string ModelName => "fake-model";

        public int CallCount { get; private set; }

        public QuestionGenerationInput? LastInput { get; private set; }

        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            LastInput = input;
            return Task.FromResult(questions);
        }
    }

    private sealed class RecordingLogger<T> : ILogger<T>
    {
        public List<LogEntry> Entries { get; } = [];

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => EmptyScope.Instance;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            Entries.Add(new LogEntry(logLevel, formatter(state, exception), exception));
        }
    }

    private sealed record LogEntry(
        LogLevel Level,
        string Message,
        Exception? Exception);

    private sealed class EmptyScope : IDisposable
    {
        public static EmptyScope Instance { get; } = new();

        public void Dispose()
        {
        }
    }
}
