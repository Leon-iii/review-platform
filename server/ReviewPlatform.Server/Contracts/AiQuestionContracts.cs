namespace ReviewPlatform.Server.Contracts;

public sealed record GenerateQuestionsRequest(
    string? SourceText,
    int? QuestionCount,
    IReadOnlyList<string>? QuestionTypes,
    string? SourceLabel,
    string? GenerationMode = null,
    string? AutomaticDensity = null);

public sealed record GeneratedQuestionChoice(string Text, bool IsCorrect);

public sealed record GeneratedQuestionDraft(
    string Type,
    string Prompt,
    IReadOnlyList<GeneratedQuestionChoice> Choices,
    IReadOnlyList<string> AcceptableAnswers,
    string? Explanation,
    int? Difficulty,
    IReadOnlyList<string> SourceIds)
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
    IReadOnlyList<GeneratedQuestionDraft> Questions);
