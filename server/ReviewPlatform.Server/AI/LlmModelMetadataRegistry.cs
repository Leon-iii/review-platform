using System.Text.Json;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class LlmModelMetadataRegistry
{
    private static readonly IReadOnlyDictionary<(string Provider, string Model), LlmModelMetadata> Models = Load();
    private static readonly LlmModelMetadata Unknown = new();

    public static LlmModelMetadata Get(string provider, string model) =>
        Models.GetValueOrDefault((provider, model), Unknown);

    private static IReadOnlyDictionary<(string, string), LlmModelMetadata> Load()
    {
        using var stream = typeof(LlmModelMetadataRegistry).Assembly
            .GetManifestResourceStream("ReviewPlatform.Server.AI.llm-model-metadata.json")
            ?? throw new InvalidOperationException("LLM model metadata registry is missing.");
        var registry = JsonSerializer.Deserialize<Registry>(stream,
            new JsonSerializerOptions(JsonSerializerDefaults.Web))
            ?? throw new InvalidOperationException("LLM model metadata registry is invalid.");
        var models = new Dictionary<(string, string), LlmModelMetadata>();
        foreach (var entry in registry.Entries)
        {
            if (string.IsNullOrWhiteSpace(entry.Provider) || entry.Models.Count == 0 ||
                entry.Lifecycle is not ("current" or "legacy" or "deprecated" or "retired") ||
                entry.Models.Any(string.IsNullOrWhiteSpace))
                throw new InvalidOperationException("LLM model metadata entry is invalid.");
            foreach (var model in entry.Models)
                models.Add((entry.Provider, model), new(entry.Lifecycle, entry.IsSnapshot));
        }
        return models;
    }

    private sealed record Registry(IReadOnlyList<Entry> Entries);
    private sealed record Entry(string Provider, IReadOnlyList<string> Models,
        string Lifecycle, bool IsSnapshot = false);
}
