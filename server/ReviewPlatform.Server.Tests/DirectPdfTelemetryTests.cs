using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DirectPdfTelemetryTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "review-pdf-usage-" + Guid.NewGuid());
    private readonly PdfEstimationProfile profile = new("model", "low", "prompt-v1");
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
    private DirectPdfTelemetryStore Store() => new(new Environment(root),
        new ConfigurationBuilder().Build(), NullLogger<DirectPdfTelemetryStore>.Instance);
    private DirectPdfUsageRecord Record(int index, long output = 1000) => new(Guid.NewGuid().ToString("N"),
        DateTimeOffset.UtcNow, "source", $"document-{index}", profile, 10, 128_000,
        30_000, output, 500, "completed", null, true, null);

    [Fact]
    public async Task Estimator_RequiresIndependentSamples_UsesMedianAndObservedRange_PersistsAcrossRestart()
    {
        var store = Store();
        Assert.Null(store.Estimate(profile, 31).Tokens);
        for (var i = 0; i < 4; i++) await store.RecordAsync(Record(i, 1000 + i * 100), null);
        Assert.Equal(4, store.Estimate(profile, 31).SampleCount);
        Assert.Null(store.Estimate(profile, 31).Tokens);
        // Repeating one PDF doesn't pretend to be a fifth independent sample.
        await store.RecordAsync(Record(0, 1000), null);
        Assert.Equal(4, store.Estimate(profile, 31).SampleCount);
        await store.RecordAsync(Record(4, 20_000), null); // Outlier does not dominate the median.
        var estimate = store.Estimate(profile, 31);
        Assert.Equal(3720, estimate.Tokens); // 1200 / 10 * 31, reasoning already included.
        Assert.Equal(3100, estimate.LowerTokens);
        Assert.Equal(62_000, estimate.UpperTokens);
        Assert.Equal("low", estimate.Confidence); // Extrapolating beyond sampled pages.
        Assert.Equal("empirical", store.Estimate(profile, 10).Confidence);
        Assert.Equal(estimate, Store().Estimate(profile, 31));
        Assert.Null(store.Estimate(profile with { Model = "other" }, 31).Tokens);
        Assert.Null(store.Estimate(profile with { ReasoningEffort = "high" }, 31).Tokens);
        Assert.Null(store.Estimate(profile with { PromptVersion = "prompt-v2" }, 31).Tokens);
    }

    [Fact]
    public async Task TruncatedMalformedFailedAndMissingUsage_ArePreservedButExcluded()
    {
        var store = Store();
        var records = new[] {
            Record(0) with { Status = "incomplete", IncompleteReason = "max_output_tokens", Validated = false },
            Record(1) with { Validated = false, Failure = "LlmProviderRequestException" },
            Record(2) with { OutputTokens = null },
            Record(3) with { InputTokens = null },
            Record(4) with { ReasoningTokens = 2000 },
            Record(5) with { Status = "failed", Validated = false }
        };
        foreach (var record in records) await store.RecordAsync(record, "{\"partial\":true}");
        Assert.Equal(0, store.Estimate(profile, 10).SampleCount);
        Assert.Equal(records.Length, Directory.GetFiles(store.StorageDirectory, "*.usage.json").Length);
        Assert.Equal(records.Length, Directory.GetFiles(store.StorageDirectory, "*.response.json").Length);
        Assert.Equal(0, Store().Estimate(profile, 10).SampleCount);
    }

    [Fact]
    public async Task DiagnosticsDiskFailure_DoesNotFailAnOtherwiseSuccessfulExtraction()
    {
        // A file where the storage directory should be simulates a write failure
        // without changing permissions or touching any user-owned directory.
        await File.WriteAllTextAsync(root, "not a directory", TestContext.Current.CancellationToken);
        try
        {
            var store = Store();
            await store.RecordAsync(Record(0), "{\"status\":\"completed\"}");
            Assert.Equal(1, store.Estimate(profile, 10).SampleCount);
        }
        finally { File.Delete(root); }
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
