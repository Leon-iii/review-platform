using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public static class DocumentReviewContent
{
    public static List<DocumentReviewBlock> DefaultBlocks(ExtractedDocumentPage page, bool includeTextLayer = false)
    {
        var text = page.Text;
        const string hybridSeparator = "[페이지 시각 정보]";
        var separator = text.IndexOf(hybridSeparator, StringComparison.Ordinal);
        if (page.Regions is { Count: > 0 })
        {
            var blocks = page.Regions.Select(region => new DocumentReviewBlock(
                region.Text, VisualRegion: region.VisualRegion, Kind: region.Kind)).ToList();
            if (includeTextLayer && page.ExtractionMethod == DocumentExtractionMethods.Hybrid && separator >= 0)
                blocks.Insert(0, new DocumentReviewBlock(text[..separator].Trim(), Kind: DocumentContentKinds.Text));
            return blocks;
        }
        // Keep the full original, but edit only one canonical transcription.
        if (!includeTextLayer && page.ExtractionMethod == DocumentExtractionMethods.Hybrid && separator >= 0 &&
            !string.IsNullOrWhiteSpace(text[(separator + hybridSeparator.Length)..]))
            text = text[(separator + hybridSeparator.Length)..].Trim();
        var result = new List<DocumentReviewBlock>();
        var remaining = text;
        const string start = "[VISUAL_REGION_START]";
        const string end = "[VISUAL_REGION_END]";
        while (true)
        {
            var first = remaining.IndexOf(start, StringComparison.Ordinal);
            var last = first < 0 ? -1 : remaining.IndexOf(end, first + start.Length, StringComparison.Ordinal);
            // Malformed markers never silently discard source text.
            if (first < 0 || last < 0) { Add(remaining, false); break; }
            Add(remaining[..first], false);
            Add(remaining[(first + start.Length)..last], true);
            remaining = remaining[(last + end.Length)..];
        }
        if (result.Count == 0) result.Add(new DocumentReviewBlock("", Kind: DocumentContentKinds.Text));
        return result;

        void Add(string value, bool visual)
        {
            if (!string.IsNullOrWhiteSpace(value)) result.Add(new DocumentReviewBlock(value.Trim(), VisualRegion: visual,
                Kind: page.ExtractionMethod == DocumentExtractionMethods.TextLayer ? DocumentContentKinds.Text : DocumentContentKinds.Uncertain));
        }
    }

    public static IReadOnlyList<ExtractedDocumentPage> AnnotatedPages(IReadOnlyList<ExtractedDocumentPage> pages) =>
        pages.Select(page => page.Regions is { Count: > 0 }
            ? page with { Text = BuildText(DefaultBlocks(page, includeTextLayer: true)) } : page).ToList();

    public static IReadOnlyList<ExtractedDocumentPage> ConfirmedPages(DocumentCheckpoint checkpoint) =>
        checkpoint.Pages.Select(page => page with
        {
            Text = BuildText(checkpoint.ReviewPages.GetValueOrDefault(page.PageNumber) ?? DefaultBlocks(page))
        }).ToList();

    public static long ContentCharacterCount(DocumentCheckpoint checkpoint) => checkpoint.Pages.Sum(page =>
        (checkpoint.ReviewPages.GetValueOrDefault(page.PageNumber) ?? DefaultBlocks(page))
            .Where(block => !block.Excluded)
            .Sum(block => (long)block.Text.Count(character => !char.IsWhiteSpace(character))));

    public static string BuildText(IEnumerable<DocumentReviewBlock> blocks) => string.Join("\n\n",
        blocks.Where(block => !block.Excluded && !string.IsNullOrWhiteSpace(block.Text)).Select(block =>
        {
            var text = block.Text.Trim();
            if (block.Kind != DocumentContentKinds.Text)
                text = $"[CONTENT_KIND:{block.Kind}]\n{text}\n[/CONTENT_KIND]";
            return block.Independent
                ? $"[USER_INDEPENDENT_REGION_START]\n{text}\n[USER_INDEPENDENT_REGION_END]"
                : block.VisualRegion ? $"[VISUAL_REGION_START]\n{text}\n[VISUAL_REGION_END]" : text;
        }));
}
