using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class OpenAiLlmProviderTests
{
    [Fact]
    public async Task GenerateQuestions_UsesResponsesStructuredOutputs()
    {
        var outputText = JsonSerializer.Serialize(new
        {
            questions = new[]
            {
                new
                {
                    type = "shortAnswer",
                    prompt = "가우스 법칙이 연결하는 두 물리량은?",
                    choices = Array.Empty<object>(),
                    acceptableAnswers = new[] { "전기선속과 내부 전하" },
                    explanation = "폐곡면을 기준으로 두 물리량을 연결한다.",
                    difficulty = 2,
                    sourceIds = Array.Empty<string>()
                }
            }
        });
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new
        {
            status = "completed",
            output = new[]
            {
                new
                {
                    type = "message",
                    content = new[]
                    {
                        new { type = "output_text", text = outputText }
                    }
                }
            }
        }));
        var provider = CreateProvider(handler);

        var questions = await provider.GenerateQuestionsAsync(new QuestionGenerationInput(
            "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.",
            1,
            ["shortAnswer"],
            "전자기학",
            "question-generation-v1"), TestContext.Current.CancellationToken);

        Assert.Single(questions);
        Assert.Equal("shortAnswer", questions[0].Type);
        Assert.Equal("Bearer", handler.AuthorizationScheme);
        Assert.Equal("test-api-key", handler.AuthorizationParameter);
        Assert.Equal("https://api.openai.com/v1/responses", handler.RequestUri);

        using var request = JsonDocument.Parse(handler.RequestBody!);
        var root = request.RootElement;
        Assert.Equal("test-model", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("store").GetBoolean());
        var format = root.GetProperty("text").GetProperty("format");
        Assert.Equal("json_schema", format.GetProperty("type").GetString());
        Assert.True(format.GetProperty("strict").GetBoolean());
        Assert.False(format.GetProperty("schema")
            .GetProperty("additionalProperties").GetBoolean());
        Assert.Contains("가우스 법칙", root.GetProperty("input")[1]
            .GetProperty("content").GetString());
        Assert.DoesNotContain("test-api-key", handler.RequestBody);
    }

    [Fact]
    public async Task MissingApiKey_FailsBeforeSendingRequest()
    {
        var handler = new RecordingHandler(_ => throw new InvalidOperationException());
        var provider = CreateProvider(handler, apiKey: string.Empty);

        var exception = await Assert.ThrowsAsync<LlmProviderUnavailableException>(() =>
            provider.GenerateQuestionsAsync(Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("OPENAI_API_KEY", exception.Message);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task ApiError_ExposesStatusAndCodeWithoutUpstreamMessage()
    {
        var handler = new RecordingHandler(_ => JsonResponse(
            HttpStatusCode.Unauthorized,
            new
            {
                error = new
                {
                    message = "secret upstream detail",
                    code = "invalid_api_key"
                }
            }));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            provider.GenerateQuestionsAsync(Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("401", exception.Message);
        Assert.Contains("invalid_api_key", exception.Message);
        Assert.DoesNotContain("secret upstream detail", exception.Message);
    }

    [Fact]
    public async Task Refusal_IsReturnedAsSafeProviderFailure()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new
        {
            status = "completed",
            output = new[]
            {
                new
                {
                    type = "message",
                    content = new[]
                    {
                        new { type = "refusal", refusal = "private refusal detail" }
                    }
                }
            }
        }));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            provider.GenerateQuestionsAsync(Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("거절", exception.Message);
        Assert.DoesNotContain("private refusal detail", exception.Message);
    }

    private static OpenAiLlmProvider CreateProvider(
        HttpMessageHandler handler,
        string apiKey = "test-api-key")
    {
        return new OpenAiLlmProvider(
            new HttpClient(handler),
            Options.Create(new LlmOptions
            {
                Provider = "openai",
                ApiKey = apiKey,
                Model = "test-model"
            }));
    }

    private static QuestionGenerationInput Input() => new(
        "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.",
        1,
        ["shortAnswer"],
        null,
        "question-generation-v1");

    private static HttpResponseMessage JsonResponse(
        HttpStatusCode statusCode,
        object body)
    {
        return new HttpResponseMessage(statusCode)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(body),
                Encoding.UTF8,
                "application/json")
        };
    }

    private sealed class RecordingHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory)
        : HttpMessageHandler
    {
        public int CallCount { get; private set; }
        public string? RequestUri { get; private set; }
        public string? RequestBody { get; private set; }
        public string? AuthorizationScheme { get; private set; }
        public string? AuthorizationParameter { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount++;
            RequestUri = request.RequestUri?.ToString();
            RequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            AuthorizationScheme = request.Headers.Authorization?.Scheme;
            AuthorizationParameter = request.Headers.Authorization?.Parameter;
            return responseFactory(request);
        }
    }
}
