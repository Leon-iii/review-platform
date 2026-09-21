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
    IHttpClientFactory httpClientFactory,
    IOptions<LlmOptions> bootstrapOptions,
    ILoggerFactory loggerFactory) : ILlmProviderResolver
{
    public async Task<ILLMProvider> ResolveAsync(
        string purpose,
        CancellationToken cancellationToken = default)
    {
        var profile = await profiles.GetActiveProfileAsync(
            purpose,
            cancellationToken);
        var options = Options.Create(new LlmOptions
        {
            Provider = profile.Provider,
            Model = profile.Model,
            BaseUrl = profile.BaseUrl,
            ApiKey = bootstrapOptions.Value.ApiKey
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
