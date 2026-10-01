namespace ReviewPlatform.Server.Contracts;

public static class DocumentExtractionMethods
{
    public const string TextLayer = "textLayer";
    public const string VisionOcr = "visionOcr";
    public const string Hybrid = "hybrid";
}

public sealed record ExtractedDocumentPage(
    int PageNumber,
    string Text,
    string ExtractionMethod = DocumentExtractionMethods.TextLayer,
    bool RequiresVision = false);

public sealed record DocumentPageExtractionMetadata(
    int PageNumber,
    string ExtractionMethod,
    string ContentHash);

public sealed record GeneratedConceptDraft(
    string Title,
    string Content,
    IReadOnlyList<int> PageNumbers,
    string Importance = "medium")
{
    public string Status => "held";
}

public sealed record DocumentSourceMetadata(
    string Id,
    string FileName,
    string ContentHash,
    int PageCount,
    string ExtractionMethod,
    DateTimeOffset ImportedAt);

public sealed record ImportDocumentResponse(
    DocumentSourceMetadata Source,
    IReadOnlyList<GeneratedConceptDraft> Concepts,
    IReadOnlyList<DocumentPageExtractionMetadata> Pages);

public sealed record ConceptExtractionInput(
    string SourceId,
    string FileName,
    IReadOnlyList<ExtractedDocumentPage> Pages,
    string PromptVersion);

public sealed record DocumentVisionInput(
    string FileName,
    int PageNumber,
    string MimeType,
    byte[] ImageBytes,
    string ImageHash,
    string PromptVersion);

public sealed record DocumentVisionResult(string Text);

public sealed record ConceptRevisionContext(
    string Id,
    string Title,
    string Content,
    IReadOnlyList<int> PageNumbers,
    string Status,
    string Importance = "medium");

public sealed record ReviseConceptsRequest(
    string SourceId,
    string FileName,
    int PageCount,
    string Instruction,
    IReadOnlyList<string> TargetConceptIds,
    IReadOnlyList<ConceptRevisionContext> Concepts);

public sealed record ConceptRevisionInput(
    string SourceId,
    string FileName,
    int PageCount,
    string Instruction,
    IReadOnlyList<ConceptRevisionContext> Concepts,
    IReadOnlyList<string> EditableConceptIds,
    string PromptVersion);

public sealed record GeneratedConceptRevision(
    string Id,
    string Title,
    string Content,
    IReadOnlyList<int> PageNumbers,
    string Importance = "medium");

public sealed record ReviseConceptsResponse(
    IReadOnlyList<GeneratedConceptRevision> Revisions);
