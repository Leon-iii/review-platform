using Microsoft.Extensions.Options;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;

namespace ReviewPlatform.Server.AI;

public interface ILlmProviderResolver
{
    Task<ILLMProvider> ResolveAsync(
        string purpose,
        CancellationToken cancellationToken = default);

    async Task<LlmProfileDto> CaptureAsync(string purpose, CancellationToken cancellationToken = default)
    {
        var provider = await ResolveAsync(purpose, cancellationToken);
        return new LlmProfileDto(purpose, purpose, provider.ProviderName,
            provider.ModelName, DateTimeOffset.UtcNow, provider.ContextWindowTokens);
    }

    async Task<ILLMProvider> ResolveSnapshotAsync(LlmProfileDto profile,
        CancellationToken cancellationToken = default)
    {
        var provider = await ResolveAsync(profile.Id, cancellationToken);
        if (provider.ProviderName != profile.Provider || provider.ModelName != profile.Model)
            throw new LlmProviderUnavailableException("작업 시작 시 선택한 모델을 사용할 수 없습니다.");
        return provider;
    }
}

public sealed class RuntimeLlmProviderResolver(
    LlmProfileService profiles,
    ILlmApiKeyStore apiKeyStore,
    IHttpClientFactory httpClientFactory,
    ILoggerFactory loggerFactory,
    DirectPdfTelemetryStore? directPdfTelemetry = null) : ILlmProviderResolver
{
    public async Task<ILLMProvider> ResolveAsync(
        string purpose,
        CancellationToken cancellationToken = default)
    {
        var profile = await profiles.GetActiveProfileAsync(
            purpose,
            cancellationToken);
        return await ResolveSnapshotAsync(profile, cancellationToken);
    }

    public Task<LlmProfileDto> CaptureAsync(string purpose, CancellationToken cancellationToken = default) =>
        profiles.GetActiveProfileAsync(purpose, cancellationToken);

    public async Task<ILLMProvider> ResolveSnapshotAsync(LlmProfileDto profile,
        CancellationToken cancellationToken = default)
    {
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
                options,
                loggerFactory.CreateLogger<OpenAiLlmProvider>(),
                httpClientFactory.CreateClient("openai-direct-pdf"),
                directPdfTelemetry),
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
