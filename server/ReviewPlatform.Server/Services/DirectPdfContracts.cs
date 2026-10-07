namespace ReviewPlatform.Server.Services;
public static class PdfExtractionModes
{
    public const string Unselected = "unselected";
    public const string Direct = "direct";
}
public sealed class DirectPdfLimits
{
    public int MaximumOutputTokens { get; set; } = 64_000;
    public int TokensPerMinute { get; set; } = 500_000;
    public int InputSafetyLimit { get; set; } = 900_000;
    public int ContextMarginTokens { get; set; } = 10_000;
    public int EstimatedOutputTokensPerPage { get; set; } = 1_050;
}
public sealed record PdfPageRange(int FirstPage, int LastPage)
{
    public int PageCount => LastPage - FirstPage + 1;
}
public sealed record PdfExtractionSelection(string Mode, IReadOnlyList<int>? SplitAfterPages = null,
    bool AcknowledgeWarnings = false, int Revision = 0);
public sealed record PdfPreflightPart(PdfPageRange Range, long FileSize, long? InputTokens,
    int OutputBudget, long EstimatedOutputTokens, string Status, IReadOnlyList<string> Messages);
public sealed record PdfExtractionPreflight(string Model, string Provider, int Revision,
    string Status, IReadOnlyList<PdfPreflightPart> Parts, string? Error = null);
public sealed record PdfExtractionOverview(string Id, string FileName, long FileSize, int PageCount,
    string ContentHash, string Mode, int Revision, string ConceptModel, string ConceptProvider,
    int MaximumOutputTokens, int TokensPerMinute, IReadOnlyList<int> SplitAfterPages, PdfExtractionPreflight? Preflight);
public sealed class PdfSelectionRequiredException(string message) : Exception(message);
