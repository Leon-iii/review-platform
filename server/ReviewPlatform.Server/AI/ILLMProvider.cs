using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public interface ILLMProvider
{
    string ProviderName { get; }

    string ModelName { get; }

    Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
        QuestionGenerationInput input,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(
        ConceptExtractionInput input,
        CancellationToken cancellationToken = default)
    {
        throw new LlmProviderUnavailableException(
            "선택한 LLM Provider는 개념 추출을 지원하지 않습니다.");
    }

    Task<IReadOnlyList<GeneratedConceptRevision>> ReviseConceptsAsync(
        ConceptRevisionInput input,
        CancellationToken cancellationToken = default)
    {
        throw new LlmProviderUnavailableException(
            "선택한 LLM Provider는 개념 수정을 지원하지 않습니다.");
    }

    Task<DocumentVisionResult> ExtractPageContentAsync(
        DocumentVisionInput input,
        CancellationToken cancellationToken = default)
    {
        throw new LlmProviderUnavailableException(
            "선택한 LLM Provider는 문서 이미지 분석을 지원하지 않습니다.");
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
    int MinimumQuestionsPerConcept = 0,
    int MaximumQuestionsPerConcept = 0)
{
    public const int MaximumAutomaticQuestionCount = 120;

    public string SourceReference => string.IsNullOrWhiteSpace(SourceLabel)
        ? "provided-source"
        : SourceLabel;

    public bool IsAutomatic => GenerationMode == "automatic";

    public int MinimumOutputQuestions => IsAutomatic ? 1 : QuestionCount;

    public int MaximumOutputQuestions => IsAutomatic
        ? MaximumAutomaticQuestionCount
        : QuestionCount;

    public int QuestionBudgetForTokenLimit => IsAutomatic
        ? AutomaticDensity switch
        {
            "low" => 10,
            "medium" => 20,
            "high" => 30,
            _ => 20
        }
        : QuestionCount;
}

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
