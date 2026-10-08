using System.Text.Json;

namespace ReviewPlatform.Server.Services;

public sealed record PdfEstimationProfile(string Model, string ReasoningEffort, string PromptVersion);
public sealed record PdfOutputEstimate(long? Tokens, long? LowerTokens, long? UpperTokens,
    int SampleCount, string Confidence);
public sealed record DirectPdfUsageRecord(string Id, DateTimeOffset RequestedAt, string SourceId,
    string DocumentHash, PdfEstimationProfile Profile, int PageCount, int OutputBudget,
    long? InputTokens, long? OutputTokens, long? ReasoningTokens, string Status,
    string? IncompleteReason, bool Validated, string? Failure);

/// Server-local diagnostics only: no request body, PDF bytes, API key or sync payload.
/// Raw responses can contain study material and are stored beside the private PDF originals.
public sealed class DirectPdfTelemetryStore
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private const int MinimumSamples = 5;
    private const int MaximumSamplesPerProfile = 100;
    private readonly object gate = new();
    private readonly Dictionary<PdfEstimationProfile, List<DirectPdfUsageRecord>> samples = [];
    private readonly ILogger<DirectPdfTelemetryStore> logger;
    private bool loaded;
    public string StorageDirectory { get; }

    public DirectPdfTelemetryStore(IWebHostEnvironment environment, IConfiguration configuration,
        ILogger<DirectPdfTelemetryStore> logger)
    {
        this.logger = logger;
        var configured = configuration["Documents:StoragePath"] ?? "App_Data/sources";
        var sources = Path.IsPathRooted(configured) ? configured : Path.Combine(environment.ContentRootPath, configured);
        StorageDirectory = Path.GetFullPath(Path.Combine(sources, "direct-pdf-usage"));
    }

    public async Task RecordAsync(DirectPdfUsageRecord record, string? responseBody)
    {
        // A received response must survive request cancellation. Persistence failure
        // must not turn a valid, paid extraction into a failed job.
        try
        {
            Directory.CreateDirectory(StorageDirectory);
            if (responseBody is not null)
                await File.WriteAllTextAsync(Path.Combine(StorageDirectory, record.Id + ".response.json"), responseBody);
            var path = Path.Combine(StorageDirectory, record.Id + ".usage.json");
            var temporary = path + ".tmp";
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(record, Json));
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            logger.LogWarning(exception, "Could not persist Direct PDF usage. AttemptId={AttemptId}", record.Id);
        }
        lock (gate)
        {
            LoadSamples();
            AddSample(record);
        }
        logger.LogInformation("Direct PDF usage. AttemptId={AttemptId} SourceId={SourceId} Model={Model} " +
            "ReasoningEffort={Effort} PromptVersion={PromptVersion} Pages={Pages} InputTokens={InputTokens} " +
            "OutputTokens={OutputTokens} ReasoningTokens={ReasoningTokens} Status={Status} " +
            "IncompleteReason={IncompleteReason} Validated={Validated}",
            record.Id, record.SourceId, record.Profile.Model, record.Profile.ReasoningEffort,
            record.Profile.PromptVersion, record.PageCount, record.InputTokens, record.OutputTokens,
            record.ReasoningTokens, record.Status, record.IncompleteReason, record.Validated);
    }

    public PdfOutputEstimate Estimate(PdfEstimationProfile profile, int pages)
    {
        lock (gate)
        {
            LoadSamples();
            var records = samples.GetValueOrDefault(profile) ?? [];
            if (records.Count < MinimumSamples) return new(null, null, null, records.Count, "insufficient");
            // A robust baseline, not a promise or a statistical confidence interval.
            // Total output already includes reasoning; never add reasoning a second time.
            var rates = records.Select(r => (double)r.OutputTokens!.Value / r.PageCount).Order().ToArray();
            var middle = rates.Length / 2;
            var median = rates.Length % 2 == 0 ? (rates[middle - 1] + rates[middle]) / 2 : rates[middle];
            static long Scale(double rate, int count) => (long)Math.Min(long.MaxValue, Math.Ceiling(rate * count));
            return new(Scale(median, pages), Scale(rates[0], pages), Scale(rates[^1], pages), records.Count,
                pages < records.Min(r => r.PageCount) || pages > records.Max(r => r.PageCount) ? "low" : "empirical");
        }
    }

    private void LoadSamples()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            if (!Directory.Exists(StorageDirectory)) return;
            foreach (var path in Directory.EnumerateFiles(StorageDirectory, "*.usage.json"))
            {
                try
                {
                    var record = JsonSerializer.Deserialize<DirectPdfUsageRecord>(File.ReadAllText(path), Json);
                    if (record is not null) AddSample(record);
                }
                catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
                { logger.LogWarning(exception, "Could not load Direct PDF usage sample."); }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        { logger.LogWarning(exception, "Could not load Direct PDF usage history."); }
    }

    private void AddSample(DirectPdfUsageRecord record)
    {
        if (!record.Validated || record.Status != "completed" || record.IncompleteReason is not null ||
            record.PageCount < 1 || record.InputTokens is not > 0 || record.OutputTokens is not > 0 ||
            record.ReasoningTokens is < 0 || record.ReasoningTokens > record.OutputTokens ||
            string.IsNullOrWhiteSpace(record.DocumentHash) || record.Profile is null) return;
        if (!samples.TryGetValue(record.Profile, out var records)) samples[record.Profile] = records = [];
        // Retried/repeated identical PDFs must not inflate the sample count.
        var old = records.FindIndex(r => r.DocumentHash == record.DocumentHash);
        if (old >= 0)
        {
            if (records[old].RequestedAt >= record.RequestedAt) return;
            records.RemoveAt(old);
        }
        records.Add(record);
        records.Sort((a, b) => a.RequestedAt.CompareTo(b.RequestedAt));
        if (records.Count > MaximumSamplesPerProfile) records.RemoveRange(0, records.Count - MaximumSamplesPerProfile);
    }
}
