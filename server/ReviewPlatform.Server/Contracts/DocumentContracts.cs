namespace ReviewPlatform.Server.Contracts;

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
    bool AllowDeletions = false,
    IReadOnlyList<ConceptRevisionClarification>? Clarifications = null,
    string? ContentHash = null);

public sealed record ConceptRevisionClarification(string Question, string Answer);
public sealed record ConceptRevisionSource(byte[] PdfBytes, IReadOnlyList<int> OriginalPages);
public sealed record ConceptRevisionResult(
    string Status, string Comment, string ClarificationQuestion,
    IReadOnlyList<GeneratedConceptRevision> Changes);

public sealed record ConceptRevisionInput(
    string SourceId,
    string FileName,
    int PageCount,
    string Instruction,
    IReadOnlyList<ConceptRevisionContext> Concepts,
    IReadOnlyList<string> EditableConceptIds,
    string PromptVersion,
    bool AllowAdditions = false,
    bool AllowDeletions = false,
    IReadOnlyList<ConceptRevisionClarification>? Clarifications = null,
    ConceptRevisionSource? Source = null);

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
    IReadOnlyList<GeneratedConceptDeletion> Deletions,
    string Status,
    string Comment,
    string ClarificationQuestion);

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
    IReadOnlyList<GeneratedConceptDeletion>? Deletions = null,
    string? Status = null,
    string? Comment = null,
    string? ClarificationQuestion = null)
{
    public ConceptRevisionResult ToResult()
    {
        if (Revisions is null || Additions is null || Deletions is null ||
            Status is null || Comment is null || ClarificationQuestion is null)
            throw new System.Text.Json.JsonException("Missing concept revision response fields.");
        return new(Status, Comment, ClarificationQuestion, Flatten());
    }
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
