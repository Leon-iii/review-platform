namespace ReviewPlatform.Server.AI;

public sealed class LlmOptions
{
    public string Provider { get; set; } = "ollama";

    public string ApiKey { get; set; } = string.Empty;

    public string Model { get; set; } = "qwen3:8b";

    public string BaseUrl { get; set; } = "http://127.0.0.1:11434";
}
