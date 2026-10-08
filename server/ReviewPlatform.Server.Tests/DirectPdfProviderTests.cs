using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Services;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace ReviewPlatform.Server.Tests;
public sealed class DirectPdfProviderTests
{
    [Fact]
    public async Task NativePdfRequests_CountExactPayload_UseLargeOutput_HasNoConceptCountCap()
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
        Assert.Equal(128_000, provider.MaximumPdfOutputTokens);
        var input = new DirectPdfInput("id", "강의.pdf", Encoding.ASCII.GetBytes("%PDF"), 1000, 128_000);
        var counted = await provider.CountPdfTokensAsync(input, TestContext.Current.CancellationToken);
        Assert.Equal(1234, counted.InputTokens);
        Assert.Null(counted.TokenLimit); // Count endpoint headers are not generation TPM.
        Assert.Single(await provider.ExtractPdfConceptsAsync(input, TestContext.Current.CancellationToken));
        Assert.Equal(128_000, requests[1].GetProperty("max_output_tokens").GetInt32());
        Assert.Equal("low", requests[1].GetProperty("reasoning").GetProperty("effort").GetString());
        Assert.Equal(requests[0].GetProperty("input").GetRawText(), requests[1].GetProperty("input").GetRawText());
        foreach (var request in requests)
            Assert.Equal(DirectPdfConceptPrompt.SystemPrompt,
                request.GetProperty("input")[0].GetProperty("content").GetString());
        Assert.Equal("input_file", requests[1].GetProperty("input")[1].GetProperty("content")[0].GetProperty("type").GetString());
        var schema = requests[1].GetProperty("text").GetProperty("format").GetProperty("schema");
        Assert.False(schema.GetProperty("properties").GetProperty("concepts").TryGetProperty("maxItems", out _));
        Assert.DoesNotContain("at most 8", DirectPdfConceptPrompt.SystemPrompt);
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

    [Theory]
    [InlineData("completed", 65_000)]
    [InlineData("incomplete", 128_000)]
    public async Task UsageAndRawResponse_AreRecorded_EvenOnActualLimit(string status, int outputTokens)
    {
        var root = Path.Combine(Path.GetTempPath(), "review-pdf-provider-" + Guid.NewGuid());
        try
        {
            var store = new DirectPdfTelemetryStore(new Environment(root), new ConfigurationBuilder().Build(),
                NullLogger<DirectPdfTelemetryStore>.Instance);
            var body = JsonSerializer.Serialize(new {
                status,
                incomplete_details = status == "incomplete" ? new { reason = "max_output_tokens" } : null,
                usage = new { input_tokens = 30672, output_tokens = outputTokens,
                    output_tokens_details = new { reasoning_tokens = 1000 } },
                output = new[] { new { type = "message", content = new[] { new {
                    type = "output_text", text = "{\"concepts\":[{\"title\":\"개념\",\"content\":\"내용\",\"pageNumbers\":[1],\"importance\":\"medium\"}]}"
                } } } }
            });
            using var client = new HttpClient(new Handler(async request => {
                using var payload = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
                Assert.Equal(128_000, payload.RootElement.GetProperty("max_output_tokens").GetInt32());
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) };
            }));
            var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions {
                Model = "gpt-6-luna", ApiKey = "never-store-this-key", ReasoningEffort = "low"
            }), directPdfTelemetry: store);
            var input = new DirectPdfInput("source", "자료.pdf", [1], 31, 128_000);
            if (status == "completed") Assert.Single(await provider.ExtractPdfConceptsAsync(input, TestContext.Current.CancellationToken));
            else await Assert.ThrowsAsync<LlmProviderRequestException>(() => provider.ExtractPdfConceptsAsync(input, TestContext.Current.CancellationToken));
            var path = Assert.Single(Directory.GetFiles(store.StorageDirectory, "*.usage.json"));
            var metadata = await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken);
            var record = JsonSerializer.Deserialize<DirectPdfUsageRecord>(metadata, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
            Assert.Equal(outputTokens, record.OutputTokens);
            Assert.Equal(1000, record.ReasoningTokens);
            Assert.Equal(30672, record.InputTokens);
            Assert.Equal("low", record.Profile.ReasoningEffort);
            Assert.Equal(DirectPdfConceptPrompt.Version, record.Profile.PromptVersion);
            Assert.Equal(status == "completed", record.Validated);
            Assert.Equal(status == "incomplete" ? "max_output_tokens" : null, record.IncompleteReason);
            Assert.Equal(body, await File.ReadAllTextAsync(Assert.Single(Directory.GetFiles(store.StorageDirectory, "*.response.json")), TestContext.Current.CancellationToken));
            Assert.DoesNotContain("never-store-this-key", metadata);
            Assert.Equal(status == "completed" ? 1 : 0, store.Estimate(provider.PdfEstimationProfile, 31).SampleCount);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData("new-unregistered-model", 128_000)]
    [InlineData("gpt-6-luna", 128_001)]
    public async Task UnregisteredOrInvalidLimit_DoesNotGuessOrSendRequest(string model, int maximum)
    {
        using var client = new HttpClient(new Handler(_ => throw new InvalidOperationException("Must not send request")));
        var provider = new OpenAiLlmProvider(client, Options.Create(new LlmOptions { Model = model, ApiKey = "test-key" }));
        await Assert.ThrowsAsync<LlmProviderUnavailableException>(() => provider.ExtractPdfConceptsAsync(
            new("source", "자료.pdf", [1], 1, maximum), TestContext.Current.CancellationToken));
        if (model == "new-unregistered-model") Assert.Null(provider.MaximumPdfOutputTokens);
    }

    private sealed class Environment(string path) : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "Tests";
        public string EnvironmentName { get; set; } = "Testing";
        public string ContentRootPath { get; set; } = path;
        public string WebRootPath { get; set; } = path;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
    }
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }
}
