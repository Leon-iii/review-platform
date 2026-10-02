using System.Net;
using System.Text;
using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class LlmModelCatalogServiceTests
{
    [Fact]
    public async Task Ollama_ReturnsModelsInstalledOnServerComputer()
    {
        HttpRequestMessage? captured = null;
        var service = CreateService((name, request) =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/show")
                return Json("""{"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960}}""");
            captured = request;
            return Json("""
                {"models":[{"name":"qwen3-vl:8b-instruct"},{"name":"qwen3:8b"}]}
                """);
        });

        var result = await service.GetModelsAsync(
            "ollama",
            TestContext.Current.CancellationToken);

        Assert.Equal("ollama", result.Provider);
        Assert.Equal(["qwen3-vl:8b-instruct", "qwen3:8b"], result.Models);
        Assert.Equal(40_960, result.ContextWindows!["qwen3:8b"]);
        Assert.Equal("http://127.0.0.1:11434/api/tags",
            captured!.RequestUri!.ToString());
        Assert.Equal("unknown", result.ModelMetadata!["qwen3:8b"].Lifecycle);
    }

    [Fact]
    public async Task OpenAi_ReturnsOnlyStructuredTextModelFamilies()
    {
        HttpRequestMessage? captured = null;
        var service = CreateService((name, request) =>
        {
            captured = request;
            return Json("""
                {"data":[
                  {"id":"gpt-4o-mini"},
                  {"id":"gpt-5"},
                  {"id":"gpt-6-luna"},
                  {"id":"gpt-5.4-mini-2026-03-17"},
                  {"id":"gpt-5.5-pro"},
                  {"id":"o3-pro"},
                  {"id":"gpt-5.4-pro"},
                  {"id":"gpt-5.2-pro-2025-12-11"},
                  {"id":"o1-mini"},
                  {"id":"o3-deep-research"},
                  {"id":"gpt-4o-2024-05-13"},
                  {"id":"gpt-5-search-api"},
                  {"id":"gpt-7-future"},
                  {"id":"o3-mini"},
                  {"id":"o5-future"},
                  {"id":"gpt-4-turbo"},
                  {"id":"text-embedding-3-small"},
                  {"id":"gpt-4o-realtime-preview"}
                ]}
                """);
        }, apiKey: "secret-key");

        var result = await service.GetModelsAsync(
            "openai",
            TestContext.Current.CancellationToken);

        Assert.Equal(
            ["gpt-4o-mini", "gpt-5", "gpt-5.4-mini-2026-03-17", "gpt-5.5-pro",
                "gpt-6-luna", "gpt-7-future", "o3-mini", "o3-pro", "o5-future"],
            result.Models);
        Assert.Equal("https://api.openai.com/v1/models",
            captured!.RequestUri!.ToString());
        Assert.Equal("Bearer", captured.Headers.Authorization!.Scheme);
        Assert.Equal("secret-key", captured.Headers.Authorization.Parameter);
        Assert.True(result.ModelCapabilities!["gpt-5"].IsKnown);
        Assert.Equal(["minimal", "low", "medium", "high"],
            result.ModelCapabilities["gpt-5"].ReasoningEfforts);
        Assert.True(result.ModelCapabilities["gpt-4o-mini"].IsKnown);
        Assert.Empty(result.ModelCapabilities["gpt-4o-mini"].ReasoningEfforts);
        Assert.False(result.ModelCapabilities["gpt-7-future"].IsKnown);
        Assert.Empty(result.ModelCapabilities["gpt-7-future"].ReasoningEfforts);
        Assert.Contains("max", result.ModelCapabilities["gpt-6-luna"].ReasoningEfforts);
        Assert.True(result.ModelCapabilities["o3-pro"].SupportsReasoning);
        Assert.Empty(result.ModelCapabilities["o3-pro"].ReasoningEfforts);
        // Presentation filtering must not remove models from the raw API catalog.
        Assert.Equal("legacy", result.ModelMetadata!["gpt-5"].Lifecycle);
        Assert.Equal("current", result.ModelMetadata["gpt-6-luna"].Lifecycle);
        Assert.True(result.ModelMetadata["gpt-5.4-mini-2026-03-17"].IsSnapshot);
        Assert.Equal("unknown", result.ModelMetadata["gpt-7-future"].Lifecycle);
    }

    [Fact]
    public async Task OpenAi_WithoutApiKeyReturnsConfigurationError()
    {
        var service = CreateService((_, _) => throw new InvalidOperationException());

        var exception = await Assert.ThrowsAsync<LlmModelCatalogException>(() =>
            service.GetModelsAsync(
                "openai",
                TestContext.Current.CancellationToken));

        Assert.Contains("OpenAI API Key", exception.Message);
        Assert.Contains("LLM 프로필", exception.Message);
    }

    [Fact]
    public async Task OpenAi_UnauthorizedReturnsActionableKeyError()
    {
        var service = CreateService((_, _) => new HttpResponseMessage(
            HttpStatusCode.Unauthorized), apiKey: "invalid-key");

        var exception = await Assert.ThrowsAsync<LlmModelCatalogException>(() =>
            service.GetModelsAsync(
                "openai",
                TestContext.Current.CancellationToken));

        Assert.Contains("API Key 인증", exception.Message);
        Assert.Contains("LLM 프로필", exception.Message);
    }

    private static LlmModelCatalogService CreateService(
        Func<string, HttpRequestMessage, HttpResponseMessage> response,
        string apiKey = "") =>
        new(
            new FakeHttpClientFactory(response),
            new MemoryApiKeyStore(apiKey),
            NullLogger<LlmModelCatalogService>.Instance,
            new OllamaModelMetadataService(new FakeHttpClientFactory(response)));

    private sealed class MemoryApiKeyStore(string openAiKey) : ILlmApiKeyStore
    {
        public Task EnsureBootstrapKeysAsync(
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task<string> GetAsync(
            string provider,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(provider == "openai" ? openAiKey : string.Empty);

        public Task<IReadOnlyDictionary<string, bool>> GetConfiguredAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyDictionary<string, bool>>(
                new Dictionary<string, bool>());

        public Task UpdateAsync(
            IReadOnlyDictionary<string, string?>? apiKeys,
            CancellationToken cancellationToken = default) => Task.CompletedTask;
    }

    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json")
    };

    private sealed class FakeHttpClientFactory(
        Func<string, HttpRequestMessage, HttpResponseMessage> response)
        : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(
            new Handler(request => response(name, request)));
    }

    private sealed class Handler(
        Func<HttpRequestMessage, HttpResponseMessage> response)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(response(request));
    }
}
