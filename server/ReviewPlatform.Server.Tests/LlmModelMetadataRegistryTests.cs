using System.Text.Json;
using ReviewPlatform.Server.AI;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class LlmModelMetadataRegistryTests
{
    [Fact]
    public void Metadata_CoversEveryReviewedOpenAiIdWithoutInventingFutureIds()
    {
        using var stream = typeof(OpenAiModelCapabilitiesRegistry).Assembly
            .GetManifestResourceStream("ReviewPlatform.Server.AI.openai-model-capabilities.json")!;
        using var registry = JsonDocument.Parse(stream);
        foreach (var entry in registry.RootElement.GetProperty("entries").EnumerateArray())
        foreach (var model in entry.GetProperty("models").EnumerateArray())
            Assert.NotEqual("unknown", LlmModelMetadataRegistry.Get("openai", model.GetString()!).Lifecycle);
        Assert.Equal("unknown", LlmModelMetadataRegistry.Get("openai", "gpt-7-future-2026-10-01").Lifecycle);
        Assert.False(LlmModelMetadataRegistry.Get("openai", "gpt-7-future-2026-10-01").IsSnapshot);
    }

    [Theory]
    [InlineData("gpt-6-luna", "current", false)]
    [InlineData("gpt-5.4-mini-2026-03-17", "current", true)]
    [InlineData("gpt-5-mini", "legacy", false)]
    [InlineData("gpt-4o-2024-11-20", "legacy", true)]
    [InlineData("o3-mini", "deprecated", false)]
    [InlineData("gpt-5.2-chat-latest", "retired", false)]
    public void Metadata_UsesExactReviewedLifecycleAndSnapshotIds(string model, string lifecycle, bool snapshot)
    {
        var metadata = LlmModelMetadataRegistry.Get("openai", model);
        Assert.Equal(lifecycle, metadata.Lifecycle);
        Assert.Equal(snapshot, metadata.IsSnapshot);
        Assert.Equal("unknown", LlmModelMetadataRegistry.Get("ollama", model).Lifecycle);
        Assert.Equal("unknown", LlmModelMetadataRegistry.Get("gemini", model).Lifecycle);
    }
}
