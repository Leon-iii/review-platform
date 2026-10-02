using System.Security.Cryptography;
using PDFtoImage;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public interface IPdfPageRenderer
{
    Task<RenderedDocumentPage> RenderAsync(
        string path,
        int pageNumber,
        CancellationToken cancellationToken = default);
}

public sealed record RenderedDocumentPage(
    int PageNumber,
    string MimeType,
    byte[] ImageBytes,
    string ContentHash);

public sealed class PdfiumPageRenderer : IPdfPageRenderer
{
    private const int RenderWidth = 1_600;

    public Task<RenderedDocumentPage> RenderAsync(
        string path,
        int pageNumber,
        CancellationToken cancellationToken = default)
    {
        if (pageNumber < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(pageNumber));
        }

        return Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var pdf = File.OpenRead(path);
                using var image = new MemoryStream();
#pragma warning disable CA1416 // PDFtoImage declares Windows/Linux/macOS support.
                var size = Conversion.GetPageSize(pdf, page: pageNumber - 1, leaveOpen: true);
                pdf.Position = 0;
                if (size.Width <= 0 || size.Height <= 0)
                    throw new DocumentImportException("PDF 페이지 크기가 올바르지 않습니다.");
                Conversion.SaveJpeg(
                    image,
                    pdf,
                    page: pageNumber - 1,
                    options: new RenderOptions(
                        Width: size.Width >= size.Height ? RenderWidth : null,
                        Height: size.Height > size.Width ? RenderWidth : null,
                        WithAspectRatio: true));
#pragma warning restore CA1416
                var bytes = image.ToArray();
                return new RenderedDocumentPage(
                    pageNumber,
                    "image/jpeg",
                    bytes,
                    Convert.ToHexString(SHA256.HashData(bytes))
                        .ToLowerInvariant());
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new DocumentImportException(
                    $"PDF {pageNumber}페이지를 OCR 이미지로 변환하지 못했습니다.",
                    exception);
            }
        }, cancellationToken);
    }
}
