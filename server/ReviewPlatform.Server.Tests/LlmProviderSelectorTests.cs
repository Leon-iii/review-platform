using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class LlmProviderSelectorTests
{
    [Theory]
    [InlineData("ollama", "ollama")]
    [InlineData("OLLAMA", "ollama")]
    [InlineData("openai", "openai")]
    [InlineData("OpenAI", "openai")]
    public void Select_UsesConfiguredProviderCaseInsensitively(
        string configured,
        string expected)
    {
        var selector = CreateSelector(configured);

        var selected = selector.Select();

        Assert.Equal(expected, selected.ProviderName);
    }

    [Fact]
    public void Select_UnknownProviderThrowsClearConfigurationError()
    {
        var selector = CreateSelector("unknown-provider");

        var exception = Assert.Throws<LlmProviderUnavailableException>(
            selector.Select);

        Assert.Contains("unknown-provider", exception.Message);
        Assert.Contains("지원하지 않는", exception.Message);
    }

    [Fact]
    public void Defaults_SelectLocalQwenWithoutApiKey()
    {
        var defaults = new LlmOptions();

        Assert.Equal("ollama", defaults.Provider);
        Assert.Equal("qwen3:8b", defaults.Model);
        Assert.Equal("http://127.0.0.1:11434", defaults.BaseUrl);
        Assert.Empty(defaults.ApiKey);
    }

    [Fact]
    public void Configuration_BindsEnvironmentStyleLlmSettings()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Llm:Provider"] = "ollama",
                ["Llm:Model"] = "custom-qwen:latest",
                ["Llm:BaseUrl"] = "http://localhost:22434"
            })
            .Build();

        var parsed = configuration.GetSection("Llm").Get<LlmOptions>();

        Assert.NotNull(parsed);
        Assert.Equal("ollama", parsed.Provider);
        Assert.Equal("custom-qwen:latest", parsed.Model);
        Assert.Equal("http://localhost:22434", parsed.BaseUrl);
        Assert.Empty(parsed.ApiKey);
    }

    private static LlmProviderSelector CreateSelector(string provider)
    {
        var options = Options.Create(new LlmOptions
        {
            Provider = provider,
            Model = provider.Equals("openai", StringComparison.OrdinalIgnoreCase)
                ? "gpt-test"
                : "qwen3:8b",
            BaseUrl = "http://127.0.0.1:11434",
            ApiKey = "openai-test-key"
        });
        var handler = new NoopHandler();
        return new LlmProviderSelector(
            new OpenAiLlmProvider(new HttpClient(handler), options),
            new OllamaLlmProvider(
                new HttpClient(handler),
                options,
                NullLogger<OllamaLlmProvider>.Instance),
            options);
    }

    private sealed class NoopHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("No request expected.");
    }
}
