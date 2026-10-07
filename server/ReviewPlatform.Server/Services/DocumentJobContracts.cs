using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.AI;

namespace ReviewPlatform.Server.Services;

public sealed class DocumentLimits
{
    public bool SupportsExtractionSelection => true;
    public bool SupportsDirectPdfOnly => true;
    public int MaximumFileSizeMb { get; set; } = 200;
    public int MaximumPages { get; set; } = 1000;
    public int MinimumFreeDiskSpaceMb { get; set; } = 512;
    public int MaximumPendingJobs { get; set; } = 8;
    public long MaximumFileSize => (long)MaximumFileSizeMb * 1024 * 1024;
}

// Checkpoints contain text/results, never images, credentials or prompts.
public sealed class DocumentCheckpoint
{
    public List<List<GeneratedConceptDraft>> Chunks { get; set; } = [];
    public int TotalPages { get; set; }
    public int TotalChunks { get; set; }
    public string Stage { get; set; } = "queued";
    public string ExtractionMode { get; set; } = PdfExtractionModes.Unselected;
    public string DirectPromptVersion { get; set; } = DirectPdfConceptPrompt.Version;
    public List<int> SplitAfterPages { get; set; } = [];
    public int ExtractionRevision { get; set; }
    public PdfExtractionPreflight? Preflight { get; set; }
}

public sealed record DocumentJobResponse(
    string Id, string FileName, string Status, string Stage,
    int CompletedPages, int TotalPages, int CompletedChunks, int TotalChunks,
    string? Error, DateTimeOffset UpdatedAt,
    string ConceptModel,
    string ExtractionMode = PdfExtractionModes.Unselected);
