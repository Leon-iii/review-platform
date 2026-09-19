using Microsoft.Extensions.Options;

namespace ReviewPlatform.Server.AI;

public sealed class LlmProviderSelector(
    OpenAiLlmProvider openAi,
    OllamaLlmProvider ollama,
    IOptions<LlmOptions> options)
{
    public ILLMProvider Select()
    {
        var provider = options.Value.Provider?.Trim() ?? string.Empty;
        return provider.ToLowerInvariant() switch
        {
            "openai" => openAi,
            "ollama" => ollama,
            _ => throw new LlmProviderUnavailableException(
                $"지원하지 않는 LLM Provider입니다: '{provider}'. " +
                "Llm__Provider를 openai 또는 ollama로 설정해 주세요.")
        };
    }
}
