using Microsoft.Extensions.Options;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;

namespace ReviewPlatform.Server.AI;

public interface ILlmProviderResolver
{
    Task<ILLMProvider> ResolveAsync(
        string purpose,
        CancellationToken cancellationToken = default);
}

public sealed class RuntimeLlmProviderResolver(
    LlmProfileService profiles,
    ILlmApiKeyStore apiKeyStore,
    IHttpClientFactory httpClientFactory,
    ILoggerFactory loggerFactory) : ILlmProviderResolver
{
    public async Task<ILLMProvider> ResolveAsync(
        string purpose,
        CancellationToken cancellationToken = default)
    {
        var profile = await profiles.GetActiveProfileAsync(
            purpose,
            cancellationToken);
        var apiKey = profile.Provider == "ollama"
            ? string.Empty
            : await apiKeyStore.GetAsync(profile.Provider, cancellationToken);
        var options = Options.Create(new LlmOptions
        {
            Provider = profile.Provider,
            Model = profile.Model,
            BaseUrl = profile.Provider == "ollama"
                ? LlmOptions.LocalOllamaBaseUrl
                : string.Empty,
            ApiKey = apiKey,
            MaximumQuestionsPerRequest = profile.MaximumQuestionsPerRequest,
            ContextWindowTokens = profile.Provider == "ollama"
                ? profile.ContextWindowTokens
                : null,
            ReasoningEffort = profile.Provider == "openai"
                ? profile.ReasoningEffort
                : null
        });
        return profile.Provider switch
        {
            "ollama" => new OllamaLlmProvider(
                httpClientFactory.CreateClient("ollama"),
                options,
                loggerFactory.CreateLogger<OllamaLlmProvider>()),
            "openai" => new OpenAiLlmProvider(
                httpClientFactory.CreateClient("openai"),
                options),
            _ => throw new LlmProviderUnavailableException(
                $"지원하지 않는 LLM Provider입니다: '{profile.Provider}'.")
        };
    }
}

public sealed class FixedLlmProviderResolver(ILLMProvider provider)
    : ILlmProviderResolver
{
    public Task<ILLMProvider> ResolveAsync(
        string purpose,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(provider);
}
