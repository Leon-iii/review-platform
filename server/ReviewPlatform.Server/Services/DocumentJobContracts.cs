using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.AI;

namespace ReviewPlatform.Server.Services;

public sealed class DocumentLimits
{
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
}

public sealed record DocumentJobResponse(
    string Id, string FileName, string Status, string Stage,
    int CompletedPages, int TotalPages, int CompletedChunks, int TotalChunks,
    string? Error, DateTimeOffset UpdatedAt,
    string VisionModel, string ConceptModel);
