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
    [Theory]
    [InlineData("gpt-6-luna", 120, 84_800)]
    [InlineData("gpt-6-luna", 1000, 128_000)]
    [InlineData("test-model", 120, 16_000)]
    public async Task AutomaticCoverageReservesOutputBeyondOldDensityEstimateButRespectsModelLimit(
        string model, int cap, int expectedBudget)
    {
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK,
            new { status = "completed", output = new[] {
                new { type = "message", content = new[] {
                    new { type = "output_text", text = "{\"questions\":[]}" } } } } }));
        await CreateProvider(handler, model: model, effort: model == "gpt-6-luna" ? "none" : null)
            .GenerateQuestionsAsync(Input() with { GenerationMode = "automatic", AutomaticDensity = "low",
                MaximumQuestionsPerRequest = cap }, TestContext.Current.CancellationToken);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        Assert.Equal(expectedBudget, request.RootElement.GetProperty("max_output_tokens").GetInt32());
        Assert.Equal(1, handler.CallCount);
    }

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
        Assert.Contains("haera-che (해라체)", root.GetProperty("input")[0]
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
            status = "ready", comment = "교체 요청을 반영했습니다.", clarificationQuestion = "",
            revisions = Array.Empty<object>(),
            additions = new[] { new { title = "새 개념", content = "내용", pageNumbers = Array.Empty<int>(), importance = "high", groupId = "replace", reason = "교체" } },
            deletions = new[] { new { id = "c1", reason = "교체 요청", groupId = "replace" } }
        });
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new {
            status = "completed", output = new[] { new { type = "message", content = new[] { new { type = "output_text", text = output } } } }
        }));
        var changes = await CreateProvider(handler, model: "gpt-4.1").ReviseConceptsAsync(new ConceptRevisionInput(
            "source", "자료", 0, "교체", [new ConceptRevisionContext("c1", "제목", "내용", [], "held")],
            ["c1"], ConceptRevisionPrompt.Version, true, true), TestContext.Current.CancellationToken);
        Assert.Equal(["add", "delete"], changes.Changes.Select(item => item.Kind));
        Assert.All(changes.Changes, item => Assert.Equal("replace", item.GroupId));
        Assert.Equal("교체 요청", changes.Changes[1].Reason);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        var schema = request.RootElement.GetProperty("text").GetProperty("format").GetProperty("schema");
        Assert.True(schema.GetProperty("properties").TryGetProperty("additions", out _));
        Assert.True(schema.GetProperty("properties").TryGetProperty("deletions", out _));
    }

    [Fact]
    public async Task ReviseConcepts_SendsSemanticIntegrationPolicyAndAcceptsRewrittenPassages()
    {
        const string revised = "객체가 캐시에 있으면 캐시 히트(cache hit)로 캐시가 반환하고, 없으면 캐시 미스(cache miss)로 원본 서버에서 받아 저장한 뒤 전달한다.";
        var output = JsonSerializer.Serialize(new
        {
            status = "ready", comment = "용어를 통합했습니다.", clarificationQuestion = "",
            revisions = new[] { new { id = "cache", title = "웹 캐시", content = revised,
                pageNumbers = new[] { 1 }, importance = "medium", groupId = "" } },
            additions = Array.Empty<object>(), deletions = Array.Empty<object>()
        });
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new
        {
            status = "completed", output = new[] { new { type = "message",
                content = new[] { new { type = "output_text", text = output } } } }
        }));
        var input = new ConceptRevisionInput("source", "자료.pdf", 1,
            "캐시 히트와 캐시 미스에 대한 내용도 포함시켜 줘.",
            [new ConceptRevisionContext("cache", "웹 캐시", "객체가 캐시에 있으면 캐시가 반환한다.", [1], "approved")],
            ["cache"], ConceptRevisionPrompt.Version);

        var revisions = await CreateProvider(handler, model: "gpt-4.1").ReviseConceptsAsync(input, TestContext.Current.CancellationToken);

        Assert.Equal(revised, Assert.Single(revisions.Changes).Content);
        using var request = JsonDocument.Parse(handler.RequestBody!);
        var messages = request.RootElement.GetProperty("input");
        Assert.Equal(ConceptRevisionPrompt.SystemPrompt, messages[0].GetProperty("content").GetString());
        Assert.Equal(ConceptRevisionPrompt.BuildUserPrompt(input), messages[1].GetProperty("content").GetString());
    }

    private static QuestionGenerationInput Input() => new(
        "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.",
        1,
        ["shortAnswer"],
        null,
        "question-generation-v1");

    [Theory]
    [InlineData("gpt-6.1-sol", true)]
    [InlineData("gpt-5.6-sol", true)]
    [InlineData("gpt-4.1", false)]
    [InlineData("gpt-7-future", false)]
    public async Task SingleConcept_UsesStableSchemaAndSupportedCacheOptions(string model, bool explicitCache)
    {
        var output = JsonSerializer.Serialize(new { questions = new[] {
            new { type = "shortAnswer", prompt = "질문", choices = Array.Empty<object>(),
                acceptableAnswers = new[] { "정답" }, explanation = "해설", difficulty = 1 } } });
        var handler = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, new {
            status = "completed", output = new[] { new { type = "message",
                content = new[] { new { type = "output_text", text = output } } } } }));
        var input = Input() with { SourceText = "", ConceptPlans = [new(
            new QuestionGenerationConcept("concept-one", "웹 캐시", "캐시에서 객체를 반환한다."), 1, [4])],
            BindConceptOnServer = true };
        var questions = await CreateProvider(handler, model: model)
            .GenerateQuestionsAsync(input, TestContext.Current.CancellationToken);
        Assert.Single(questions); // Source/primary IDs are intentionally absent in model output.
        using var request = JsonDocument.Parse(handler.RequestBody!);
        var root = request.RootElement;
        Assert.Equal("review-question-single-concept-v12", root.GetProperty("prompt_cache_key").GetString());
        Assert.Equal(explicitCache, root.TryGetProperty("prompt_cache_options", out var options));
        var commonInstructions = explicitCache
            ? root.GetProperty("input")[0].GetProperty("content")[0].GetProperty("text").GetString()
            : root.GetProperty("input")[0].GetProperty("content").GetString();
        Assert.Contains("haera-che (해라체)", commonInstructions);
        if (explicitCache)
        {
            Assert.Equal("explicit", options.GetProperty("mode").GetString());
            Assert.Equal("30m", options.GetProperty("ttl").GetString());
            Assert.Equal("developer", root.GetProperty("input")[0].GetProperty("role").GetString());
            var prefix = root.GetProperty("input")[0].GetProperty("content")[0];
            Assert.Equal("explicit", prefix.GetProperty("prompt_cache_breakpoint").GetProperty("mode").GetString());
            Assert.DoesNotContain("concept-one", prefix.GetProperty("text").GetString());
        }
        var schema = root.GetProperty("text").GetProperty("format").GetProperty("schema");
        Assert.DoesNotContain("sourceIds", schema.GetRawText());
        Assert.DoesNotContain("primaryConceptId", schema.GetRawText());
        var payload = JsonDocument.Parse(root.GetProperty("input")[1].GetProperty("content").GetString()!);
        using (payload)
        {
            Assert.Equal("concept-one", payload.RootElement.GetProperty("source").GetProperty("id").GetString());
            Assert.Equal(1, payload.RootElement.GetProperty("questionCount").GetInt32());
            Assert.Equal(4, payload.RootElement.GetProperty("targetDifficulties")[0].GetInt32());
        }
    }

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
