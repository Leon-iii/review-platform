using System.Text.Json;
using ReviewPlatform.Server.AI;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class OpenAiModelCapabilitiesRegistryTests
{
    [Fact]
    public void Registry_ContainsAllReviewedIdsAndConsistentSnapshotCapabilities()
    {
        using var stream = typeof(OpenAiModelCapabilitiesRegistry).Assembly
            .GetManifestResourceStream("ReviewPlatform.Server.AI.openai-model-capabilities.json")!;
        using var registry = JsonDocument.Parse(stream);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in registry.RootElement.GetProperty("entries").EnumerateArray())
        {
            var models = entry.GetProperty("models").EnumerateArray()
                .Select(model => model.GetString()!).ToArray();
            var expected = OpenAiModelCapabilitiesRegistry.Get(models[0]);
            Assert.True(expected.IsKnown);
            foreach (var model in models)
            {
                Assert.True(ids.Add(model));
                Assert.Same(expected, OpenAiModelCapabilitiesRegistry.Get(model));
            }
            if (expected.SupportsStructuredOutputs) Assert.True(expected.MaxOutputTokens > 0);
            if (expected.DefaultReasoningEffort is { } effort)
                Assert.Contains(effort, expected.ReasoningEfforts);
        }
        Assert.Equal(79, ids.Count);
    }

    [Theory]
    [InlineData("gpt-6-luna")]
    [InlineData("gpt-5.6-luna")]
    [InlineData("gpt-5.6-terra")]
    public void LunaAndTerra_SupportSixEfforts(string model)
    {
        var capabilities = OpenAiModelCapabilitiesRegistry.Get(model);
        Assert.True(capabilities.IsKnown);
        Assert.True(capabilities.SupportsReasoning);
        Assert.Equal(["none", "low", "medium", "high", "xhigh", "max"], capabilities.ReasoningEfforts);
        Assert.Equal("medium", capabilities.DefaultReasoningEffort);
    }

    [Theory]
    [InlineData("gpt-5.4-mini-2026-03-17", "xhigh")]
    [InlineData("gpt-5.4-nano", "none")]
    [InlineData("gpt-5.5-pro", "xhigh")]
    [InlineData("gpt-5-pro", "high")]
    [InlineData("gpt-5.3-codex", "xhigh")]
    [InlineData("gpt-5.2-codex", "low")]
    [InlineData("o3-mini-2025-01-31", "medium")]
    public void NewlyReviewedModels_SupportDocumentedEfforts(string model, string effort) =>
        Assert.True(OpenAiModelCapabilitiesRegistry.SupportsEffort(model, effort));

    [Theory]
    [InlineData("gpt-5.1-codex-max")]
    [InlineData("gpt-5.1-codex-mini")]
    [InlineData("gpt-5-codex")]
    [InlineData("gpt-5.6-cyber")]
    [InlineData("o1")]
    [InlineData("o1-pro")]
    [InlineData("o3-pro")]
    public void AutomaticOnlyReasoning_IsKnownButDoesNotInventManualValues(string model)
    {
        var capabilities = OpenAiModelCapabilitiesRegistry.Get(model);
        Assert.True(capabilities.IsKnown);
        Assert.True(capabilities.SupportsReasoning);
        Assert.Empty(capabilities.ReasoningEfforts);
        Assert.Null(capabilities.DefaultReasoningEffort);
    }

    [Theory]
    [InlineData("gpt-6-luna-2026-10-01")]
    [InlineData("gpt-7-future")]
    [InlineData("gpt-5.3-codex-future")]
    [InlineData("ft:gpt-6-luna:custom")]
    public void UnreviewedIds_DoNotInheritCapabilitiesFromPrefixes(string model) =>
        Assert.False(OpenAiModelCapabilitiesRegistry.Get(model).IsKnown);
}
