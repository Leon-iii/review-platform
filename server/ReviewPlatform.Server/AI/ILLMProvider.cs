using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public interface ILLMProvider
{
    string ProviderName { get; }

    string ModelName { get; }

    int? ContextWindowTokens => null;

    int MaximumQuestionsPerRequest => 120;

    Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
        QuestionGenerationInput input,
        CancellationToken cancellationToken = default);

    bool SupportsRevisionPdf => false;

    Task<ConceptRevisionResult> ReviseConceptsAsync(
        ConceptRevisionInput input,
        CancellationToken cancellationToken = default)
    {
        throw new LlmProviderUnavailableException(
            "선택한 LLM Provider는 개념 수정을 지원하지 않습니다.");
    }


}

public sealed record QuestionGenerationInput(
    string SourceText,
    int QuestionCount,
    IReadOnlyList<string> QuestionTypes,
    string? SourceLabel,
    string PromptVersion,
    string GenerationMode = "manual",
    string? AutomaticDensity = null,
    int MinimumDifficulty = 1,
    int MaximumDifficulty = 5,
    int MaximumQuestionsPerRequest = 120,
    IReadOnlyList<QuestionConceptPlan>? ConceptPlans = null,
    bool ReflectConceptImportance = false,
    bool BindConceptOnServer = false)
{
    public int? PlannedQuestionCount => !IsAutomatic && ConceptPlans is { Count: > 0 }
        ? ConceptPlans.Sum(plan => plan.QuestionCount) : null;
    public string SourceReference => string.IsNullOrWhiteSpace(SourceLabel)
        ? "provided-source"
        : SourceLabel;

    public bool IsAutomatic => GenerationMode == "automatic";

    public int MinimumOutputQuestions => PlannedQuestionCount ?? (IsAutomatic ? 1 : QuestionCount);

    public int MaximumOutputQuestions => IsAutomatic ? MaximumQuestionsPerRequest
        : PlannedQuestionCount ?? QuestionCount;

    // Coverage count is not known until generation; reserve for the configured cap,
    // rather than cutting a detailed concept off at a small density-based estimate.
    public int QuestionBudgetForTokenLimit => IsAutomatic ? MaximumQuestionsPerRequest
        : PlannedQuestionCount ?? QuestionCount;
}

public sealed record QuestionConceptPlan(QuestionGenerationConcept Concept, int QuestionCount,
    IReadOnlyList<int>? TargetDifficulties = null, int AdditionalPracticeQuestions = 0);

public sealed class LlmProviderUnavailableException(
    string message,
    Exception? inner = null) : Exception(message, inner);

public sealed class LlmProviderRequestException(string message, Exception? inner = null)
    : Exception(message, inner);

public sealed class UnconfiguredLlmProvider : ILLMProvider
{
    public string ProviderName => "unconfigured";

    public string ModelName => "unconfigured";

    public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
        QuestionGenerationInput input,
        CancellationToken cancellationToken = default)
    {
        throw new LlmProviderUnavailableException(
            "LLM Provider가 아직 설정되지 않았습니다.");
    }
}
