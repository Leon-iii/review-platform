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

public sealed record LlmProfileDto(
    string Id,
    string Name,
    string Provider,
    string Model,
    DateTimeOffset UpdatedAt);

public sealed record LlmProfileInput(
    string Id,
    string Name,
    string Provider,
    string Model);

public sealed record LlmProfileSettingsResponse(
    IReadOnlyList<LlmProfileDto> Profiles,
    IReadOnlyDictionary<string, string> Assignments);

public sealed record UpdateLlmProfileSettingsRequest(
    IReadOnlyList<LlmProfileInput>? Profiles,
    IReadOnlyDictionary<string, string>? Assignments);

public sealed record LlmModelCatalogResponse(
    string Provider,
    IReadOnlyList<string> Models,
    DateTimeOffset RefreshedAt);
