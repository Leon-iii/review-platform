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
    string Summary,
    string Details,
    IReadOnlyList<int> PageNumbers)
{
    public string Status => "draft";
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
