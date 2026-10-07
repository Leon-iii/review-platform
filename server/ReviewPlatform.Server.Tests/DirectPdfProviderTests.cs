using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using Xunit;

namespace ReviewPlatform.Server.Tests;
public sealed class DirectPdfProviderTests
{
    [Fact]
    public async Task NativePdfRequests_CountExactPayload_UseLargeOutput_KeepOnlyOllamaCap()
    {
        var requests = new List<JsonElement>();
        using var client = new HttpClient(new Handler(async request =>
        {
            requests.Add(JsonDocument.Parse(await request.Content!.ReadAsStringAsync()).RootElement.Clone());
            var counting = request.RequestUri!.AbsolutePath.EndsWith("input_tokens");
            var body = counting ? "{\"input_tokens\":1234}" : JsonSerializer.Serialize(new {
                status = "completed", output = new[] { new { type = "message", content = new[] { new {
                    type = "output_text", text = "{\"concepts\":[{\"title\":\"개념\",\"content\":\"내용\",\"pageNumbers\":[1],\"importance\":\"medium\"}]}"
                } } } } });
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) };
            response.Headers.Add("x-ratelimit-limit-tokens", counting ? "1" : "500000");
            return response;
        }));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = "gpt-6-luna", ApiKey = "test-only-key", ReasoningEffort = "low" }));
        var input = new DirectPdfInput("id", "강의.pdf", Encoding.ASCII.GetBytes("%PDF"), 1000, 64000);
        var counted = await provider.CountPdfTokensAsync(input, TestContext.Current.CancellationToken);
        Assert.Equal(1234, counted.InputTokens);
        Assert.Null(counted.TokenLimit); // Count endpoint headers are not generation TPM.
        Assert.Single(await provider.ExtractPdfConceptsAsync(input, TestContext.Current.CancellationToken));
        Assert.Equal(64000, requests[1].GetProperty("max_output_tokens").GetInt32());
        Assert.Equal("low", requests[1].GetProperty("reasoning").GetProperty("effort").GetString());
        Assert.Equal(requests[0].GetProperty("input").GetRawText(), requests[1].GetProperty("input").GetRawText());
        Assert.Equal("input_file", requests[1].GetProperty("input")[1].GetProperty("content")[0].GetProperty("type").GetString());
        var schema = requests[1].GetProperty("text").GetProperty("format").GetProperty("schema");
        Assert.False(schema.GetProperty("properties").GetProperty("concepts").TryGetProperty("maxItems", out _));
        Assert.DoesNotContain("at most 8", DirectPdfConceptPrompt.SystemPrompt);
        Assert.DoesNotContain("at most 8", ConceptExtractionPrompt.SystemPrompt);
        Assert.Contains("at most 8", ConceptExtractionPrompt.OllamaSystemPrompt);
    }

    [Theory]
    [InlineData("{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"concepts\\\":[\"}]}]}")]
    public async Task IncompleteOutput_IsNeverSavedAsConcepts(string body)
    {
        using var client = new HttpClient(new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) })));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = "gpt-6-luna", ApiKey = "test-only-key" }));
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => provider.ExtractPdfConceptsAsync(
            new("id", "강의.pdf", [1], 1, 64000), TestContext.Current.CancellationToken));
    }
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }
}
