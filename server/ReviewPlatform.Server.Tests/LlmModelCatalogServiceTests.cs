using System.Net;
using System.Text;
using Microsoft.Extensions.Options;
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
        Assert.Equal("http://127.0.0.1:11434/api/tags",
            captured!.RequestUri!.ToString());
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
            ["gpt-4o-mini", "gpt-5", "gpt-7-future", "o3-mini", "o5-future"],
            result.Models);
        Assert.Equal("https://api.openai.com/v1/models",
            captured!.RequestUri!.ToString());
        Assert.Equal("Bearer", captured.Headers.Authorization!.Scheme);
        Assert.Equal("secret-key", captured.Headers.Authorization.Parameter);
    }

    [Fact]
    public async Task OpenAi_WithoutApiKeyReturnsConfigurationError()
    {
        var service = CreateService((_, _) => throw new InvalidOperationException());

        var exception = await Assert.ThrowsAsync<LlmModelCatalogException>(() =>
            service.GetModelsAsync(
                "openai",
                TestContext.Current.CancellationToken));

        Assert.Contains("OPENAI_API_KEY", exception.Message);
    }

    private static LlmModelCatalogService CreateService(
        Func<string, HttpRequestMessage, HttpResponseMessage> response,
        string apiKey = "") =>
        new(
            new FakeHttpClientFactory(response),
            Options.Create(new LlmOptions { ApiKey = apiKey }));

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
