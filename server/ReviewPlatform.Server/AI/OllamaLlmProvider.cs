using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;

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

    public int MaximumQuestionsPerRequest => settings.MaximumQuestionsPerRequest;

    public int? ContextWindowTokens => settings.ContextWindowTokens;

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
                            content = QuestionGenerationPrompt.GetSystemPrompt(input)
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
                    ["options"] = BuildGenerationOptions(Math.Min(
                            16_000,
                            800 + input.QuestionBudgetForTokenLimit * 700))
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

    public async Task<IReadOnlyList<GeneratedConceptRevision>> ReviseConceptsAsync(
        ConceptRevisionInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        var stopwatch = Stopwatch.StartNew();
        logger.LogInformation(
            "LLM operation started. Provider={Provider} Model={Model} Operation={Operation}",
            ProviderName,
            ModelName,
            "concept-revision");
        try
        {
            await EnsureModelInstalledAsync(cancellationToken);
            var schema = ConceptRevisionPrompt.BuildSchema(input);
            var userPrompt = ConceptRevisionPrompt.BuildUserPrompt(input);
            var outputTokenBudget = Math.Min(
                6_000,
                2_048 + (input.EditableConceptIds.Count + (input.AllowAdditions ? 4 : 0)) * 384);
            var contextWindow = SelectRevisionContextWindow(
                ConceptRevisionPrompt.SystemPrompt.Length + userPrompt.Length,
                outputTokenBudget);
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
                            content = ConceptRevisionPrompt.SystemPrompt
                        },
                        new
                        {
                            role = "user",
                            content = userPrompt
                        }
                    },
                    ["stream"] = false,
                    ["think"] = false,
                    ["format"] = schema,
                    ["keep_alive"] = "10m",
                    ["options"] = BuildGenerationOptions(
                        outputTokenBudget, contextWindow)
                }, JsonOptions),
                Encoding.UTF8,
                "application/json");

            using var response = await SendAsync(request, cancellationToken);
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                LogOllamaApiFailure(
                    response.StatusCode,
                    responseBody,
                    "concept-revision",
                    0);
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode, responseBody));
            }
            var revisions = ParseConceptRevisionResponse(responseBody);
            logger.LogInformation(
                "LLM response received and parsed. Provider={Provider} Model={Model} " +
                "Operation={Operation} OutputCount={OutputCount} DurationMs={DurationMs}",
                ProviderName,
                ModelName,
                "concept-revision",
                revisions.Count,
                stopwatch.ElapsedMilliseconds);
            return revisions;
        }
        catch (Exception exception) when (
            exception is LlmProviderUnavailableException or
            LlmProviderRequestException)
        {
            logger.LogWarning(
                "LLM operation failed. Provider={Provider} Model={Model} " +
                "Operation={Operation} DurationMs={DurationMs} Failure={Failure}",
                ProviderName,
                ModelName,
                "concept-revision",
                stopwatch.ElapsedMilliseconds,
                exception.GetType().Name);
            throw;
        }
    }

    private void LogOllamaApiFailure(
        HttpStatusCode statusCode,
        string responseBody,
        string operation,
        int pageNumber)
    {
        logger.LogWarning(
            "Ollama API returned an error. Provider={Provider} Model={Model} " +
            "Operation={Operation} PageNumber={PageNumber} StatusCode={StatusCode} " +
            "ResponseError={ResponseError}",
            ProviderName,
            ModelName,
            operation,
            pageNumber,
            (int)statusCode,
            ExtractResponseError(responseBody) ?? "unavailable");
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

    private IReadOnlyList<GeneratedConceptRevision> ParseConceptRevisionResponse(
        string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("done", out var done) &&
                done.ValueKind == JsonValueKind.False)
            {
                throw new LlmProviderRequestException(
                    "Ollama가 개념 수정을 완료하지 못했습니다.");
            }
            if (!root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(content.GetString()))
            {
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 개념 수정안이 없습니다.");
            }
            var envelope = JsonSerializer.Deserialize<ConceptChangeEnvelope>(
                content.GetString()!,
                JsonOptions);
            return envelope?.Flatten() ?? throw new LlmProviderRequestException(
                "Ollama의 구조화된 개념 수정 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama의 구조화된 개념 수정 응답을 해석하지 못했습니다.",
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

    private Dictionary<string, object> BuildGenerationOptions(
        int outputTokenBudget,
        int? automaticContextWindow = null)
    {
        var contextWindow = settings.ContextWindowTokens ?? automaticContextWindow;
        var options = new Dictionary<string, object>
        {
            ["temperature"] = 0,
            // Reserve room for input when a small manual window is selected.
            ["num_predict"] = settings.ContextWindowTokens is int manualWindow
                ? Math.Min(outputTokenBudget, manualWindow / 2)
                : outputTokenBudget
        };
        if (contextWindow is not null) options["num_ctx"] = contextWindow.Value;
        return options;
    }

    private static int SelectRevisionContextWindow(
        int inputCharacterCount,
        int outputTokenBudget)
    {
        // Korean and JSON commonly use more tokens per character than plain
        // English. This intentionally conservative estimate still avoids the
        // large KV-cache cost of forcing 32K for every small edit request.
        var estimatedInputTokens = (inputCharacterCount + 1) / 2;
        var requiredTokens = estimatedInputTokens + outputTokenBudget;
        if (requiredTokens <= 8_192) return 8_192;
        if (requiredTokens <= 16_384) return 16_384;
        return 32_768;
    }

    private static string ToSafeApiError(HttpStatusCode statusCode) =>
        ToSafeApiError(statusCode, string.Empty);

    private static string ToSafeApiError(
        HttpStatusCode statusCode,
        string responseBody)
    {
        var error = ExtractResponseError(responseBody);
        if (error?.Contains("memory", StringComparison.OrdinalIgnoreCase) == true ||
            error?.Contains("CUDA", StringComparison.OrdinalIgnoreCase) == true)
        {
            return "Ollama가 모델을 실행할 메모리가 부족합니다. " +
                "다른 GPU 작업을 종료한 뒤 다시 시도해 주세요.";
        }
        if (statusCode == HttpStatusCode.InternalServerError)
        {
            return "Ollama가 내부 오류를 반환했습니다. " +
                "서버 로그를 확인해 주세요. (500)";
        }
        return $"Ollama API 요청이 실패했습니다: {(int)statusCode}";
    }

    private static string? ExtractResponseError(string responseBody)
    {
        try
        {
            using var document = JsonDocument.Parse(responseBody);
            if (!document.RootElement.TryGetProperty("error", out var error) ||
                error.ValueKind != JsonValueKind.String)
            {
                return null;
            }
            var value = error.GetString()?.Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (string.IsNullOrWhiteSpace(value)) return null;
            return value.Length <= 1_000 ? value : value[..1_000];
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private sealed record OllamaTagsResponse(
        IReadOnlyList<OllamaModelInfo>? Models);

    private sealed record OllamaModelInfo(string? Name, string? Model);

    private sealed record QuestionEnvelope(
        IReadOnlyList<GeneratedQuestionDraft>? Questions);

}

public sealed record OllamaStatus(bool Reachable, bool ModelInstalled, string Model);
