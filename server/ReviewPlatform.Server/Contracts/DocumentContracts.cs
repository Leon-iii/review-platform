namespace ReviewPlatform.Server.Contracts;

public static class DocumentExtractionMethods
{
    public const string TextLayer = "textLayer";
    public const string VisionOcr = "visionOcr";
    public const string Hybrid = "hybrid";
}

public static class DocumentContentKinds
{
    public const string Text = "text";
    public const string Diagram = "diagram";
    public const string Table = "table";
    public const string Uncertain = "uncertain";
    public static bool IsValid(string? kind) => kind is Text or Diagram or Table or Uncertain;
}

public sealed record DocumentVisionRegion(string Kind, string Text, bool VisualRegion = false);

public sealed record ExtractedDocumentPage(
    int PageNumber,
    string Text,
    string ExtractionMethod = DocumentExtractionMethods.TextLayer,
    bool RequiresVision = false,
    IReadOnlyList<DocumentVisionRegion>? Regions = null);

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

public sealed record DocumentVisionResult(string Text, IReadOnlyList<DocumentVisionRegion>? Regions = null);

public sealed record ConceptRevisionContext(
    string Id,
    string Title,
    string Content,
    IReadOnlyList<int> PageNumbers,
    string Status,
    string Importance = "medium");

// PageCount=0 and empty PageNumbers represent user-authored material/concepts.
// PDF materials can also contain user-authored concepts with empty PageNumbers.
public sealed record ReviseConceptsRequest(
    string SourceId,
    string FileName,
    int PageCount,
    string Instruction,
    IReadOnlyList<string> TargetConceptIds,
    IReadOnlyList<ConceptRevisionContext> Concepts,
    bool AllowAdditions = false,
    bool AllowDeletions = false);

public sealed record ConceptRevisionInput(
    string SourceId,
    string FileName,
    int PageCount,
    string Instruction,
    IReadOnlyList<ConceptRevisionContext> Concepts,
    IReadOnlyList<string> EditableConceptIds,
    string PromptVersion,
    bool AllowAdditions = false,
    bool AllowDeletions = false);

public sealed record GeneratedConceptRevision(
    string Id,
    string Title,
    string Content,
    IReadOnlyList<int> PageNumbers,
    string Importance = "medium",
    string GroupId = "",
    string Kind = "update",
    string Reason = "");

public sealed record ReviseConceptsResponse(
    IReadOnlyList<GeneratedConceptRevision> Revisions,
    IReadOnlyList<GeneratedConceptAddition> Additions,
    IReadOnlyList<GeneratedConceptDeletion> Deletions);

public sealed record GeneratedConceptAddition(
    string Title,
    string Content,
    IReadOnlyList<int> PageNumbers,
    string Importance = "medium",
    string GroupId = "",
    string Reason = "");

public sealed record GeneratedConceptDeletion(string Id, string Reason, string GroupId = "");

// Provider adapters flatten the three wire arrays into the existing revision interface.
// New concept IDs are assigned by the client only when the confirmed proposal is saved.
public sealed record ConceptChangeEnvelope(
    IReadOnlyList<GeneratedConceptRevision>? Revisions,
    IReadOnlyList<GeneratedConceptAddition>? Additions = null,
    IReadOnlyList<GeneratedConceptDeletion>? Deletions = null)
{
    public IReadOnlyList<GeneratedConceptRevision> Flatten()
    {
        if (Revisions is null) throw new System.Text.Json.JsonException("Missing revisions array.");
        return [
            .. Revisions.Select(item => item with { Kind = "update" }),
            .. (Additions ?? []).Select(item => new GeneratedConceptRevision(
                "", item.Title, item.Content, item.PageNumbers, item.Importance,
                item.GroupId, "add", item.Reason)),
            .. (Deletions ?? []).Select(item => new GeneratedConceptRevision(
                item.Id, "", "", [], "medium", item.GroupId, "delete", item.Reason))
        ];
    }
}
