namespace ReviewPlatform.Server.AI;

public sealed class LlmOptions
{
    public const string LocalOllamaBaseUrl = "http://127.0.0.1:11434";

    public string Provider { get; set; } = "ollama";

    public string ApiKey { get; set; } = string.Empty;

    public string Model { get; set; } = "qwen3-vl:8b-instruct";

    public string BaseUrl { get; set; } = LocalOllamaBaseUrl;

    // null uses the provider's automatic policy; only Ollama accepts an override.
    public int? ContextWindowTokens { get; set; }

    // null leaves the OpenAI API default unchanged; not used by Ollama.
    public string? ReasoningEffort { get; set; }
}
