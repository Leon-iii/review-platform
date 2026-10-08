using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class ConceptRevisionBudget
{
    // Advisory only. Never used as max_output_tokens or to truncate an answer.
    public const int OutputSafetyThresholdTokens = 64_000;
    public static long EstimateVisibleOutput(ConceptRevisionInput input)
    {
        var selected = input.EditableConceptIds.ToHashSet(StringComparer.Ordinal);
        var characters = input.Concepts.Where(item => selected.Contains(item.Id))
            .Sum(item => (long)item.Title.Length + item.Content.Length);
        // Rough Korean/JSON allowance, not a tokenizer or a quality guarantee.
        return characters + 2_000 + selected.Count * 400L + (input.AllowAdditions ? 8_000 : 0);
    }
}

public sealed partial class OpenAiLlmProvider
{
    private async Task CheckRevisionInputAsync(ConceptRevisionInput input,
        Dictionary<string, object?> payload, CancellationToken token)
    {
        var estimate = ConceptRevisionBudget.EstimateVisibleOutput(input);
        if (estimate > ConceptRevisionBudget.OutputSafetyThresholdTokens)
            logger?.LogWarning("Concept revision advisory output warning. Model={Model} EstimatedVisibleTokens={Estimate} SafetyThreshold={Threshold} ActualApiLimit={Limit}",
                settings.Model, estimate, ConceptRevisionBudget.OutputSafetyThresholdTokens, payload["max_output_tokens"]);
        if (input.Source is null) return;
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/responses/input_tokens");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", settings.ApiKey);
        var countPayload = new Dictionary<string, object?>(payload);
        countPayload.Remove("max_output_tokens");
        countPayload.Remove("store");
        countPayload.Remove("reasoning");
        request.Content = new StringContent(JsonSerializer.Serialize(countPayload, JsonOptions), Encoding.UTF8, "application/json");
        using var response = await (directPdfClient ?? httpClient).SendAsync(request, token);
        var body = await response.Content.ReadAsStringAsync(token);
        if (!response.IsSuccessStatusCode)
            throw new LlmProviderRequestException(ToSafeApiError(response.StatusCode, body, "개념 수정 입력 점검"));
        long tokens;
        try
        {
            using var count = JsonDocument.Parse(body);
            tokens = count.RootElement.GetProperty("input_tokens").GetInt64();
            if (tokens < 1) throw new JsonException("Invalid input token count.");
        }
        catch (Exception exception) when (exception is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        { throw new LlmProviderRequestException("개념 수정 입력 토큰을 확인하지 못했습니다. 다시 시도해 주세요.", exception); }
        if (PdfContextTokens is int context)
        {
            var budget = Math.Min((long)(int)payload["max_output_tokens"]!, context - tokens - 8192);
            if (budget < 16)
                throw new LlmProviderRequestException("개념 수정 입력이 모델 컨텍스트 한도에 도달했습니다. 선택한 개념을 줄여 주세요.");
            payload["max_output_tokens"] = (int)budget;
        }
        // For models without registered context limits, do not guess: upstream validation
        // remains authoritative and failures are reported rather than dropping source pages.
        logger?.LogInformation("Concept revision input checked. Model={Model} SourcePages={Pages} InputTokens={Tokens} OutputLimit={Limit} ContextLimitKnown={Known}",
            settings.Model, input.Source.OriginalPages.Count, tokens, payload["max_output_tokens"], PdfContextTokens is not null);
    }

    private void LogRevisionUsage(string body, long duration, object? limit)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            long? Number(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object &&
                element.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? number : null;
            var usage = root.TryGetProperty("usage", out var data) ? data : default;
            var details = usage.ValueKind == JsonValueKind.Object && usage.TryGetProperty("output_tokens_details", out var tokens) ? tokens : default;
            logger?.LogInformation("Concept revision usage. Model={Model} Status={Status} InputTokens={Input} OutputTokens={Output} ReasoningTokens={Reasoning} OutputLimit={Limit} DurationMs={Duration}",
                settings.Model, root.TryGetProperty("status", out var status) ? status.GetString() : "failed",
                Number(usage, "input_tokens"), Number(usage, "output_tokens"), Number(details, "reasoning_tokens"), limit, duration);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException) { }
    }
}
