using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public sealed class OpenAiLlmProvider(
    HttpClient httpClient,
    IOptions<LlmOptions> options) : ILLMProvider
{
    private static readonly Uri ResponsesEndpoint = new(
        "https://api.openai.com/v1/responses");
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };
    private readonly LlmOptions settings = options.Value;

    public string ProviderName => "openai";

    public string ModelName => settings.Model;

    public async Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
        QuestionGenerationInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        using var request = new HttpRequestMessage(HttpMethod.Post, ResponsesEndpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            settings.ApiKey);
        request.Content = new StringContent(
            JsonSerializer.Serialize(BuildRequest(input), JsonOptions),
            Encoding.UTF8,
            "application/json");

        HttpResponseMessage response;
        try
        {
            response = await httpClient.SendAsync(request, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmProviderRequestException(
                "OpenAI 요청 시간이 초과되었습니다.");
        }
        catch (HttpRequestException exception)
        {
            throw new LlmProviderRequestException(
                "OpenAI API에 연결하지 못했습니다.",
                exception);
        }

        using (response)
        {
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode, responseBody));
            }
            return ParseResponse(responseBody);
        }
    }

    public async Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(
        ConceptExtractionInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        using var request = new HttpRequestMessage(HttpMethod.Post, ResponsesEndpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            settings.ApiKey);
        request.Content = new StringContent(
            JsonSerializer.Serialize(BuildConceptRequest(input), JsonOptions),
            Encoding.UTF8,
            "application/json");

        HttpResponseMessage response;
        try
        {
            response = await httpClient.SendAsync(request, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmProviderRequestException(
                "OpenAI 개념 추출 요청 시간이 초과되었습니다.");
        }
        catch (HttpRequestException exception)
        {
            throw new LlmProviderRequestException(
                "OpenAI API에 연결하지 못했습니다.",
                exception);
        }

        using (response)
        {
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode, responseBody));
            }
            return ParseConceptResponse(responseBody);
        }
    }

    public async Task<IReadOnlyList<GeneratedConceptRevision>> ReviseConceptsAsync(
        ConceptRevisionInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        using var request = new HttpRequestMessage(HttpMethod.Post, ResponsesEndpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            settings.ApiKey);
        request.Content = new StringContent(
            JsonSerializer.Serialize(BuildConceptRevisionRequest(input), JsonOptions),
            Encoding.UTF8,
            "application/json");

        HttpResponseMessage response;
        try
        {
            response = await httpClient.SendAsync(request, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmProviderRequestException(
                "OpenAI 개념 수정 요청 시간이 초과되었습니다.");
        }
        catch (HttpRequestException exception)
        {
            throw new LlmProviderRequestException(
                "OpenAI API에 연결하지 못했습니다.",
                exception);
        }

        using (response)
        {
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode, responseBody));
            }
            return ParseConceptRevisionResponse(responseBody);
        }
    }

    private void ValidateConfiguration()
    {
        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            throw new LlmProviderUnavailableException(
                "OPENAI_API_KEY가 설정되지 않았습니다.");
        }
        if (string.IsNullOrWhiteSpace(settings.Model))
        {
            throw new LlmProviderUnavailableException(
                "OpenAI 모델이 설정되지 않았습니다.");
        }
        if (OpenAiModelCapabilitiesRegistry.IsKnownIncompatible(settings.Model))
            throw new LlmProviderUnavailableException(
                "선택한 OpenAI 모델은 이 앱에서 필요한 구조화 출력을 지원하지 않습니다. 다른 모델을 선택해 주세요.");
        if (settings.ReasoningEffort is not null &&
            !OpenAiModelCapabilitiesRegistry.SupportsEffort(
                settings.Model, settings.ReasoningEffort))
            throw new LlmProviderUnavailableException(
                "선택한 OpenAI 모델에서 지원하지 않는 추론 수준입니다. 자동 모드로 변경해 주세요.");
    }

    private Dictionary<string, object?> ApplyReasoning(Dictionary<string, object?> request)
    {
        var capabilities = OpenAiModelCapabilitiesRegistry.Get(settings.Model);
        if (settings.ReasoningEffort is not null)
            request["reasoning"] = new { effort = settings.ReasoningEffort };
        // Reasoning and visible JSON share max_output_tokens. Reserve room so a
        // small edit cannot exhaust its entire budget before emitting any JSON.
        var effort = settings.ReasoningEffort ?? capabilities.DefaultReasoningEffort;
        var outputBudget = (int)request["max_output_tokens"]!;
        if (capabilities.SupportsReasoning && effort != "none")
        {
            var reserve = effort is "high" or "xhigh" or "max" ? 48_000 : 24_000;
            outputBudget = Math.Max(25_000, outputBudget + reserve);
        }
        request["max_output_tokens"] = Math.Min(outputBudget,
            capabilities.MaxOutputTokens ?? outputBudget);
        return request;
    }

    private object BuildRequest(QuestionGenerationInput input)
    {
        return ApplyReasoning(new Dictionary<string, object?>
        {
            ["model"] = settings.Model,
            ["store"] = false,
            ["max_output_tokens"] = Math.Min(
                16_000,
                800 + input.QuestionBudgetForTokenLimit * 700),
            ["input"] = new object[]
            {
                new
                {
                    role = "system",
                    content = QuestionGenerationPrompt.SystemPrompt
                },
                new
                {
                    role = "user",
                    content = QuestionGenerationPrompt.BuildUserPrompt(input)
                }
            },
            ["text"] = new
            {
                format = new Dictionary<string, object?>
                {
                    ["type"] = "json_schema",
                    ["name"] = "review_question_generation",
                    ["description"] = "Draft review questions grounded in the supplied source",
                    ["strict"] = true,
                    ["schema"] = QuestionGenerationPrompt.BuildQuestionSchema(input)
                }
            }
        });
    }

    private object BuildConceptRequest(ConceptExtractionInput input)
    {
        return ApplyReasoning(new Dictionary<string, object?>
        {
            ["model"] = settings.Model,
            ["store"] = false,
            ["max_output_tokens"] = 8_000,
            ["input"] = new object[]
            {
                new
                {
                    role = "system",
                    content = ConceptExtractionPrompt.SystemPrompt
                },
                new
                {
                    role = "user",
                    content = ConceptExtractionPrompt.BuildUserPrompt(input)
                }
            },
            ["text"] = new
            {
                format = new Dictionary<string, object?>
                {
                    ["type"] = "json_schema",
                    ["name"] = "review_concept_extraction",
                    ["description"] = "Held study concepts grounded in PDF pages",
                    ["strict"] = true,
                    ["schema"] = ConceptExtractionPrompt.BuildSchema(input)
                }
            }
        });
    }

    private object BuildConceptRevisionRequest(ConceptRevisionInput input)
    {
        return ApplyReasoning(new Dictionary<string, object?>
        {
            ["model"] = settings.Model,
            ["store"] = false,
            ["max_output_tokens"] = Math.Min(
                12_000,
                500 + input.EditableConceptIds.Count * 650),
            ["input"] = new object[]
            {
                new
                {
                    role = "system",
                    content = ConceptRevisionPrompt.SystemPrompt
                },
                new
                {
                    role = "user",
                    content = ConceptRevisionPrompt.BuildUserPrompt(input)
                }
            },
            ["text"] = new
            {
                format = new Dictionary<string, object?>
                {
                    ["type"] = "json_schema",
                    ["name"] = "review_concept_revision",
                    ["description"] = "Requested revisions to existing PDF concepts",
                    ["strict"] = true,
                    ["schema"] = ConceptRevisionPrompt.BuildSchema(input)
                }
            }
        });
    }

    private static IReadOnlyList<GeneratedQuestionDraft> ParseResponse(string body)
    {
        try
        {
            var outputText = ExtractOutputText(body, "문제 생성");
            var envelope = JsonSerializer.Deserialize<QuestionEnvelope>(
                outputText,
                JsonOptions);
            return envelope?.Questions ?? throw new LlmProviderRequestException(
                "OpenAI의 구조화 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "OpenAI의 구조화 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private static IReadOnlyList<GeneratedConceptDraft> ParseConceptResponse(
        string body)
    {
        try
        {
            var outputText = ExtractOutputText(body, "개념 추출");
            var envelope = JsonSerializer.Deserialize<ConceptEnvelope>(
                outputText,
                JsonOptions);
            return envelope?.Concepts ?? throw new LlmProviderRequestException(
                "OpenAI의 구조화된 개념 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "OpenAI의 구조화된 개념 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private static IReadOnlyList<GeneratedConceptRevision>
        ParseConceptRevisionResponse(string body)
    {
        try
        {
            var outputText = ExtractOutputText(body, "개념 수정");
            var envelope = JsonSerializer.Deserialize<ConceptRevisionEnvelope>(
                outputText,
                JsonOptions);
            return envelope?.Revisions ?? throw new LlmProviderRequestException(
                "OpenAI의 구조화된 개념 수정 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "OpenAI의 구조화된 개념 수정 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private static string ExtractOutputText(string body, string operation)
    {
        using var document = JsonDocument.Parse(body);
        var root = document.RootElement;
        if (root.TryGetProperty("status", out var status) &&
            status.GetString() != "completed")
        {
            if (root.TryGetProperty("incomplete_details", out var details) &&
                details.ValueKind == JsonValueKind.Object &&
                details.TryGetProperty("reason", out var reason) &&
                reason.GetString() == "max_output_tokens")
                throw new LlmProviderRequestException(
                    $"OpenAI {operation}의 추론·출력 토큰 한도에 도달했습니다. 추론 수준을 낮추거나 작업 범위를 줄여 주세요.");
            throw new LlmProviderRequestException(
                $"OpenAI가 {operation}을 완료하지 못했습니다.");
        }

        string? outputText = null;
        string? refusal = null;
        if (root.TryGetProperty("output", out var output) &&
            output.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in output.EnumerateArray())
            {
                if (!item.TryGetProperty("content", out var content) ||
                    content.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }
                foreach (var part in content.EnumerateArray())
                {
                    var type = part.TryGetProperty("type", out var typeElement)
                        ? typeElement.GetString()
                        : null;
                    if (type == "output_text" &&
                        part.TryGetProperty("text", out var text))
                    {
                        outputText = text.GetString();
                    }
                    else if (type == "refusal" &&
                        part.TryGetProperty("refusal", out var refusalElement))
                    {
                        refusal = refusalElement.GetString();
                    }
                }
            }
        }

        if (!string.IsNullOrWhiteSpace(refusal))
        {
            throw new LlmProviderRequestException(
                $"OpenAI가 {operation} 요청을 거절했습니다.");
        }
        if (string.IsNullOrWhiteSpace(outputText))
        {
            throw new LlmProviderRequestException(
                $"OpenAI 응답에 구조화된 {operation} 결과가 없습니다.");
        }
        return outputText;
    }

    private static string ToSafeApiError(
        System.Net.HttpStatusCode statusCode,
        string responseBody)
    {
        string? errorCode = null;
        try
        {
            using var document = JsonDocument.Parse(responseBody);
            if (document.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("code", out var code))
            {
                errorCode = code.GetString();
            }
        }
        catch (JsonException)
        {
            // Do not expose an untrusted upstream response body.
        }

        var suffix = string.IsNullOrWhiteSpace(errorCode)
            ? string.Empty
            : $" ({errorCode})";
        return $"OpenAI API 요청이 실패했습니다: {(int)statusCode}{suffix}";
    }

    private sealed record QuestionEnvelope(
        IReadOnlyList<GeneratedQuestionDraft>? Questions);

    private sealed record ConceptEnvelope(
        IReadOnlyList<GeneratedConceptDraft>? Concepts);

    private sealed record ConceptRevisionEnvelope(
        IReadOnlyList<GeneratedConceptRevision>? Revisions);
}
