using System.Text.Json;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class OpenAiModelCapabilitiesRegistry
{
    private static readonly IReadOnlyDictionary<string, OpenAiModelCapabilities> Models = Load();
    private static readonly OpenAiModelCapabilities Unknown = new(false, [], null, null);

    public static OpenAiModelCapabilities Get(string model) =>
        Models.GetValueOrDefault(model, Unknown);

    public static bool SupportsEffort(string model, string effort) =>
        Get(model).ReasoningEfforts.Contains(effort, StringComparer.Ordinal);

    public static bool IsKnownIncompatible(string model) =>
        Get(model) is { IsKnown: true, SupportsStructuredOutputs: false };

    private static IReadOnlyDictionary<string, OpenAiModelCapabilities> Load()
    {
        using var stream = typeof(OpenAiModelCapabilitiesRegistry).Assembly
            .GetManifestResourceStream("ReviewPlatform.Server.AI.openai-model-capabilities.json")
            ?? throw new InvalidOperationException("OpenAI model capability registry is missing.");
        var registry = JsonSerializer.Deserialize<Registry>(stream,
            new JsonSerializerOptions(JsonSerializerDefaults.Web))
            ?? throw new InvalidOperationException("OpenAI model capability registry is invalid.");
        var models = new Dictionary<string, OpenAiModelCapabilities>(StringComparer.Ordinal);
        foreach (var entry in registry.Entries)
        {
            if (entry.Models.Count == 0 || entry.MaxOutputTokens is <= 0 ||
                (entry.SupportsStructuredOutputs && entry.MaxOutputTokens is null) ||
                !Uri.TryCreate(entry.Source, UriKind.Absolute, out var source) ||
                source.Scheme != "https" || source.Host != "developers.openai.com" ||
                entry.ReasoningEfforts.Distinct(StringComparer.Ordinal).Count() != entry.ReasoningEfforts.Count ||
                entry.ReasoningEfforts.Any(effort => effort is not
                    ("none" or "minimal" or "low" or "medium" or "high" or "xhigh" or "max")) ||
                (entry.DefaultReasoningEffort is not null &&
                 !entry.ReasoningEfforts.Contains(entry.DefaultReasoningEffort)))
                throw new InvalidOperationException("OpenAI model capability entry is invalid.");
            var capabilities = new OpenAiModelCapabilities(true,
                entry.ReasoningEfforts, entry.DefaultReasoningEffort, entry.MaxOutputTokens,
                entry.SupportsStructuredOutputs,
                entry.SupportsReasoning || entry.ReasoningEfforts.Count > 0);
            foreach (var model in entry.Models) models.Add(model, capabilities);
        }
        return models;
    }

    private sealed record Registry(IReadOnlyList<Entry> Entries);
    private sealed record Entry(IReadOnlyList<string> Models,
        IReadOnlyList<string> ReasoningEfforts, string? DefaultReasoningEffort,
        int? MaxOutputTokens, string Source,
        bool SupportsStructuredOutputs = true,
        bool SupportsReasoning = false);
}
