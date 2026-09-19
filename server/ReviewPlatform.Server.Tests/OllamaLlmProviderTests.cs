using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class OllamaLlmProviderTests
{
    [Fact]
    public async Task GenerateQuestions_UsesNativeChatSchemaAndIgnoresThinking()
    {
        var generatedJson = JsonSerializer.Serialize(new
        {
            questions = new[]
            {
                new
                {
                    type = "shortAnswer",
                    prompt = "가우스 법칙이 연결하는 두 물리량은?",
                    choices = Array.Empty<object>(),
                    acceptableAnswers = new[] { "전기선속과 내부 전하" },
                    explanation = "SOURCE에 명시된 두 물리량이다.",
                    difficulty = 2,
                    sourceIds = new[] { "전자기학" }
                }
            }
        });
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[]
                    {
                        new { name = "qwen3:8b", model = "qwen3:8b" }
                    }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    model = "qwen3:8b",
                    message = new
                    {
                        role = "assistant",
                        thinking = "저장하거나 노출하면 안 되는 추론",
                        content = generatedJson
                    },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var questions = await provider.GenerateQuestionsAsync(
            Input(),
            TestContext.Current.CancellationToken);

        var question = Assert.Single(questions);
        Assert.Equal("shortAnswer", question.Type);
        Assert.Equal("전기선속과 내부 전하", Assert.Single(
            question.AcceptableAnswers));
        Assert.Equal(2, handler.Requests.Count);
        Assert.All(handler.Requests, request => Assert.Null(request.Authorization));

        var chatRequest = Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
        using var body = JsonDocument.Parse(chatRequest.Body!);
        var root = body.RootElement;
        Assert.Equal("qwen3:8b", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("stream").GetBoolean());
        Assert.Equal("object", root.GetProperty("format")
            .GetProperty("type").GetString());
        Assert.Equal(1, root.GetProperty("format")
            .GetProperty("properties")
            .GetProperty("questions")
            .GetProperty("minItems").GetInt32());
        Assert.Contains("가우스 법칙", root.GetProperty("messages")[1]
            .GetProperty("content").GetString());
        Assert.DoesNotContain("추론", JsonSerializer.Serialize(questions));
    }

    [Fact]
    public async Task MissingModel_ReturnsClearErrorWithoutChatRequest()
    {
        var handler = new RecordingHandler(_ => JsonResponse(
            HttpStatusCode.OK,
            new
            {
                models = new[] { new { name = "other:latest" } }
            }));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderUnavailableException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("qwen3:8b", exception.Message);
        Assert.Contains("not installed", exception.Message);
        Assert.Single(handler.Requests);
        Assert.Equal("/api/tags", handler.Requests[0].Path);
    }

    [Fact]
    public async Task OllamaUnavailable_ReturnsSafeConnectionError()
    {
        var handler = new RecordingHandler(_ =>
            throw new HttpRequestException("private network detail"));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderUnavailableException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("Ollama에 연결", exception.Message);
        Assert.DoesNotContain("private network detail", exception.Message);
    }

    [Fact]
    public async Task RequestTimeout_ReturnsSafeTimeoutError()
    {
        var handler = new RecordingHandler(_ =>
            throw new OperationCanceledException("private timeout detail"));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("시간이 초과", exception.Message);
        Assert.DoesNotContain("private timeout detail", exception.Message);
    }

    [Fact]
    public async Task InvalidMessageContent_ReturnsStructuredResponseError()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/tags"
                ? JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        role = "assistant",
                        content = "not-json",
                        thinking = "ignored"
                    },
                    done = true
                }));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("구조화 응답", exception.Message);
    }

    [Fact]
    public async Task EmptyApiKey_DoesNotBlockOllama()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/tags"
                ? JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = JsonSerializer.Serialize(new
                        {
                            questions = new[]
                            {
                                new
                                {
                                    type = "shortAnswer",
                                    prompt = "질문",
                                    choices = Array.Empty<object>(),
                                    acceptableAnswers = new[] { "답" },
                                    explanation = (string?)null,
                                    difficulty = 1,
                                    sourceIds = new[] { "전자기학" }
                                }
                            }
                        })
                    },
                    done = true
                }));
        var provider = CreateProvider(handler, apiKey: string.Empty);

        var questions = await provider.GenerateQuestionsAsync(
            Input(),
            TestContext.Current.CancellationToken);

        Assert.Single(questions);
    }

    private static OllamaLlmProvider CreateProvider(
        HttpMessageHandler handler,
        string apiKey = "")
    {
        return new OllamaLlmProvider(
            new HttpClient(handler),
            Options.Create(new LlmOptions
            {
                Provider = "ollama",
                Model = "qwen3:8b",
                BaseUrl = "http://127.0.0.1:11434",
                ApiKey = apiKey
            }),
            NullLogger<OllamaLlmProvider>.Instance);
    }

    private static QuestionGenerationInput Input() => new(
        "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.",
        1,
        ["shortAnswer"],
        "전자기학",
        "question-generation-v2-grounded");

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
        public List<RecordedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(new RecordedRequest(
                request.RequestUri!.AbsolutePath,
                request.Content is null
                    ? null
                    : await request.Content.ReadAsStringAsync(cancellationToken),
                request.Headers.Authorization?.ToString()));
            return responseFactory(request);
        }
    }

    private sealed record RecordedRequest(
        string Path,
        string? Body,
        string? Authorization);
}
