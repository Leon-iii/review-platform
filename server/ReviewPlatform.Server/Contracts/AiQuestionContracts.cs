namespace ReviewPlatform.Server.Contracts;

public sealed record GenerateQuestionsRequest(
    string? SourceText,
    int? QuestionCount,
    IReadOnlyList<string>? QuestionTypes,
    string? SourceLabel,
    string? GenerationMode = null,
    string? AutomaticDensity = null,
    int MinimumDifficulty = 1,
    int MaximumDifficulty = 5,
    IReadOnlyList<QuestionGenerationConcept>? Concepts = null,
    bool ReflectConceptImportance = false);

public sealed record QuestionGenerationConcept(
    string Id, string Title, string Content, string Importance = "medium");

public sealed record GeneratedQuestionChoice(string Text, bool IsCorrect);

public sealed record GeneratedQuestionDraft(
    string Type,
    string Prompt,
    IReadOnlyList<GeneratedQuestionChoice> Choices,
    IReadOnlyList<string> AcceptableAnswers,
    string? Explanation,
    int? Difficulty,
    IReadOnlyList<string> SourceIds,
    string? PrimaryConceptId = null,
    IReadOnlyList<int>? CorrectOrder = null)
{
    public string Status => "draft";
}

public sealed record QuestionGenerationMetadata(
    string GenerationId,
    string Provider,
    string Model,
    string PromptVersion,
    DateTimeOffset RequestedAt,
    string InputHash,
    string? SourceLabel);

public sealed record GenerateQuestionsResponse(
    QuestionGenerationMetadata Metadata,
    IReadOnlyList<GeneratedQuestionDraft> Questions,
    IReadOnlyList<QuestionGenerationFailure>? Failures = null,
    IReadOnlyList<string>? Warnings = null);

public sealed record QuestionGenerationFailure(string ConceptId, string Title, string Error);

public sealed record QuestionGenerationProgress(
    int CompletedConcepts, int TotalConcepts, int GeneratedQuestions,
    string? ConceptTitle, int FailedConcepts);
