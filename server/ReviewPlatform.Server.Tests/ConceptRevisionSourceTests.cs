using System.Security.Cryptography;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptRevisionSourceTests : IAsyncLifetime
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "review-revision-source-" + Guid.NewGuid());
    private readonly string id = Guid.NewGuid().ToString("D");
    public ValueTask InitializeAsync() { Directory.CreateDirectory(Path.Combine(root, "sources")); return ValueTask.CompletedTask; }
    public ValueTask DisposeAsync() { Directory.Delete(root, true); return ValueTask.CompletedTask; }
    private DocumentProcessingService Reader() => new(new Renderer(), new Environment(root),
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> {
            ["Documents:StoragePath"] = "sources", ["Documents:MaximumPages"] = "1"
        }).Build(), NullLogger<DocumentProcessingService>.Instance);
    private async Task<byte[]> StoreAsync(int pages = 50)
    {
        var pdf = new PdfDocumentBuilder();
        for (var page = 1; page <= pages; page++) pdf.AddPage(600 + page, 400);
        var bytes = pdf.Build();
        await File.WriteAllBytesAsync(Path.Combine(root, "sources", id + ".pdf"), bytes, TestContext.Current.CancellationToken);
        return bytes;
    }

    [Fact]
    public async Task Excerpt_SortsDeduplicatesAndMapsNoncontiguousPages_WithoutImportLimitOrCheckpoint()
    {
        var original = await StoreAsync();
        var source = await Reader().ReadAsync(id, 50, [50, 47, 50],
            Convert.ToHexString(SHA256.HashData(original)), TestContext.Current.CancellationToken);
        Assert.Equal([47, 50], source.OriginalPages);
        using var excerpt = PdfDocument.Open(source.PdfBytes);
        Assert.Equal(2, excerpt.NumberOfPages);
        Assert.Equal(647, excerpt.GetPage(1).Width);
        Assert.Equal(650, excerpt.GetPage(2).Width);
        Assert.Equal(original, await File.ReadAllBytesAsync(Path.Combine(root, "sources", id + ".pdf"), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(51)]
    public async Task Excerpt_RejectsInvalidPagesAndMismatchedCount(int page)
    {
        await StoreAsync();
        await Assert.ThrowsAsync<DocumentImportException>(() => Reader().ReadAsync(id, 50, [page], null, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => Reader().ReadAsync(id, 49, [1], null, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Excerpt_RejectsMissingCorruptAndMismatchedOriginal_AndPathTraversal()
    {
        await Assert.ThrowsAsync<DocumentImportException>(() => Reader().ReadAsync(id, 1, [1], null, TestContext.Current.CancellationToken));
        await StoreAsync(1);
        await Assert.ThrowsAsync<DocumentImportException>(() => Reader().ReadAsync(id, 1, [1], new string('0', 64), TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<DocumentImportException>(() => Reader().ReadAsync("../outside", 1, [1], null, TestContext.Current.CancellationToken));
        await File.WriteAllTextAsync(Path.Combine(root, "sources", id + ".pdf"), "broken PDF", TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<DocumentImportException>(() => Reader().ReadAsync(id, 1, [1], null, TestContext.Current.CancellationToken));
    }

    private sealed class Renderer : IPdfPageRenderer
    {
        public Task<RenderedDocumentPage> RenderAsync(string path, int pageNumber, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Revision source preparation must not run OCR or image rendering.");
    }
    private sealed class Environment(string path) : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "Tests";
        public string EnvironmentName { get; set; } = "Testing";
        public string ContentRootPath { get; set; } = path;
        public string WebRootPath { get; set; } = path;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
    }
}
