using System.Text.RegularExpressions;
using ReviewPlatform.Server.Contracts;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace ReviewPlatform.Server.Services;

public interface IPdfTextExtractor
{
    PdfTextExtractionResult Extract(string path);
}

public sealed record PdfTextExtractionResult(
    int PageCount,
    IReadOnlyList<ExtractedDocumentPage> Pages);

public sealed partial class PdfPigTextExtractor : IPdfTextExtractor
{
    public PdfTextExtractionResult Extract(string path)
    {
        try
        {
            using var document = PdfDocument.Open(path);
            var pages = new List<ExtractedDocumentPage>(document.NumberOfPages);
            foreach (var page in document.GetPages())
            {
                var text = Normalize(ContentOrderTextExtractor.GetText(page));
                pages.Add(new ExtractedDocumentPage(
                    page.Number,
                    text,
                    RequiresVision: RequiresVisualAnalysis(page, text)));
            }
            return new PdfTextExtractionResult(document.NumberOfPages, pages);
        }
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
            return hasLargeImage || hasStructuredGraphics;
        }
        catch
        {
            // Text extraction remains usable even when optional image metadata
            // cannot be decoded for a particular PDF object.
            return false;
        }
    }

    [GeneratedRegex(@"[\t\f\v ]+")]
    private static partial Regex HorizontalWhitespace();

    [GeneratedRegex(@"\n{3,}")]
    private static partial Regex ExcessiveBlankLines();
}

public sealed class DocumentImportException(
    string message,
    Exception? innerException = null) : Exception(message, innerException);
