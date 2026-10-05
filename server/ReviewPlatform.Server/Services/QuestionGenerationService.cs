using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;

public sealed class QuestionGenerationService
{
    public const string PromptVersion = "question-generation-v15-haera-che";
    private const int MaximumSourceLength = 50_000;
    private static readonly HashSet<string> SupportedQuestionTypes =
    [
        "multipleChoice",
        "trueFalse",
        "shortAnswer",
        "essay"
    ];
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web);
    private readonly ILogger<QuestionGenerationService> log =
        NullLogger<QuestionGenerationService>.Instance;
    private readonly SyncDbContext database;
    private readonly ILlmProviderResolver providerResolver;

    public QuestionGenerationService(
        SyncDbContext database,
        ILlmProviderResolver providerResolver,
        ILogger<QuestionGenerationService>? logger = null)
    {
        this.database = database;
        this.providerResolver = providerResolver;
        log = logger ?? NullLogger<QuestionGenerationService>.Instance;
    }

    public QuestionGenerationService(
        SyncDbContext database,
        ILLMProvider provider,
        ILogger<QuestionGenerationService>? logger = null)
        : this(database, new FixedLlmProviderResolver(provider), logger)
    {
    }

    public async Task<GenerateQuestionsResponse> GenerateAsync(
        GenerateQuestionsRequest request,
        CancellationToken cancellationToken = default,
        Func<QuestionGenerationProgress, Task>? onProgress = null)
    {
        var provider = await providerResolver.ResolveAsync(
            LlmPurposes.QuestionGeneration,
            cancellationToken);
        QuestionGenerationInput input;
        try
        {
            input = ValidateAndNormalize(request, provider.MaximumQuestionsPerRequest);
        }
        catch (QuestionGenerationRequestException exception)
        {
            log.LogWarning(
                exception,
                "LLM generation request rejected. Provider={Provider} Model={Model} " +
                "GenerationMode={GenerationMode} AutomaticDensity={AutomaticDensity} " +
                "RequestedQuestionCount={RequestedQuestionCount} RequestedTypes={RequestedTypes} " +
                "SourceLength={SourceLength}",
                provider.ProviderName,
                provider.ModelName,
                LimitLogValue(request.GenerationMode),
                LimitLogValue(request.AutomaticDensity),
                request.QuestionCount,
                SummarizeQuestionTypes(request.QuestionTypes),
                request.SourceText?.Length ?? 0);
            throw;
        }

        var requestedAt = DateTimeOffset.UtcNow;
        var generationId = Guid.NewGuid().ToString();
        var record = new AiGenerationRecord
        {
            Id = generationId,
            Provider = provider.ProviderName,
            Model = provider.ModelName,
            PromptVersion = PromptVersion,
            RequestedAt = requestedAt,
            InputHash = ComputeHash(JsonSerializer.Serialize(input, JsonOptions)),
            SourceLabel = input.SourceLabel,
            RequestedQuestionCount = input.QuestionCount,
            QuestionTypesJson = JsonSerializer.Serialize(
                input.QuestionTypes,
                JsonOptions),
            Status = "running"
        };
        database.AiGenerationRecords.Add(record);
        var elapsed = Stopwatch.StartNew();
        var stage = "provider-request";
        int? providerOutputCount = null;

        try
        {
            var questions = new List<GeneratedQuestionDraft>();
            var failures = new List<QuestionGenerationFailure>();
            var plans = input.ConceptPlans?.Where(plan => plan.QuestionCount > 0).ToArray() ?? [];
            var completed = 0;
            if (plans.Length == 0)
            {
                var generated = await provider.GenerateQuestionsAsync(input, cancellationToken);
                providerOutputCount = generated.Count;
                stage = "output-validation";
                questions.AddRange(ValidateProviderOutput(generated, input));
            }
            else
            {
                // Resolve the profile once; each request contains exactly one concept snapshot.
                foreach (var plan in plans)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (onProgress is not null)
                        await onProgress(new(completed, plans.Length, questions.Count,
                            plan.Concept.Title, failures.Count));
                    var conceptInput = input with
                    {
                        SourceText = "", QuestionCount = plan.QuestionCount,
                        ConceptPlans = [plan], BindConceptOnServer = true
                    };
                    stage = "provider-request";
                    try
                    {
                        var generated = await provider.GenerateQuestionsAsync(conceptInput, cancellationToken);
                        providerOutputCount = generated.Count;
                        stage = "output-validation";
                        if (generated.Any(question => question is null))
                            throw new LlmOutputValidationException("생성된 문제 항목이 비어 있습니다.");
                        // IDs are application metadata, not something the model must infer or echo.
                        var bound = generated.Select(question => question with
                        {
                            PrimaryConceptId = plan.Concept.Id,
                            SourceIds = [input.SourceReference]
                        }).ToArray();
                        questions.AddRange(ValidateProviderOutput(bound, conceptInput));
                    }
                    catch (Exception exception) when (exception is LlmProviderRequestException or
                        LlmProviderUnavailableException or LlmOutputValidationException)
                    {
                        failures.Add(new(plan.Concept.Id, plan.Concept.Title, SafeError(exception)));
                        log.LogError(exception,
                            "Concept generation failed. GenerationId={GenerationId} ConceptId={ConceptId} " +
                            "Stage={Stage} Provider={Provider} Model={Model}",
                            generationId, plan.Concept.Id, stage, provider.ProviderName, provider.ModelName);
                    }
                    completed++;
                    record.OutputJson = JsonSerializer.Serialize(questions, JsonOptions);
                    record.Error = failures.Count == 0 ? null : JsonSerializer.Serialize(failures, JsonOptions);
                    await database.SaveChangesAsync(cancellationToken);
                    if (onProgress is not null)
                        await onProgress(new(completed, plans.Length, questions.Count, null, failures.Count));
                }
                if (questions.Count == 0)
                    throw new LlmOutputValidationException(
                        $"모든 개념의 문제 생성에 실패했습니다. {failures[0].Error}");
            }
            record.Status = failures.Count == 0 ? "succeeded" : "partial";
            record.OutputJson = JsonSerializer.Serialize(questions, JsonOptions);
            stage = "success-persistence";
            await database.SaveChangesAsync(cancellationToken);

            return new GenerateQuestionsResponse(
                new QuestionGenerationMetadata(
                    generationId,
                    provider.ProviderName,
                    provider.ModelName,
                    PromptVersion,
                    requestedAt,
                    record.InputHash,
                    input.SourceLabel),
                questions,
                failures);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            record.Status = "canceled";
            await database.SaveChangesAsync(CancellationToken.None);
            log.LogInformation(
                "LLM generation canceled. GenerationId={GenerationId} Stage={Stage} " +
                "Provider={Provider} Model={Model} DurationMs={DurationMs}",
                generationId,
                stage,
                provider.ProviderName,
                provider.ModelName,
                elapsed.ElapsedMilliseconds);
            throw;
        }
        catch (Exception exception)
        {
            record.Status = "failed";
            record.Error = SafeError(exception);
            log.LogError(
                exception,
                "LLM generation failed. GenerationId={GenerationId} Stage={Stage} " +
                "Provider={Provider} Model={Model} PromptVersion={PromptVersion} " +
                "InputHash={InputHash} GenerationMode={GenerationMode} " +
                "AutomaticDensity={AutomaticDensity} RequestedQuestionCount={RequestedQuestionCount} " +
                "QuestionTypes={QuestionTypes} ProviderOutputCount={ProviderOutputCount} " +
                "ValidationQuestionNumber={ValidationQuestionNumber} " +
                "ValidationDiagnostic={ValidationDiagnostic} DurationMs={DurationMs}",
                generationId,
                stage,
                provider.ProviderName,
                provider.ModelName,
                PromptVersion,
                record.InputHash,
                input.GenerationMode,
                input.AutomaticDensity,
                input.QuestionCount,
                string.Join(',', input.QuestionTypes),
                providerOutputCount,
                (exception as LlmOutputValidationException)?.QuestionNumber,
                (exception as LlmOutputValidationException)?.Diagnostic,
                elapsed.ElapsedMilliseconds);

            try
            {
                await database.SaveChangesAsync(CancellationToken.None);
            }
            catch (Exception persistenceException)
            {
                log.LogError(
                    persistenceException,
                    "Failed to persist LLM generation failure history. " +
                    "GenerationId={GenerationId} OriginalFailureType={OriginalFailureType}",
                    generationId,
                    exception.GetType().FullName);
            }
            throw;
        }
    }

    private static string? LimitLogValue(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var trimmed = value.Trim();
        return trimmed.Length <= 64 ? trimmed : trimmed[..64];
    }

    private static string SummarizeQuestionTypes(IReadOnlyList<string>? types)
    {
        if (types is null || types.Count == 0) return "(none)";
        return string.Join(',', types.Take(10).Select(LimitLogValue));
    }

    private static QuestionGenerationInput ValidateAndNormalize(
        GenerateQuestionsRequest request,
        int maximumQuestionsPerRequest)
    {
        var sourceText = request.SourceText?.Trim() ?? string.Empty;
        var hasConcepts = request.Concepts is { Count: > 0 };
        if (!hasConcepts && sourceText.Length < 10)
        {
            throw new QuestionGenerationRequestException(
                "문제를 생성할 학습 내용을 10자 이상 입력해 주세요.");
        }
        if (!hasConcepts && sourceText.Length > MaximumSourceLength)
        {
            throw new QuestionGenerationRequestException(
                $"학습 내용은 최대 {MaximumSourceLength:N0}자까지 입력할 수 있습니다.");
        }
        if (request.MinimumDifficulty is < 1 or > 5 ||
            request.MaximumDifficulty is < 1 or > 5 ||
            request.MinimumDifficulty > request.MaximumDifficulty)
        {
            throw new QuestionGenerationRequestException(
                "목표 난이도는 1에서 5 사이이며 최솟값이 최댓값보다 클 수 없습니다.");
        }
        var generationMode = string.IsNullOrWhiteSpace(request.GenerationMode)
            ? "manual"
            : request.GenerationMode.Trim();
        if (generationMode is not ("automatic" or "manual"))
        {
            throw new QuestionGenerationRequestException(
                "생성 방식은 automatic 또는 manual이어야 합니다.");
        }

        var questionCount = 0;
        string? automaticDensity = null;
        var minimumQuestionsPerConcept = 0;
        var maximumQuestionsPerConcept = 0;
        if (generationMode == "manual")
        {
            if (request.QuestionCount is null or < 1 or > 20)
            {
                throw new QuestionGenerationRequestException(
                    "수동 문제 수는 1개에서 20개 사이여야 합니다.");
            }
            questionCount = request.QuestionCount.Value;
            if (!hasConcepts && questionCount > maximumQuestionsPerRequest)
                throw new QuestionGenerationRequestException(
                    $"수동 문제 수가 LLM 설정의 요청 1회당 상한({maximumQuestionsPerRequest}개)을 초과합니다.");
        }
        else
        {
            automaticDensity = request.AutomaticDensity?.Trim();
            (minimumQuestionsPerConcept, maximumQuestionsPerConcept) =
                automaticDensity switch
                {
                    "low" => (1, 2),
                    "medium" => (3, 4),
                    "high" => (5, 6),
                    _ => throw new QuestionGenerationRequestException(
                        "자동 생성량은 low, medium 또는 high여야 합니다.")
                };
        }

        var questionTypes = (request.QuestionTypes ?? [])
            .Select(type => type.Trim())
            .Where(type => type.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        if (questionTypes.Count == 0 ||
            questionTypes.Any(type => !SupportedQuestionTypes.Contains(type)))
        {
            throw new QuestionGenerationRequestException(
                "문제 유형은 multipleChoice, trueFalse, shortAnswer 또는 essay만 사용할 수 있습니다.");
        }

        var sourceLabel = string.IsNullOrWhiteSpace(request.SourceLabel)
            ? null
            : request.SourceLabel.Trim();
        if (sourceLabel?.Length > 200)
        {
            throw new QuestionGenerationRequestException(
                "자료 이름은 최대 200자까지 입력할 수 있습니다.");
        }

        var plans = QuestionConceptAllocator.Allocate(request.Concepts,
            request.ReflectConceptImportance, generationMode == "automatic",
            automaticDensity, questionCount, maximumQuestionsPerRequest, perConceptRequests: true)
            .Select(plan => plan with
            {
                // Targets cover the requested range independently of importance.
                // Actual output ratings are never clamped to these drafting targets.
                TargetDifficulties = Enumerable.Range(0, plan.QuestionCount).Select(index =>
                    (int)Math.Round(plan.QuestionCount == 1
                        ? (request.MinimumDifficulty + request.MaximumDifficulty) / 2.0
                        : request.MinimumDifficulty + index *
                          (request.MaximumDifficulty - request.MinimumDifficulty) / (double)(plan.QuestionCount - 1),
                        MidpointRounding.AwayFromZero)).ToArray()
            }).ToList();
        if (plans.Count > 0)
            sourceText = "";
        if (sourceText.Length > MaximumSourceLength)
            throw new QuestionGenerationRequestException("학습 내용은 최대 50,000자까지 입력할 수 있습니다.");
        return new QuestionGenerationInput(
            sourceText.Replace("\r\n", "\n", StringComparison.Ordinal),
            questionCount,
            questionTypes,
            sourceLabel,
            PromptVersion,
            generationMode,
            automaticDensity,
            minimumQuestionsPerConcept,
            maximumQuestionsPerConcept,
            request.MinimumDifficulty,
            request.MaximumDifficulty,
            maximumQuestionsPerRequest,
            plans,
            request.ReflectConceptImportance);
    }

    private static IReadOnlyList<GeneratedQuestionDraft> ValidateProviderOutput(
        IReadOnlyList<GeneratedQuestionDraft> generated,
        QuestionGenerationInput input)
    {
        if (input.PlannedQuestionCount is int planned && generated.Count != planned)
            throw new LlmOutputValidationException(
                $"LLM이 개념별 배분과 다른 수의 문제를 반환했습니다 (계획 {planned}개, 응답 {generated.Count}개).");
        if (!input.IsAutomatic && generated.Count != input.QuestionCount)
        {
            throw new LlmOutputValidationException(
                "LLM이 요청한 개수와 다른 수의 문제를 반환했습니다.");
        }
        if (input.IsAutomatic &&
            (generated.Count < 1 || generated.Count > input.MaximumOutputQuestions))
        {
            throw new LlmOutputValidationException(
                $"LLM이 자동 생성에서 허용되지 않는 수의 문제를 반환했습니다 (상한 {input.MaximumOutputQuestions}개).");
        }

        var validated = new List<GeneratedQuestionDraft>(generated.Count);
        for (var questionIndex = 0; questionIndex < generated.Count; questionIndex++)
        {
            var questionNumber = questionIndex + 1;
            var question = generated[questionIndex];
            if (question is null || question.Type is null || question.Prompt is null ||
                question.Choices is null || question.AcceptableAnswers is null || question.SourceIds is null ||
                question.Choices.Any(choice => choice is null || choice.Text is null) ||
                question.AcceptableAnswers.Any(answer => answer is null))
                throw new LlmOutputValidationException("생성된 문제의 필수 필드가 누락되었습니다.", questionNumber);
            var type = question.Type.Trim();
            var prompt = question.Prompt.Trim();
            var choices = question.Choices
                .Select(choice => new GeneratedQuestionChoice(
                    choice.Text.Trim(),
                    choice.IsCorrect))
                .ToList();
            var answers = question.AcceptableAnswers
                .Select(answer => answer.Trim())
                .Where(answer => answer.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            if (!input.QuestionTypes.Contains(type, StringComparer.Ordinal))
            {
                throw new LlmOutputValidationException(
                    "LLM이 요청하지 않은 문제 유형을 반환했습니다.",
                    questionNumber);
            }
            if (prompt.Length is < 1 or > 2_000)
            {
                throw new LlmOutputValidationException(
                    "생성된 문제의 질문이 비어 있거나 너무 깁니다.",
                    questionNumber);
            }
            if (question.Explanation?.Length > 4_000 ||
                question.Difficulty is null or < 1 or > 5)
            {
                throw new LlmOutputValidationException(
                    "생성된 문제의 설명 또는 난이도가 올바르지 않습니다.",
                    questionNumber);
            }

            var sourceIds = question.SourceIds
                .Where(id => !string.IsNullOrWhiteSpace(id))
                .Select(id => id.Trim())
                .Distinct(StringComparer.Ordinal)
                .ToList();
            if (sourceIds.Count == 0)
            {
                throw new LlmOutputValidationException(
                    "생성된 문제에 학습자료 참조가 없습니다.",
                    questionNumber);
            }

            var primaryConceptId = question.PrimaryConceptId?.Trim();
            if (input.ConceptPlans is { Count: > 0 } plans &&
                !plans.Any(plan => plan.QuestionCount > 0 && plan.Concept.Id == primaryConceptId))
                throw new LlmOutputValidationException(
                    "생성된 문제의 주개념 ID가 입력 개념 또는 생성 배분에 없습니다.", questionNumber);

            if (type == "multipleChoice")
            {
                choices = NormalizeMultipleChoiceChoices(
                    choices,
                    answers,
                    questionNumber);
                answers = [];
            }
            else if (type == "trueFalse")
            {
                choices = NormalizeTrueFalseChoices(
                    choices,
                    answers,
                    questionNumber);
                answers = [];
            }
            else if (choices.Count != 0 || answers.Count is < 1 or > 10)
            {
                throw new LlmOutputValidationException(
                    type == "essay" ? "서술형 문제의 모범 답안이 올바르지 않습니다." : "단답형 문제의 허용 답안이 올바르지 않습니다.",
                    questionNumber,
                    $"ChoiceCount={choices.Count}; AcceptableAnswerCount={answers.Count}");
            }
            if (type == "shortAnswer" && answers.Any(IsBinaryAnswer))
                throw new LlmOutputValidationException(
                    "단답형 문제에는 예/아니오 형태의 답안을 사용할 수 없습니다.", questionNumber);

            validated.Add(question with
            {
                Type = type,
                Prompt = prompt,
                Choices = choices,
                AcceptableAnswers = answers,
                Explanation = string.IsNullOrWhiteSpace(question.Explanation)
                    ? null
                    : question.Explanation.Trim(),
                SourceIds = sourceIds,
                PrimaryConceptId = input.ConceptPlans is { Count: > 0 } ? primaryConceptId : null
            });
        }

        if (input.ConceptPlans is { Count: > 0 } conceptPlans)
            foreach (var plan in conceptPlans)
                if (validated.Count(q => q.PrimaryConceptId == plan.Concept.Id) != plan.QuestionCount)
                    throw new LlmOutputValidationException(
                        "LLM이 서버에서 지정한 개념별 문제 수 배분을 지키지 않았습니다.",
                        diagnostic: $"ExpectedCount={plan.QuestionCount}; ActualCount={validated.Count(q => q.PrimaryConceptId == plan.Concept.Id)}");
        return validated;
    }

    private static bool IsBinaryAnswer(string answer) => answer.Trim().ToLowerInvariant()
        .TrimEnd('.', '!', '?', '。') is "예" or "네" or "아니오" or "아니요" or "yes" or "no" or "true" or "false";

    private static List<GeneratedQuestionChoice> NormalizeMultipleChoiceChoices(
        IReadOnlyList<GeneratedQuestionChoice> choices,
        IReadOnlyList<string> answers,
        int questionNumber)
    {
        var emptyChoiceCount = choices.Count(choice => choice.Text.Length == 0);
        var uniqueChoiceCount = choices
            .Select(choice => choice.Text)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        var correctFlagCount = choices.Count(choice => choice.IsCorrect);
        var diagnostic =
            $"ChoiceCount={choices.Count}; EmptyChoiceCount={emptyChoiceCount}; " +
            $"UniqueChoiceCount={uniqueChoiceCount}; CorrectFlagCount={correctFlagCount}; " +
            $"AcceptableAnswerCount={answers.Count}";

        if (choices.Count is < 2 or > 6 ||
            emptyChoiceCount != 0 ||
            uniqueChoiceCount != choices.Count)
        {
            throw new LlmOutputValidationException(
                "객관식 문제의 선택지 또는 정답이 올바르지 않습니다.",
                questionNumber,
                diagnostic);
        }

        // Some local models redundantly fill acceptableAnswers even though the
        // correct choice is already represented by isCorrect. That field can be
        // discarded without changing the meaning of the question.
        if (correctFlagCount == 1)
        {
            return choices.ToList();
        }

        // A common schema variation is to leave every isCorrect flag false and
        // put the exact correct choice text in acceptableAnswers. Recover only
        // when that text identifies one choice unambiguously.
        if (correctFlagCount == 0 && answers.Count == 1)
        {
            var matchingIndexes = choices
                .Select((choice, index) => new { choice.Text, Index = index })
                .Where(item => string.Equals(
                    item.Text,
                    answers[0],
                    StringComparison.OrdinalIgnoreCase))
                .Select(item => item.Index)
                .ToList();
            if (matchingIndexes.Count == 1)
            {
                var correctIndex = matchingIndexes[0];
                return choices
                    .Select((choice, index) => choice with
                    {
                        IsCorrect = index == correctIndex
                    })
                    .ToList();
            }
        }

        throw new LlmOutputValidationException(
            "객관식 문제의 선택지 또는 정답이 올바르지 않습니다.",
            questionNumber,
            diagnostic);
    }

    private static List<GeneratedQuestionChoice> NormalizeTrueFalseChoices(
        IReadOnlyList<GeneratedQuestionChoice> choices,
        IReadOnlyList<string> answers,
        int questionNumber)
    {
        string? correctLabel = null;
        if (choices.Count == 2)
        {
            var normalized = choices
                .Select(choice => new
                {
                    Label = NormalizeTrueFalseLabel(choice.Text),
                    choice.IsCorrect
                })
                .ToList();
            if (normalized.All(choice => choice.Label is not null) &&
                normalized.Select(choice => choice.Label)
                    .Distinct(StringComparer.Ordinal).Count() == 2)
            {
                var markedCorrect = normalized
                    .Where(choice => choice.IsCorrect)
                    .ToList();
                if (markedCorrect.Count == 1)
                {
                    correctLabel = markedCorrect[0].Label;
                }
            }
        }

        if (correctLabel is null && (choices.Count == 0 || choices.Count == 2))
        {
            var answerLabels = answers
                .Select(NormalizeTrueFalseLabel)
                .Where(label => label is not null)
                .Distinct(StringComparer.Ordinal)
                .ToList();
            if (answerLabels.Count == 1)
            {
                correctLabel = answerLabels[0];
            }
        }

        if (correctLabel is null)
        {
            throw new LlmOutputValidationException(
                "O/X 문제의 선택지 또는 정답이 올바르지 않습니다.",
                questionNumber,
                $"ChoiceCount={choices.Count}; " +
                $"CorrectFlagCount={choices.Count(choice => choice.IsCorrect)}; " +
                $"AcceptableAnswerCount={answers.Count}");
        }

        return
        [
            new GeneratedQuestionChoice("O", correctLabel == "O"),
            new GeneratedQuestionChoice("X", correctLabel == "X")
        ];
    }

    private static string? NormalizeTrueFalseLabel(string value)
    {
        var trimmed = value.Trim();
        if (trimmed is "○" or "⭕" or "◯") return "O";
        if (trimmed is "×" or "✕" or "❌") return "X";

        var compact = string.Concat(trimmed.Where(char.IsLetterOrDigit))
            .ToUpperInvariant();
        var direct = compact switch
        {
            "O" or "TRUE" or "T" or "YES" or "CORRECT" or
            "참" or "참입니다" or "맞음" or "맞다" or "옳음" or "옳다" => "O",
            "X" or "FALSE" or "F" or "NO" or "INCORRECT" or
            "거짓" or "거짓입니다" or "틀림" or "틀리다" or
            "옳지않음" or "아님" or "아니다" => "X",
            _ => null
        };
        if (direct is not null) return direct;

        var tokenLabels = trimmed.ToUpperInvariant()
            .Split(
                [' ', '\t', '(', ')', '[', ']', '{', '}', ':', '-', '/', '.', ','],
                StringSplitOptions.RemoveEmptyEntries |
                StringSplitOptions.TrimEntries)
            .Select(token => token switch
            {
                "O" or "TRUE" or "T" or "YES" or "CORRECT" or
                "참" or "맞음" or "맞다" or "옳음" or "옳다" => "O",
                "X" or "FALSE" or "F" or "NO" or "INCORRECT" or
                "거짓" or "틀림" or "틀리다" or "옳지않음" or
                "아님" or "아니다" => "X",
                _ => null
            })
            .Where(label => label is not null)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        return tokenLabels.Count == 1 ? tokenLabels[0] : null;
    }

    private static string ComputeHash(string sourceText)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(sourceText));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string SafeError(Exception exception)
    {
        var message = exception switch
        {
            LlmProviderUnavailableException => exception.Message,
            LlmProviderRequestException => exception.Message,
            LlmOutputValidationException => exception.Message,
            _ => "LLM 문제 생성 요청에 실패했습니다."
        };
        return message.Length <= 1_000 ? message : message[..1_000];
    }
}

public sealed class QuestionGenerationRequestException(string message)
    : Exception(message);

public sealed class LlmOutputValidationException(
    string message,
    int? questionNumber = null,
    string? diagnostic = null) : Exception(message)
{
    public int? QuestionNumber { get; } = questionNumber;

    public string? Diagnostic { get; } = diagnostic;
}
