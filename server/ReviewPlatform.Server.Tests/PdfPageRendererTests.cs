using System.Text;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class PdfPageRendererTests
{
    [Theory]
    [InlineData(300, 200)]
    [InlineData(200, 300)]
    [InlineData(300, 10000)]
    public async Task RenderAsync_ProducesJpegForRequestedPage(int width, int height)
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"review-platform-render-{Guid.NewGuid():N}.pdf");
        try
        {
            await File.WriteAllBytesAsync(
                path,
                BuildSinglePagePdf(width, height),
                TestContext.Current.CancellationToken);
            var renderer = new PdfiumPageRenderer();

            var page = await renderer.RenderAsync(
                path,
                1,
                TestContext.Current.CancellationToken);

            Assert.Equal(1, page.PageNumber);
            Assert.Equal("image/jpeg", page.MimeType);
            Assert.True(page.ImageBytes.Length > 100);
            Assert.Equal(0xff, page.ImageBytes[0]);
            Assert.Equal(0xd8, page.ImageBytes[1]);
            Assert.Equal(64, page.ContentHash.Length);
            using var bitmap = SkiaSharp.SKBitmap.Decode(page.ImageBytes);
            Assert.Equal(1600, Math.Max(bitmap.Width, bitmap.Height));
            Assert.True(bitmap.Width <= 1600 && bitmap.Height <= 1600);
            Assert.True(Math.Abs((double)bitmap.Width / bitmap.Height - (double)width / height) < 0.01);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private static byte[] BuildSinglePagePdf(int width, int height)
    {
        const string content = "BT /F1 18 Tf 72 120 Td (Review Platform) Tj ET";
        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] " +
            "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            $"<< /Length {Encoding.ASCII.GetByteCount(content)} >>\nstream\n" +
            $"{content}\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        };
        var builder = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (var index = 0; index < objects.Length; index++)
        {
            offsets.Add(Encoding.ASCII.GetByteCount(builder.ToString()));
            builder.Append(index + 1)
                .Append(" 0 obj\n")
                .Append(objects[index])
                .Append("\nendobj\n");
        }
        var xrefOffset = Encoding.ASCII.GetByteCount(builder.ToString());
        builder.Append("xref\n0 6\n")
            .Append("0000000000 65535 f \n");
        foreach (var offset in offsets)
        {
            builder.Append(offset.ToString("D10"))
                .Append(" 00000 n \n");
        }
        builder.Append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n")
            .Append(xrefOffset)
            .Append("\n%%EOF\n");
        return Encoding.ASCII.GetBytes(builder.ToString());
    }
}
