using System.Text.RegularExpressions;
using ReviewPlatform.Server.Contracts;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace ReviewPlatform.Server.Services;

public interface IPdfTextExtractor
{
    PdfTextExtractionResult Extract(string path);
    PdfTextExtractionResult Extract(string path, CancellationToken cancellationToken,
        int maximumPages, int maximumCharacters)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Extract(path);
    }
}

public sealed record PdfTextExtractionResult(
    int PageCount,
    IReadOnlyList<ExtractedDocumentPage> Pages);

public sealed partial class PdfPigTextExtractor : IPdfTextExtractor
{
    public PdfTextExtractionResult Extract(string path) =>
        Extract(path, CancellationToken.None, int.MaxValue, int.MaxValue);

    public PdfTextExtractionResult Extract(string path, CancellationToken cancellationToken,
        int maximumPages, int maximumCharacters)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var document = PdfDocument.Open(path);
            if (document.NumberOfPages > maximumPages)
                throw new DocumentImportException($"PDF는 최대 {maximumPages}페이지까지 가져올 수 있습니다.");
            var pages = new List<ExtractedDocumentPage>(document.NumberOfPages);
            long characters = 0;
            foreach (var page in document.GetPages())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var text = Normalize(ContentOrderTextExtractor.GetText(page));
                characters += text.Length;
                if (characters > maximumCharacters)
                    throw new DocumentImportException("추출된 텍스트가 서버의 안전 제한을 초과했습니다. PDF를 나누어 가져와 주세요.");
                pages.Add(new ExtractedDocumentPage(
                    page.Number,
                    text,
                    RequiresVision: RequiresVisualAnalysis(page, text)));
            }
            return new PdfTextExtractionResult(document.NumberOfPages, pages);
        }
        catch (OperationCanceledException) { throw; }
        catch (DocumentImportException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new DocumentImportException(
                "PDF 파일을 읽지 못했습니다. 손상되었거나 암호화된 파일인지 확인해 주세요.",
                exception);
        }
    }

    private static string Normalize(string value)
    {
        var normalized = value.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        normalized = HorizontalWhitespace().Replace(normalized, " ");
        normalized = ExcessiveBlankLines().Replace(normalized, "\n\n");
        return normalized.Trim();
    }

    private static bool RequiresVisualAnalysis(
        UglyToad.PdfPig.Content.Page page,
        string text)
    {
        try
        {
            var pageArea = Math.Max(1, page.Width * page.Height);
            var hasLargeImage = page.GetImages().Any(image =>
                image.Bounds.Width * image.Bounds.Height >= pageArea * 0.2);
            var hasStructuredGraphics = page.Paths.Count >= 20 &&
                text.Count(character => !char.IsWhiteSpace(character)) < 5_000;
            return hasLargeImage || hasStructuredGraphics || HasTextCallout(page, pageArea);
        }
        catch
        {
            // Text extraction remains usable even when optional image metadata
            // cannot be decoded for a particular PDF object.
            return false;
        }
    }

    private static bool HasTextCallout(UglyToad.PdfPig.Content.Page page, double pageArea)
    {
        // A single rectangle/rounded callout can contain independent study content.
        // Path count alone misses it. Ignore decorative/empty boxes and page frames;
        // this is a layout-analysis trigger, never an instruction to split a concept.
        var letters = page.Letters.Where(letter => !string.IsNullOrWhiteSpace(letter.Value)).ToArray();
        foreach (var region in page.Paths
            .Where(path => path.IsStroked || path.IsFilled)
            .SelectMany(path => path)
            .Where(subpath => subpath.IsClosed())
            .Take(256))
        {
            if (region.GetBoundingRectangle() is not { } bounds ||
                bounds.Width < 60 || bounds.Height < 24 ||
                bounds.Width * bounds.Height > pageArea * 0.8)
                continue;

            var inside = 0;
            var outside = 0;
            foreach (var letter in letters)
            {
                var point = letter.GlyphRectangle.Centroid;
                if (point.X >= bounds.Left && point.X <= bounds.Right &&
                    point.Y >= bounds.Bottom && point.Y <= bounds.Top)
                    inside++;
                else
                    outside++;
                if (inside >= 12 && outside >= 12) return true;
            }
        }
        return false;
    }

    [GeneratedRegex(@"[\t\f\v ]+")]
    private static partial Regex HorizontalWhitespace();

    [GeneratedRegex(@"\n{3,}")]
    private static partial Regex ExcessiveBlankLines();
}

public sealed class DocumentImportException(
    string message,
    Exception? innerException = null) : Exception(message, innerException);
