using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public sealed class OllamaLlmProvider(
    HttpClient httpClient,
    IOptions<LlmOptions> options,
    ILogger<OllamaLlmProvider> logger) : ILLMProvider
{
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };
    private readonly LlmOptions settings = options.Value;

    public string ProviderName => "ollama";

    public string ModelName => settings.Model;

    public async Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
        QuestionGenerationInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        var stopwatch = Stopwatch.StartNew();
        logger.LogInformation(
            "LLM operation started. Provider={Provider} Model={Model} Operation={Operation}",
            ProviderName,
            ModelName,
            "question-generation");

        try
        {
            await EnsureModelInstalledAsync(cancellationToken);
            var schema = QuestionGenerationPrompt.BuildQuestionSchema(input);
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                BuildEndpoint("api/chat"));
            request.Content = new StringContent(
                JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["model"] = settings.Model,
                    ["messages"] = new object[]
                    {
                        new
                        {
                            role = "system",
                            content = QuestionGenerationPrompt.SystemPrompt
                        },
                        new
                        {
                            role = "user",
                            content = $"""
                                {QuestionGenerationPrompt.BuildUserPrompt(input)}

                                Return JSON matching this schema exactly:
                                {schema.ToJsonString()}
                                """
                        }
                    },
                    ["stream"] = false,
                    ["format"] = schema,
                    ["options"] = new
                    {
                        temperature = 0,
                        num_predict = Math.Min(
                            16_000,
                            800 + input.QuestionBudgetForTokenLimit * 700)
                    }
                }, JsonOptions),
                Encoding.UTF8,
                "application/json");

            using var response = await SendAsync(request, cancellationToken);
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode));
            }

            var questions = ParseResponse(responseBody);
            logger.LogInformation(
                "LLM response received and parsed. Provider={Provider} Model={Model} " +
                "Operation={Operation} OutputCount={OutputCount} DurationMs={DurationMs}",
                ProviderName,
                ModelName,
                "question-generation",
                questions.Count,
                stopwatch.ElapsedMilliseconds);
            return questions;
        }
        catch (Exception exception) when (
            exception is LlmProviderUnavailableException or
            LlmProviderRequestException)
        {
            logger.LogWarning(
                "LLM operation failed. Provider={Provider} Model={Model} Operation={Operation} DurationMs={DurationMs} Failure={Failure}",
                ProviderName,
                ModelName,
                "question-generation",
                stopwatch.ElapsedMilliseconds,
                exception.GetType().Name);
            throw;
        }
    }

    public async Task<OllamaStatus> CheckStatusAsync(
        CancellationToken cancellationToken = default)
    {
        try
        {
            ValidateConfiguration();
            var models = await GetInstalledModelsAsync(cancellationToken);
            return new OllamaStatus(
                true,
                models.Contains(settings.Model),
                settings.Model);
        }
        catch (LlmProviderUnavailableException)
        {
            return new OllamaStatus(false, false, settings.Model);
        }
        catch (LlmProviderRequestException)
        {
            return new OllamaStatus(false, false, settings.Model);
        }
    }

    private async Task EnsureModelInstalledAsync(
        CancellationToken cancellationToken)
    {
        var models = await GetInstalledModelsAsync(cancellationToken);
        if (!models.Contains(settings.Model))
        {
            throw new LlmProviderUnavailableException(
                $"Configured Ollama model '{settings.Model}' is not installed.");
        }
    }

    private async Task<HashSet<string>> GetInstalledModelsAsync(
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            BuildEndpoint("api/tags"));
        using var response = await SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new LlmProviderRequestException(
                $"Ollama 모델 목록 요청이 실패했습니다: {(int)response.StatusCode}");
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<OllamaTagsResponse>(
                responseBody,
                JsonOptions);
            if (envelope?.Models is null)
            {
                throw new JsonException("Missing models array.");
            }
            return envelope.Models
                .Select(model => model.Name ?? model.Model)
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Select(name => name!)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama 모델 목록 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        try
        {
            return await httpClient.SendAsync(request, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmProviderRequestException(
                "Ollama 요청 시간이 초과되었습니다.");
        }
        catch (HttpRequestException exception)
        {
            throw new LlmProviderUnavailableException(
                "Ollama에 연결하지 못했습니다. Ollama가 실행 중인지 확인해 주세요.",
                exception);
        }
    }

    private IReadOnlyList<GeneratedQuestionDraft> ParseResponse(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("done", out var done) &&
                done.ValueKind == JsonValueKind.False)
            {
                throw new LlmProviderRequestException(
                    "Ollama가 문제 생성을 완료하지 못했습니다.");
            }
            if (!root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(content.GetString()))
            {
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 문제가 없습니다.");
            }

            var envelope = JsonSerializer.Deserialize<QuestionEnvelope>(
                content.GetString()!,
                JsonOptions);
            return envelope?.Questions ?? throw new LlmProviderRequestException(
                "Ollama의 구조화 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama의 구조화 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private void ValidateConfiguration()
    {
        if (string.IsNullOrWhiteSpace(settings.Model))
        {
            throw new LlmProviderUnavailableException(
                "Ollama 모델이 설정되지 않았습니다.");
        }
        if (!Uri.TryCreate(settings.BaseUrl, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            throw new LlmProviderUnavailableException(
                "Llm__BaseUrl에 올바른 Ollama HTTP 주소를 설정해 주세요.");
        }
    }

    private Uri BuildEndpoint(string path)
    {
        var baseUri = new Uri(settings.BaseUrl.Trim().TrimEnd('/') + "/");
        return new Uri(baseUri, path);
    }

    private static string ToSafeApiError(HttpStatusCode statusCode) =>
        $"Ollama API 요청이 실패했습니다: {(int)statusCode}";

    private sealed record OllamaTagsResponse(
        IReadOnlyList<OllamaModelInfo>? Models);

    private sealed record OllamaModelInfo(string? Name, string? Model);

    private sealed record QuestionEnvelope(
        IReadOnlyList<GeneratedQuestionDraft>? Questions);
}

public sealed record OllamaStatus(
    bool Reachable,
    bool ModelInstalled,
    string Model);
