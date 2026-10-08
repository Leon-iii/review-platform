namespace ReviewPlatform.Server.Services;
public static class PdfExtractionModes
{
    public const string Unselected = "unselected";
    public const string Direct = "direct";
}
public sealed class DirectPdfLimits
{
    public int OutputSafetyThresholdTokens { get; set; } = 64_000;
    public int TokensPerMinute { get; set; } = 500_000;
    public int InputSafetyLimit { get; set; } = 900_000;
    public int ContextMarginTokens { get; set; } = 10_000;
}
public static class DirectPdfBudgetPolicy
{
    public const string Version = "direct-pdf-budget-v2";
}
public sealed record PdfPageRange(int FirstPage, int LastPage)
{
    public int PageCount => LastPage - FirstPage + 1;
}
public sealed record PdfExtractionSelection(string Mode, IReadOnlyList<int>? SplitAfterPages = null,
    bool AcknowledgeWarnings = false, int Revision = 0);
public sealed record PdfPreflightPart(PdfPageRange Range, long FileSize, long? InputTokens,
    int? OutputBudget, long? EstimatedOutputTokens, string Status, IReadOnlyList<string> Messages,
    int OutputSafetyThresholdTokens = 64_000, PdfOutputEstimate? OutputEstimate = null);
public sealed record PdfExtractionPreflight(string Model, string Provider, int Revision,
    string Status, IReadOnlyList<PdfPreflightPart> Parts, string? Error = null,
    string BudgetPolicyVersion = "legacy");
public sealed record PdfExtractionOverview(string Id, string FileName, long FileSize, int PageCount,
    string ContentHash, string Mode, int Revision, string ConceptModel, string ConceptProvider,
    int? MaximumOutputTokens, int TokensPerMinute, IReadOnlyList<int> SplitAfterPages, PdfExtractionPreflight? Preflight,
    int OutputSafetyThresholdTokens = 64_000);
public sealed class PdfSelectionRequiredException(string message) : Exception(message);
