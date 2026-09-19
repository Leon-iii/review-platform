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
    }

    private object BuildRequest(QuestionGenerationInput input)
    {
        return new Dictionary<string, object?>
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
        };
    }

    private static IReadOnlyList<GeneratedQuestionDraft> ParseResponse(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("status", out var status) &&
                status.GetString() != "completed")
            {
                throw new LlmProviderRequestException(
                    "OpenAI가 문제 생성을 완료하지 못했습니다.");
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
                    "OpenAI가 해당 문제 생성 요청을 거절했습니다.");
            }
            if (string.IsNullOrWhiteSpace(outputText))
            {
                throw new LlmProviderRequestException(
                    "OpenAI 응답에 구조화된 문제가 없습니다.");
            }

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
}
