using System.Net.Http.Json;
using System.Text.Json;
using ReviewPlatform.Server.AI;

namespace ReviewPlatform.Server.Services;

public sealed class OllamaModelMetadataService(IHttpClientFactory httpClientFactory)
{
    public async Task<int> GetContextWindowAsync(
        string model,
        CancellationToken cancellationToken = default)
    {
        try
        {
            using var response = await httpClientFactory.CreateClient("ollama")
                .PostAsJsonAsync(
                    $"{LlmOptions.LocalOllamaBaseUrl}/api/show",
                    new { model },
                    cancellationToken);
            if (!response.IsSuccessStatusCode)
                throw new LlmModelCatalogException(
                    $"'{model}' 모델의 컨텍스트 정보를 불러오지 못했습니다: {(int)response.StatusCode}");
            using var document = JsonDocument.Parse(
                await response.Content.ReadAsStringAsync(cancellationToken));
            if (document.RootElement.TryGetProperty("model_info", out var info))
            {
                var architecture = info.TryGetProperty("general.architecture", out var value)
                    ? value.GetString()
                    : null;
                if (architecture is not null &&
                    info.TryGetProperty($"{architecture}.context_length", out var length) &&
                    length.TryGetInt32(out var tokens) && tokens > 0)
                    return tokens;
                // Some model exporters omit general.architecture.
                foreach (var property in info.EnumerateObject())
                {
                    if (property.Name.EndsWith(".context_length", StringComparison.Ordinal) &&
                        property.Value.TryGetInt32(out tokens) && tokens > 0)
                        return tokens;
                }
            }
            throw new LlmModelCatalogException(
                $"'{model}' 모델의 최대 컨텍스트 크기를 확인하지 못했습니다. 자동 모드를 사용하거나 목록을 새로고침해 주세요.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmModelCatalogException("Ollama 모델 정보 요청 시간이 초과되었습니다.");
        }
        catch (Exception exception) when (exception is HttpRequestException or JsonException)
        {
            throw new LlmModelCatalogException(
                "Ollama 모델 정보를 불러오지 못했습니다.", exception);
        }
    }
}
