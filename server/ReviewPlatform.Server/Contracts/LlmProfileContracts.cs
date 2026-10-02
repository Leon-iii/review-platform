namespace ReviewPlatform.Server.Contracts;

public static class LlmPurposes
{
    public const string QuestionGeneration = "questionGeneration";
    public const string ConceptExtraction = "conceptExtraction";
    public const string ConceptRevision = "conceptRevision";
    public const string DocumentVision = "documentVision";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(
        [QuestionGeneration, ConceptExtraction, ConceptRevision, DocumentVision],
        StringComparer.Ordinal);
}

public static class LlmApiKeyProviders
{
    public const string OpenAi = "openai";
    public const string Gemini = "gemini";
    public const string Claude = "claude";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(
        [OpenAi, Gemini, Claude],
        StringComparer.Ordinal);
}

public sealed record LlmProfileDto(
    string Id,
    string Name,
    string Provider,
    string Model,
    DateTimeOffset UpdatedAt,
    int? ContextWindowTokens = null,
    string? ReasoningEffort = null,
    int MaximumQuestionsPerRequest = 120);

public sealed record LlmProfileInput(
    string Id,
    string Name,
    string Provider,
    string Model,
    int? ContextWindowTokens = null,
    string? ReasoningEffort = null,
    int MaximumQuestionsPerRequest = 120);

public sealed record LlmProfileSettingsResponse(
    IReadOnlyList<LlmProfileDto> Profiles,
    IReadOnlyDictionary<string, string> Assignments,
    IReadOnlyDictionary<string, bool> ApiKeyConfigured);

public sealed record UpdateLlmProfileSettingsRequest(
    IReadOnlyList<LlmProfileInput>? Profiles,
    IReadOnlyDictionary<string, string>? Assignments,
    IReadOnlyDictionary<string, string?>? ApiKeys = null);

public sealed record LlmModelCatalogResponse(
    string Provider,
    IReadOnlyList<string> Models,
    DateTimeOffset RefreshedAt,
    IReadOnlyDictionary<string, int>? ContextWindows = null,
    IReadOnlyDictionary<string, OpenAiModelCapabilities>? ModelCapabilities = null,
    IReadOnlyDictionary<string, LlmModelMetadata>? ModelMetadata = null);

// Provider-neutral presentation metadata. Unknown models must remain visible.
public sealed record LlmModelMetadata(string Lifecycle = "unknown", bool IsSnapshot = false);

public sealed record OpenAiModelCapabilities(
    bool IsKnown,
    IReadOnlyList<string> ReasoningEfforts,
    string? DefaultReasoningEffort,
    int? MaxOutputTokens,
    bool SupportsStructuredOutputs = true,
    bool SupportsReasoning = false);
