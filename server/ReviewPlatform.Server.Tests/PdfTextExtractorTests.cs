using System.Text;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class PdfTextExtractorTests
{
    [Theory]
    [InlineData("50 150 500 90 re S", true)]
    [InlineData("50 150 500 90 re f", true)]
    [InlineData("50 150 m 550 150 l 550 240 l 50 240 l h S", true)]
    [InlineData("60 150 m 540 150 l 550 150 550 160 550 170 c 550 220 l 550 240 540 240 530 240 c 70 240 l 50 240 50 230 50 220 c 50 170 l 50 150 60 150 60 150 c h S", true)]
    [InlineData("", false)]
    [InlineData("450 20 60 30 re S", false)]
    [InlineData("5 5 590 390 re S", false)]
    [InlineData("50 180 m 550 180 l S", false)]
    public async Task SingleTextCallout_TriggersVisionButDecorationDoesNot(string drawing, bool needsVision)
    {
        var content = drawing + "\n" + """
            BT /F1 14 Tf 60 340 Td (Network history and milestones) Tj ET
            BT /F1 12 Tf 60 300 Td (1961 - first historical milestone) Tj ET
            BT /F1 12 Tf 60 210 Td (Independent interconnection principles) Tj ET
            BT /F1 12 Tf 60 185 Td (Related networks operate independently.) Tj ET
            BT /F1 12 Tf 60 90 Td (1972 - another historical milestone) Tj ET
            """;
        await CheckPdf(content, page =>
        {
            Assert.Equal(needsVision, page.RequiresVision);
            Assert.Contains("interconnection principles", page.Text);
            Assert.Contains("historical milestone", page.Text);
        });
    }

    [Fact]
    public async Task BoxAroundAllText_DoesNotTriggerExtraVision()
    {
        await CheckPdf("""
            50 150 500 90 re S
            BT /F1 12 Tf 60 210 Td (A single concept with no surrounding text) Tj ET
            """, page => Assert.False(page.RequiresVision));
    }

    private static async Task CheckPdf(string content, Action<Contracts.ExtractedDocumentPage> assert)
    {
        var path = Path.Combine(Path.GetTempPath(), $"review-platform-box-{Guid.NewGuid():N}.pdf");
        try
        {
            await File.WriteAllBytesAsync(path, BuildPdf(content), TestContext.Current.CancellationToken);
            var result = new PdfPigTextExtractor().Extract(path, TestContext.Current.CancellationToken, 1, 10_000);
            assert(Assert.Single(result.Pages));
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private static byte[] BuildPdf(string content)
    {
        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 400] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            $"<< /Length {Encoding.ASCII.GetByteCount(content)} >>\nstream\n{content}\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        };
        var builder = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (var i = 0; i < objects.Length; i++)
        {
            offsets.Add(Encoding.ASCII.GetByteCount(builder.ToString()));
            builder.Append(i + 1).Append(" 0 obj\n").Append(objects[i]).Append("\nendobj\n");
        }
        var xref = Encoding.ASCII.GetByteCount(builder.ToString());
        builder.Append("xref\n0 6\n0000000000 65535 f \n");
        foreach (var offset in offsets) builder.Append(offset.ToString("D10")).Append(" 00000 n \n");
        builder.Append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n").Append(xref).Append("\n%%EOF\n");
        return Encoding.ASCII.GetBytes(builder.ToString());
    }
}
