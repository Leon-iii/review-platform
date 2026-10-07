using System.Text;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.Services;
using UglyToad.PdfPig.Writer;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DocumentProcessingServiceTests : IAsyncLifetime
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"review-pdf-original-{Guid.NewGuid()}");
    public ValueTask InitializeAsync() { Directory.CreateDirectory(root); return ValueTask.CompletedTask; }
    public ValueTask DisposeAsync() { Directory.Delete(root, true); return ValueTask.CompletedTask; }
    private DocumentProcessingService Service() => new(new Renderer(), new Environment(root),
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> {
            ["Documents:StoragePath"] = "sources", ["Documents:MinimumFreeDiskSpaceMb"] = "0"
        }).Build(), NullLogger<DocumentProcessingService>.Instance);

    [Fact]
    public async Task Upload_PreservesExactBytes_Idempotently_AndRejectsReplacement()
    {
        var id = Guid.NewGuid().ToString();
        var builder = new PdfDocumentBuilder();
        builder.AddPage(600, 400);
        var bytes = builder.Build();
        var service = Service();
        using var first = new MemoryStream(bytes);
        await service.StoreUploadAsync(id, first, "강의.pdf", bytes.Length, TestContext.Current.CancellationToken);
        using var duplicate = new MemoryStream(bytes);
        await service.StoreUploadAsync(id, duplicate, "강의.pdf", bytes.Length, TestContext.Current.CancellationToken);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(Path.Combine(root, "sources", $"{id}.pdf"), TestContext.Current.CancellationToken));
        Assert.Equal(1, service.InspectStoredPdf(id).PageCount);
        using var different = new MemoryStream(Encoding.ASCII.GetBytes("%PDF-1.7 different"));
        await Assert.ThrowsAsync<DocumentImportException>(() => service.StoreUploadAsync(id, different, "강의.pdf", different.Length, TestContext.Current.CancellationToken));
        Assert.Equal(bytes, await File.ReadAllBytesAsync(Path.Combine(root, "sources", $"{id}.pdf"), TestContext.Current.CancellationToken));
        Assert.Single(Directory.GetFiles(Path.Combine(root, "sources")));
    }

    [Theory]
    [InlineData("not a PDF", 9)]
    [InlineData("%PDF-test", 99)]
    [InlineData("%PDF-test", 4)]
    public async Task InvalidOrIncompleteUpload_LeavesNoFiles(string body, int length)
    {
        using var stream = new MemoryStream(Encoding.ASCII.GetBytes(body));
        await Assert.ThrowsAsync<DocumentImportException>(() => Service().StoreUploadAsync(
            Guid.NewGuid().ToString(), stream, "강의.pdf", length, TestContext.Current.CancellationToken));
        Assert.Empty(Directory.GetFiles(Path.Combine(root, "sources")));
    }

    [Theory]
    [InlineData("../other")]
    [InlineData("invalid")]
    public void Delete_RejectsUnsafeSourceIds(string id) =>
        Assert.Throws<DocumentImportException>(() => Service().DeletePdf(id));

    [Fact]
    public async Task Original_IsOnlyDeletedByExplicitDeletion()
    {
        var id = Guid.NewGuid().ToString();
        using var stream = new MemoryStream(Encoding.ASCII.GetBytes("%PDF-1.7 retained"));
        var service = Service();
        await service.StoreUploadAsync(id, stream, "강의.pdf", stream.Length, TestContext.Current.CancellationToken);
        Assert.True(File.Exists(Path.Combine(root, "sources", $"{id}.pdf")));
        service.DeletePdf(id);
        service.DeletePdf(id);
        Assert.False(File.Exists(Path.Combine(root, "sources", $"{id}.pdf")));
    }

    private sealed class Renderer : IPdfPageRenderer
    {
        public Task<RenderedDocumentPage> RenderAsync(string path, int pageNumber, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
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
