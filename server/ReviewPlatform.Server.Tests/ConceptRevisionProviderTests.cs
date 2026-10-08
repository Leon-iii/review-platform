using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptRevisionProviderTests
{
    private static ConceptRevisionInput Input(bool source = true) => new("source", "자료.pdf", 50, "본문 교정",
        [new("c1", "제목", "기존 내용", [47, 50], "held")], ["c1"], ConceptRevisionPrompt.Version,
        Clarifications: [new("범위가 무엇인가요?", "본문만")],
        Source: source ? new([1, 2, 3], [47, 50]) : null);
    private static string Completed() => JsonSerializer.Serialize(new {
        status = "completed", usage = new { input_tokens = 1234, output_tokens = 65001,
            output_tokens_details = new { reasoning_tokens = 1000 } },
        output = new[] { new { type = "message", content = new[] { new { type = "output_text", text = JsonSerializer.Serialize(new {
            status = "needsClarification", comment = "삭제 범위를 확인해 주세요.", clarificationQuestion = "어느 문장을 삭제할까요?",
            revisions = Array.Empty<object>(), additions = Array.Empty<object>(), deletions = Array.Empty<object>()
        }) } } } }
    });

    [Theory]
    [InlineData(1234, 128000)]
    [InlineData(1000000, 41808)]
    public async Task Reference_CountsExactInputAndUsesTechnicalOutputLimit_NotSoftThreshold(long inputTokens, int budget)
    {
        var requests = new List<JsonElement>();
        using var client = new HttpClient(new Handler(async request => {
            Assert.Equal("test-key", request.Headers.Authorization!.Parameter);
            requests.Add(JsonDocument.Parse(await request.Content!.ReadAsStringAsync()).RootElement.Clone());
            return Response(request.RequestUri!.AbsolutePath.EndsWith("input_tokens")
                ? JsonSerializer.Serialize(new { input_tokens = inputTokens }) : Completed());
        }));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = "gpt-6-luna", ApiKey = "test-key", ReasoningEffort = "low" }));
        var result = await provider.ReviseConceptsAsync(Input(), TestContext.Current.CancellationToken);
        Assert.Equal("needsClarification", result.Status);
        Assert.Empty(result.Changes);
        Assert.Equal(2, requests.Count);
        Assert.Equal(requests[0].GetProperty("input").GetRawText(), requests[1].GetProperty("input").GetRawText());
        Assert.False(requests[0].TryGetProperty("max_output_tokens", out _));
        Assert.Equal(budget, requests[1].GetProperty("max_output_tokens").GetInt32());
        Assert.Equal("low", requests[1].GetProperty("reasoning").GetProperty("effort").GetString());
        var content = requests[1].GetProperty("input")[1].GetProperty("content");
        Assert.Equal("input_file", content[0].GetProperty("type").GetString());
        Assert.Equal("data:application/pdf;base64,AQID", content[0].GetProperty("file_data").GetString());
        Assert.Equal(ConceptRevisionPrompt.BuildUserPrompt(Input()), content[1].GetProperty("text").GetString());
    }

    [Theory]
    [InlineData("count-failure")]
    [InlineData("count-invalid")]
    [InlineData("context-full")]
    public async Task Reference_PreflightFailuresNeverSendGeneration(string failure)
    {
        var calls = 0;
        using var client = new HttpClient(new Handler(request => {
            calls++;
            Assert.EndsWith("input_tokens", request.RequestUri!.AbsolutePath);
            return Task.FromResult(failure switch {
                "count-failure" => new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent("{\"error\":{\"code\":\"invalid_request\"}}") },
                "count-invalid" => Response("{\"input_tokens\":0}"),
                _ => Response("{\"input_tokens\":1042000}")
            });
        }));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = "gpt-6-luna", ApiKey = "test-key" }));
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => provider.ReviseConceptsAsync(Input(), TestContext.Current.CancellationToken));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task TextOnly_DoesNotUseLocalCaps_AndIncompleteJsonIsNeverAccepted()
    {
        var calls = 0;
        using var client = new HttpClient(new Handler(async request => {
            calls++;
            using var payload = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            Assert.Equal(128000, payload.RootElement.GetProperty("max_output_tokens").GetInt32());
            return Response("{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}");
        }));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = "gpt-6-luna", ApiKey = "test-key", ReasoningEffort = "none" }));
        var error = await Assert.ThrowsAsync<LlmProviderRequestException>(() => provider.ReviseConceptsAsync(Input(false), TestContext.Current.CancellationToken));
        Assert.Contains("추론·출력 토큰 한도", error.Message);
        Assert.Equal(1, calls);
        Assert.True(ConceptRevisionBudget.EstimateVisibleOutput(Input(false) with {
            Concepts = Enumerable.Range(0, 10).Select(index => new ConceptRevisionContext(index.ToString(), "제목", new string('가', 8000), [], "held")).ToArray(),
            EditableConceptIds = Enumerable.Range(0, 10).Select(index => index.ToString()).ToArray()
        }) > ConceptRevisionBudget.OutputSafetyThresholdTokens);
    }

    [Theory]
    [InlineData("unknown-model")]
    [InlineData("o3-mini")]
    public async Task UnsupportedReference_IsRejectedBeforeSending(string model)
    {
        using var client = new HttpClient(new Handler(_ => throw new InvalidOperationException("No network expected")));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = model, ApiKey = "test-key" }));
        await Assert.ThrowsAsync<LlmProviderUnavailableException>(() => provider.ReviseConceptsAsync(Input(), TestContext.Current.CancellationToken));
    }

    private static HttpResponseMessage Response(string body) => new(HttpStatusCode.OK) {
        Content = new StringContent(body, Encoding.UTF8, "application/json")
    };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }
}
