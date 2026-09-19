using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;

public sealed class QuestionGenerationService(
    SyncDbContext database,
    ILLMProvider provider,
    ILogger<QuestionGenerationService>? logger = null)
{
    public const string PromptVersion = "question-generation-v5-multiple-choice";
    private const int MaximumSourceLength = 50_000;
    private static readonly HashSet<string> SupportedQuestionTypes =
    [
        "multipleChoice",
        "trueFalse",
        "shortAnswer"
    ];
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web);
    private readonly ILogger<QuestionGenerationService> log =
        logger ?? NullLogger<QuestionGenerationService>.Instance;

    public async Task<GenerateQuestionsResponse> GenerateAsync(
        GenerateQuestionsRequest request,
        CancellationToken cancellationToken = default)
    {
        QuestionGenerationInput input;
        try
        {
            input = ValidateAndNormalize(request);
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
            InputHash = ComputeHash(input.SourceText),
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
            var generated = await provider.GenerateQuestionsAsync(
                input,
                cancellationToken);
            providerOutputCount = generated.Count;
            stage = "output-validation";
            var questions = ValidateProviderOutput(generated, input);
            record.Status = "succeeded";
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
                questions);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
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
        GenerateQuestionsRequest request)
    {
        var sourceText = request.SourceText?.Trim() ?? string.Empty;
        if (sourceText.Length < 10)
        {
            throw new QuestionGenerationRequestException(
                "문제를 생성할 학습 내용을 10자 이상 입력해 주세요.");
        }
        if (sourceText.Length > MaximumSourceLength)
        {
            throw new QuestionGenerationRequestException(
                $"학습 내용은 최대 {MaximumSourceLength:N0}자까지 입력할 수 있습니다.");
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
                "문제 유형은 multipleChoice, trueFalse 또는 shortAnswer만 사용할 수 있습니다.");
        }

        var sourceLabel = string.IsNullOrWhiteSpace(request.SourceLabel)
            ? null
            : request.SourceLabel.Trim();
        if (sourceLabel?.Length > 200)
        {
            throw new QuestionGenerationRequestException(
                "자료 이름은 최대 200자까지 입력할 수 있습니다.");
        }

        return new QuestionGenerationInput(
            sourceText.Replace("\r\n", "\n", StringComparison.Ordinal),
            questionCount,
            questionTypes,
            sourceLabel,
            PromptVersion,
            generationMode,
            automaticDensity,
            minimumQuestionsPerConcept,
            maximumQuestionsPerConcept);
    }

    private static IReadOnlyList<GeneratedQuestionDraft> ValidateProviderOutput(
        IReadOnlyList<GeneratedQuestionDraft> generated,
        QuestionGenerationInput input)
    {
        if (!input.IsAutomatic && generated.Count != input.QuestionCount)
        {
            throw new LlmOutputValidationException(
                "LLM이 요청한 개수와 다른 수의 문제를 반환했습니다.");
        }
        if (input.IsAutomatic &&
            generated.Count is < 1 or > QuestionGenerationInput.MaximumAutomaticQuestionCount)
        {
            throw new LlmOutputValidationException(
                "LLM이 자동 생성에서 허용되지 않는 수의 문제를 반환했습니다.");
        }

        var validated = new List<GeneratedQuestionDraft>(generated.Count);
        for (var questionIndex = 0; questionIndex < generated.Count; questionIndex++)
        {
            var questionNumber = questionIndex + 1;
            var question = generated[questionIndex];
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
                question.Difficulty is < 1 or > 5)
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
                    "단답형 문제의 허용 답안이 올바르지 않습니다.",
                    questionNumber,
                    $"ChoiceCount={choices.Count}; AcceptableAnswerCount={answers.Count}");
            }

            validated.Add(question with
            {
                Type = type,
                Prompt = prompt,
                Choices = choices,
                AcceptableAnswers = answers,
                Explanation = string.IsNullOrWhiteSpace(question.Explanation)
                    ? null
                    : question.Explanation.Trim(),
                SourceIds = sourceIds
            });
        }

        return validated;
    }

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
