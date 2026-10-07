using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.AI;

namespace ReviewPlatform.Server.Services;

public sealed class DocumentLimits
{
    public bool SupportsExtractionSelection => true;
    public int MaximumFileSizeMb { get; set; } = 200;
    public int MaximumPages { get; set; } = 1000;
    public int MaximumExtractedCharacters { get; set; } = 3_000_000;
    public int MinimumFreeDiskSpaceMb { get; set; } = 512;
    public int MaximumPendingJobs { get; set; } = 8;
    public long MaximumFileSize => (long)MaximumFileSizeMb * 1024 * 1024;
}

// Checkpoints contain text/results, never images, credentials or prompts.
public sealed class DocumentCheckpoint
{
    public string ConceptPromptVersion { get; set; } = ConceptExtractionPrompt.Version;
    public string VisionPromptVersion { get; set; } = DocumentVisionPrompt.Version;
    public List<ExtractedDocumentPage> Pages { get; set; } = [];
    public List<DocumentPageExtractionMetadata> Metadata { get; set; } = [];
    public List<List<GeneratedConceptDraft>> Chunks { get; set; } = [];
    public int TotalPages { get; set; }
    public int TotalChunks { get; set; }
    public string Stage { get; set; } = "queued";
    public bool ReviewBeforeConcepts { get; set; }
    public bool ReviewConfirmed { get; set; }
    public int ReviewRevision { get; set; }
    public Dictionary<int, List<DocumentReviewBlock>> ReviewPages { get; set; } = [];
    public string ExtractionMode { get; set; } = PdfExtractionModes.Ocr;
    public string DirectPromptVersion { get; set; } = DirectPdfConceptPrompt.Version;
    public List<int> SplitAfterPages { get; set; } = [];
    public int ExtractionRevision { get; set; }
    public PdfExtractionPreflight? Preflight { get; set; }
}

public sealed record DocumentReviewBlock(string Text, bool Independent = false,
    bool Excluded = false, bool VisualRegion = false, string Kind = DocumentContentKinds.Uncertain);
public sealed record DocumentReviewPage(int PageNumber, int TotalPages, string OriginalText,
    IReadOnlyList<DocumentReviewBlock> Blocks, int Revision, bool Edited,
    IReadOnlyList<DocumentReviewBlock>? OriginalBlocks = null, bool ReadOnly = false);
public sealed record SaveDocumentReviewRequest(int Revision, IReadOnlyList<DocumentReviewBlock>? Blocks);
public sealed record ConfirmDocumentReviewRequest(int Revision);
public sealed class DocumentReviewRequiredException : Exception;

public sealed record DocumentJobResponse(
    string Id, string FileName, string Status, string Stage,
    int CompletedPages, int TotalPages, int CompletedChunks, int TotalChunks,
    string? Error, DateTimeOffset UpdatedAt,
    string VisionModel, string ConceptModel,
    bool ReviewBeforeConcepts = false, bool ReviewConfirmed = false,
    string ExtractionMode = PdfExtractionModes.Ocr);
