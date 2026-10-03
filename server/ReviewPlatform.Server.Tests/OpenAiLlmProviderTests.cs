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
        Assert.False(root.TryGetProperty("num_ctx", out _));
        Assert.False(root.TryGetProperty("options", out _));
        Assert.False(root.TryGetProperty("reasoning", out _));
        Assert.Null(((ILLMProvider)provider).ContextWindowTokens);
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

    [Fact]
    public async Task DocumentVision_SendsImageAndReturnsTextUsingSelectedProfile()
    {
        var handler = new RecordingHandler(_ => VisionResponse("  표와 수식: E = mc²\n한국어  "));
        var result = await CreateProvider(handler, model: "gpt-6.1-sol", effort: "medium")
            .ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken);
        Assert.Equal("표와 수식: E = mc²\n한국어", result.Text);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        var root = request.RootElement;
        Assert.Equal("gpt-6.1-sol", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("store").GetBoolean());
        Assert.Equal("medium", root.GetProperty("reasoning").GetProperty("effort").GetString());
        Assert.True(root.GetProperty("max_output_tokens").GetInt32() >= 25_000);
        Assert.False(root.TryGetProperty("options", out _));
        var content = root.GetProperty("input")[1].GetProperty("content");
        Assert.Equal("input_text", content[0].GetProperty("type").GetString());
        Assert.Contains("PAGE: 3", content[0].GetProperty("text").GetString());
        Assert.Equal("input_image", content[1].GetProperty("type").GetString());
        Assert.Equal("data:image/png;base64,AQID", content[1].GetProperty("image_url").GetString());
        Assert.Equal("high", content[1].GetProperty("detail").GetString());
        var format = root.GetProperty("text").GetProperty("format");
        Assert.True(format.GetProperty("strict").GetBoolean());
        Assert.Equal("json_schema", format.GetProperty("type").GetString());
        Assert.False(format.GetProperty("schema").GetProperty("additionalProperties").GetBoolean());
        Assert.Equal("Bearer", handler.AuthorizationScheme);
        Assert.DoesNotContain("test-api-key", handler.RequestBody);
    }

    [Fact]
    public async Task DocumentVision_ReturnsTypedRegionsAndRequiresTheirKindsInSchema()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new
        {
            status = "completed",
            output = new[] { new { type = "message", content = new[] { new
            {
                type = "output_text",
                text = """{"regions":[{"kind":"diagram","text":"A → B","visualRegion":true},{"kind":"table","text":"|열|값|","visualRegion":false}]}"""
            } } } }
        }));
        var result = await CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken);
        Assert.Equal(["diagram", "table"], result.Regions!.Select(region => region.Kind));
        using var request = JsonDocument.Parse(handler.RequestBody!);
        var itemSchema = request.RootElement.GetProperty("text").GetProperty("format").GetProperty("schema")
            .GetProperty("properties").GetProperty("regions").GetProperty("items");
        Assert.Equal(["text", "diagram", "table", "uncertain"], itemSchema.GetProperty("properties")
            .GetProperty("kind").GetProperty("enum").EnumerateArray().Select(value => value.GetString()));
        Assert.Contains(itemSchema.GetProperty("required").EnumerateArray(), value => value.GetString() == "kind");
    }

    [Fact]
    public async Task DocumentVision_BlankPageIsValid()
    {
        var handler = new RecordingHandler(_ => VisionResponse(""));
        var result = await CreateProvider(handler).ExtractPageContentAsync(
            VisionInput(), TestContext.Current.CancellationToken);
        Assert.Empty(result.Text);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"text\":null}")]
    [InlineData("not json")]
    public async Task DocumentVision_InvalidResultIsProviderFailure(string output)
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "completed", output = new[] { new { type = "message",
                content = new[] { new { type = "output_text", text = output } } } } }));
        await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task DocumentVision_IncompleteOutputIsNotSavedAsPartialText()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "incomplete", incomplete_details = new { reason = "max_output_tokens" } }));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        Assert.Contains("추론·출력 토큰 한도", error.Message);
    }

    [Fact]
    public async Task DocumentVision_RefusalIsSafeFailure()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "completed", output = new[] { new { type = "message",
                content = new[] { new { type = "refusal", refusal = "private detail" } } } } }));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        Assert.Contains("거절", error.Message);
        Assert.DoesNotContain("private detail", error.Message);
    }

    [Fact]
    public async Task DocumentVision_ApiFailureHidesUpstreamSecrets()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.BadRequest,
            new { error = new { code = "invalid_image", message = "test-api-key private detail" } }));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        Assert.Contains("400", error.Message);
        Assert.Contains("invalid_image", error.Message);
        Assert.DoesNotContain("test-api-key", error.Message);
    }

    [Fact]
    public async Task DocumentVision_MissingKeyOrInvalidImageDoesNotSendRequest()
    {
        var handler = new RecordingHandler(_ => throw new InvalidOperationException());
        await Assert.ThrowsAsync<LlmProviderUnavailableException>(() =>
            CreateProvider(handler, apiKey: "").ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        foreach (var input in new[] {
            VisionInput() with { ImageBytes = [] },
            VisionInput() with { ImageBytes = new byte[12 * 1024 * 1024 + 1] },
            VisionInput() with { MimeType = "text/plain" } })
            await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
                CreateProvider(handler).ExtractPageContentAsync(input, TestContext.Current.CancellationToken));
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task DocumentVision_TimeoutIsReadableAndCallerCancellationPropagates()
    {
        var handler = new RecordingHandler(_ => throw new TaskCanceledException());
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        Assert.Contains("시간이 초과", error.Message);
        Assert.Contains("p.3", error.Message);
        using var cancellation = new CancellationTokenSource();
        await cancellation.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), cancellation.Token));
    }

    [Fact]
    public async Task DocumentVision_OversizedOutputIsRejected()
    {
        var handler = new RecordingHandler(_ => VisionResponse(new string('x', 50_001)));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        Assert.Contains("너무 깁니다", error.Message);
    }

    [Fact]
    public async Task DocumentVision_ConnectionErrorIsReadable()
    {
        var handler = new RecordingHandler(_ => throw new HttpRequestException("private detail"));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractPageContentAsync(VisionInput(), TestContext.Current.CancellationToken));
        Assert.Contains("연결하지 못했습니다", error.Message);
        Assert.DoesNotContain("private detail", error.Message);
    }

    [Fact]
    public async Task DocumentVision_CombinesOutputTextPartsAndIgnoresReasoning()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "completed", output = new object[] {
                new { type = "reasoning", summary = Array.Empty<object>() },
                new { type = "message", content = new[] {
                    new { type = "output_text", text = "{\"text\":\"" },
                    new { type = "output_text", text = "OCR 결과\"}" } } } } }));
        var result = await CreateProvider(handler).ExtractPageContentAsync(
            VisionInput(), TestContext.Current.CancellationToken);
        Assert.Equal("OCR 결과", result.Text);
    }

    [Fact]
    public async Task InvalidConceptSchema_IdentifiesStageWithoutExposingUpstreamMessage()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.BadRequest,
            new { error = new { code = "invalid_json_schema", message = "private upstream detail" } }));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).ExtractConceptsAsync(new ConceptExtractionInput("source", "자료.pdf",
                [new ExtractedDocumentPage(1, "내용")], ConceptExtractionPrompt.Version),
                TestContext.Current.CancellationToken));
        Assert.Contains("개념 추출", error.Message);
        Assert.Contains("JSON Schema", error.Message);
        Assert.Contains("400 (invalid_json_schema)", error.Message);
        Assert.DoesNotContain("private upstream detail", error.Message);
    }

    private static DocumentVisionInput VisionInput() => new(
        "강의.pdf", 3, "image/png", [1, 2, 3], "image-hash", DocumentVisionPrompt.Version);

    private static HttpResponseMessage VisionResponse(string text) =>
        JsonResponse(HttpStatusCode.OK, new { status = "completed", output = new[] {
            new { type = "message", content = new[] {
                new { type = "output_text", text = JsonSerializer.Serialize(new { text }) } } } } });

    private static OpenAiLlmProvider CreateProvider(
        HttpMessageHandler handler,
        string apiKey = "test-api-key",
        string model = "test-model",
        string? effort = null)
    {
        return new OpenAiLlmProvider(
            new HttpClient(handler),
            Options.Create(new LlmOptions
            {
                Provider = "openai",
                ApiKey = apiKey,
                Model = model,
                ReasoningEffort = effort
            }));
    }

    [Theory]
    [InlineData("gpt-5-mini", "high", true)]
    [InlineData("gpt-5-mini", null, true)]
    [InlineData("gpt-5.1", "none", false)]
    [InlineData("gpt-4o-mini", null, false)]
    [InlineData("gpt-7-future", null, false)]
    [InlineData("gpt-6-luna", "max", true)]
    [InlineData("gpt-6-luna", "none", false)]
    [InlineData("gpt-6-luna", null, true)]
    [InlineData("gpt-5.6-terra", "high", true)]
    [InlineData("gpt-5.4-mini", "xhigh", true)]
    [InlineData("gpt-5.5-pro", "xhigh", true)]
    [InlineData("gpt-5-pro", "high", true)]
    [InlineData("o3-pro", null, true)]
    [InlineData("gpt-5.1-codex", null, true)]
    [InlineData("gpt-4.5-preview", null, false)]
    public async Task Reasoning_SendsOnlyExplicitSupportedEffortWithAppropriateBudget(
        string model, string? effort, bool reservesReasoning)
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "completed", output = new[] {
                new { type = "message", content = new[] {
                    new { type = "output_text", text = "{\"questions\":[]}" } } } } }));
        await CreateProvider(handler, model: model, effort: effort).GenerateQuestionsAsync(
            Input(), TestContext.Current.CancellationToken);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        Assert.Equal(effort is not null, request.RootElement.TryGetProperty("reasoning", out var reasoning));
        if (effort is not null)
            Assert.Equal(effort, reasoning.GetProperty("effort").GetString());
        var budget = request.RootElement.GetProperty("max_output_tokens").GetInt32();
        Assert.Equal(reservesReasoning, budget >= 25_000);
        Assert.InRange(budget, 1, 128_000);
    }

    [Theory]
    [InlineData("gpt-5-mini", "none")]
    [InlineData("gpt-7-future", "high")]
    [InlineData("gpt-4o-mini", "low")]
    [InlineData("gpt-5.5-pro", "low")]
    [InlineData("gpt-5-pro", "medium")]
    [InlineData("gpt-5.1-codex", "high")]
    public async Task UnsupportedReasoning_FailsBeforeSendingRequest(string model, string effort)
    {
        var handler = new RecordingHandler(_ => throw new InvalidOperationException());
        await Assert.ThrowsAsync<LlmProviderUnavailableException>(() =>
            CreateProvider(handler, model: model, effort: effort).GenerateQuestionsAsync(
                Input(), TestContext.Current.CancellationToken));
        Assert.Equal(0, handler.CallCount);
    }

    [Theory]
    [InlineData("gpt-5.4-pro")]
    [InlineData("gpt-5.2-pro-2025-12-11")]
    [InlineData("o1-mini")]
    [InlineData("o3-deep-research")]
    [InlineData("gpt-4o-2024-05-13")]
    public async Task KnownIncompatibleModels_FailBeforeSendingRequest(string model)
    {
        var handler = new RecordingHandler(_ => throw new InvalidOperationException());
        var error = await Assert.ThrowsAsync<LlmProviderUnavailableException>(() =>
            CreateProvider(handler, model: model).GenerateQuestionsAsync(
                Input(), TestContext.Current.CancellationToken));
        Assert.Contains("구조화 출력", error.Message);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task AutomaticOnlyReasoning_ClampsBudgetToKnownOutputLimit()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "completed", output = new[] {
                new { type = "message", content = new[] {
                    new { type = "output_text", text = "{\"questions\":[]}" } } } } }));
        await CreateProvider(handler, model: "o1-preview").GenerateQuestionsAsync(
            Input() with { QuestionCount = 100 }, TestContext.Current.CancellationToken);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        Assert.Equal(32768, request.RootElement.GetProperty("max_output_tokens").GetInt32());
        Assert.False(request.RootElement.TryGetProperty("reasoning", out _));
    }

    [Fact]
    public async Task IncompleteOutput_ExplainsReasoningTokenLimit()
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "incomplete", incomplete_details = new { reason = "max_output_tokens" } }));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateProvider(handler).GenerateQuestionsAsync(Input(), TestContext.Current.CancellationToken));
        Assert.Contains("추론·출력 토큰 한도", error.Message);
    }

    [Fact]
    public async Task ReviseConcepts_ParsesAdditionsAndDeletionsWithGroups()
    {
        var output = JsonSerializer.Serialize(new {
            revisions = Array.Empty<object>(),
            additions = new[] { new { title = "새 개념", content = "내용", pageNumbers = Array.Empty<int>(), importance = "high", groupId = "replace", reason = "교체" } },
            deletions = new[] { new { id = "c1", reason = "교체 요청", groupId = "replace" } }
        });
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new {
            status = "completed", output = new[] { new { type = "message", content = new[] { new { type = "output_text", text = output } } } }
        }));
        var changes = await CreateProvider(handler).ReviseConceptsAsync(new ConceptRevisionInput(
            "source", "자료", 0, "교체", [new ConceptRevisionContext("c1", "제목", "내용", [], "held")],
            ["c1"], ConceptRevisionPrompt.Version, true, true), TestContext.Current.CancellationToken);
        Assert.Equal(["add", "delete"], changes.Select(item => item.Kind));
        Assert.All(changes, item => Assert.Equal("replace", item.GroupId));
        Assert.Equal("교체 요청", changes[1].Reason);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        var schema = request.RootElement.GetProperty("text").GetProperty("format").GetProperty("schema");
        Assert.True(schema.GetProperty("properties").TryGetProperty("additions", out _));
        Assert.True(schema.GetProperty("properties").TryGetProperty("deletions", out _));
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
