using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public sealed class LlmModelCatalogService(
    IHttpClientFactory httpClientFactory,
    IOptions<LlmOptions> options)
{
    private static readonly Uri OpenAiModelsEndpoint = new(
        "https://api.openai.com/v1/models");

    public async Task<LlmModelCatalogResponse> GetModelsAsync(
        string? provider,
        CancellationToken cancellationToken = default)
    {
        var normalized = provider?.Trim().ToLowerInvariant();
        var models = normalized switch
        {
            "ollama" => await GetOllamaModelsAsync(cancellationToken),
            "openai" => await GetOpenAiModelsAsync(cancellationToken),
            _ => throw new LlmModelCatalogException(
                "모델 목록 Provider는 ollama 또는 openai여야 합니다.")
        };
        return new LlmModelCatalogResponse(
            normalized,
            models,
            DateTimeOffset.UtcNow);
    }

    private async Task<IReadOnlyList<string>> GetOllamaModelsAsync(
        CancellationToken cancellationToken)
    {
        var endpoint = new Uri($"{LlmOptions.LocalOllamaBaseUrl}/api/tags");
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        using var response = await SendAsync(
            httpClientFactory.CreateClient("ollama"),
            request,
            "서버 컴퓨터의 Ollama에 연결하지 못했습니다.",
            cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new LlmModelCatalogException(
                $"Ollama 모델 목록 요청이 실패했습니다: {(int)response.StatusCode}");
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            return document.RootElement.GetProperty("models")
                .EnumerateArray()
                .Select(item => item.TryGetProperty("name", out var name)
                    ? name.GetString()?.Trim()
                    : null)
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Select(name => name!)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch (Exception exception) when (
            exception is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new LlmModelCatalogException(
                "Ollama 모델 목록 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private async Task<IReadOnlyList<string>> GetOpenAiModelsAsync(
        CancellationToken cancellationToken)
    {
        var apiKey = options.Value.ApiKey?.Trim() ?? string.Empty;
        if (apiKey.Length == 0)
        {
            throw new LlmModelCatalogException(
                "OPENAI_API_KEY가 서버에 설정되지 않았습니다.");
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, OpenAiModelsEndpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        using var response = await SendAsync(
            httpClientFactory.CreateClient("openai"),
            request,
            "OpenAI 모델 목록 API에 연결하지 못했습니다.",
            cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new LlmModelCatalogException(
                $"OpenAI 모델 목록 요청이 실패했습니다: {(int)response.StatusCode}");
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            return document.RootElement.GetProperty("data")
                .EnumerateArray()
                .Select(item => item.TryGetProperty("id", out var id)
                    ? id.GetString()?.Trim()
                    : null)
                .Where(id => id is not null && IsSupportedOpenAiModel(id))
                .Select(id => id!)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(id => id, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch (Exception exception) when (
            exception is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new LlmModelCatalogException(
                "OpenAI 모델 목록 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    internal static bool IsSupportedOpenAiModel(string id)
    {
        var normalized = id.ToLowerInvariant();
        var baseModel = normalized.StartsWith("ft:", StringComparison.Ordinal)
            ? normalized[3..]
            : normalized;
        var isLegacyGpt =
            baseModel.StartsWith("gpt-3", StringComparison.Ordinal) ||
            baseModel.Equals("gpt-4", StringComparison.Ordinal) ||
            baseModel.StartsWith("gpt-4-", StringComparison.Ordinal);
        var isGptFamily =
            baseModel.StartsWith("gpt-", StringComparison.Ordinal) &&
            !isLegacyGpt;
        var isReasoningFamily =
            baseModel.Length >= 2 &&
            baseModel[0] == 'o' &&
            char.IsAsciiDigit(baseModel[1]);
        var supportedFamily = isGptFamily || isReasoningFamily;
        if (!supportedFamily) return false;

        string[] incompatibleKinds =
        [
            "audio",
            "realtime",
            "live",
            "transcribe",
            "tts",
            "image",
            "moderation",
            "search-preview"
        ];
        return incompatibleKinds.All(kind =>
            !baseModel.Contains(kind, StringComparison.Ordinal));
    }

    private static async Task<HttpResponseMessage> SendAsync(
        HttpClient client,
        HttpRequestMessage request,
        string connectionError,
        CancellationToken cancellationToken)
    {
        try
        {
            return await client.SendAsync(request, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmModelCatalogException("모델 목록 요청 시간이 초과되었습니다.");
        }
        catch (HttpRequestException exception)
        {
            throw new LlmModelCatalogException(connectionError, exception);
        }
    }
}

public sealed class LlmModelCatalogException(string message, Exception? inner = null)
    : Exception(message, inner);
