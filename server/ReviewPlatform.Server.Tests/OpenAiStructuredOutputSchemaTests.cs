using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class OpenAiStructuredOutputSchemaTests
{
    [Fact]
    public void Build_PreservesInputSchemaAndSupportedConstraints()
    {
        var original = ConceptExtractionPrompt.BuildOllamaSchema(new ConceptExtractionInput("source", "자료.pdf",
            [new ExtractedDocumentPage(3, "내용"), new ExtractedDocumentPage(5, "내용")],
            ConceptExtractionPrompt.Version));
        var snapshot = original.ToJsonString();
        var result = OpenAiStructuredOutputSchema.Build(original);
        Assert.Equal(snapshot, original.ToJsonString());
        var concepts = result["properties"]!["concepts"]!;
        Assert.Equal(1, concepts["minItems"]!.GetValue<int>());
        Assert.Equal(8, concepts["maxItems"]!.GetValue<int>());
        var properties = concepts["items"]!["properties"]!;
        Assert.Null(properties["title"]!["maxLength"]);
        Assert.Contains("200", properties["title"]!["description"]!.GetValue<string>());
        Assert.Contains("8000", properties["content"]!["description"]!.GetValue<string>());
        Assert.Null(properties["pageNumbers"]!["uniqueItems"]);
        Assert.Equal("[3,5]", properties["pageNumbers"]!["items"]!["enum"]!.ToJsonString());
        Assert.Equal(original["properties"]!["concepts"]!["items"]!["properties"]!["importance"]!.ToJsonString(),
            properties["importance"]!.ToJsonString());
        using var document = JsonDocument.Parse(result.ToJsonString());
        ValidateSchema(document.RootElement);
    }

    [Fact]
    public void Build_TraversesSchemasWithoutRemovingPropertyNamesOrEnumValues()
    {
        var original = JsonNode.Parse("""
            {"type":"object","additionalProperties":false,"required":["maxLength","uniqueItems"],
             "properties":{
               "maxLength":{"anyOf":[{"type":"string","minLength":1,"maxLength":10,"description":"Existing guidance."},{"type":"null"}]},
               "uniqueItems":{"type":"string","enum":["maxLength","uniqueItems"]}},
             "$defs":{"values":{"type":"array","uniqueItems":true,"minItems":1,"maxItems":3,
               "items":{"type":"integer","minimum":1,"maximum":9}}}}
            """)!.AsObject();
        var result = OpenAiStructuredOutputSchema.Build(original);
        var text = result["properties"]!["maxLength"]!["anyOf"]![0]!;
        Assert.Null(text["minLength"]);
        Assert.Null(text["maxLength"]);
        Assert.Contains("Existing guidance.", text["description"]!.GetValue<string>());
        Assert.Contains("at least 1", text["description"]!.GetValue<string>());
        Assert.Contains("at most 10", text["description"]!.GetValue<string>());
        Assert.Equal("[\"maxLength\",\"uniqueItems\"]", result["properties"]!["uniqueItems"]!["enum"]!.ToJsonString());
        var values = result["$defs"]!["values"]!;
        Assert.Null(values["uniqueItems"]);
        Assert.Equal(3, values["maxItems"]!.GetValue<int>());
        Assert.Equal(9, values["items"]!["maximum"]!.GetValue<int>());
        using var document = JsonDocument.Parse(result.ToJsonString());
        ValidateSchema(document.RootElement);
    }

    [Theory]
    [InlineData("questions")]
    [InlineData("concepts")]
    [InlineData("revision")]
    [InlineData("vision")]
    public async Task Requests_OnlySendSupportedStrictSchemas(string operation)
    {
        var handler = new SchemaValidationHandler(operation);
        var provider = new OpenAiLlmProvider(new HttpClient(handler), Options.Create(new LlmOptions
        {
            Model = "gpt-6.1-sol", ApiKey = "test-key"
        }));
        var cancellation = TestContext.Current.CancellationToken;
        switch (operation)
        {
            case "questions":
                await provider.GenerateQuestionsAsync(new QuestionGenerationInput(
                    "학습 내용", 1, ["shortAnswer"], "source", "question-generation-test"), cancellation);
                break;
            case "concepts":
                await provider.ExtractConceptsAsync(new ConceptExtractionInput("source", "자료.pdf",
                    [new ExtractedDocumentPage(1, "학습 내용")], ConceptExtractionPrompt.Version), cancellation);
                break;
            case "revision":
                await provider.ReviseConceptsAsync(new ConceptRevisionInput("source", "자료", 1, "수정 요청",
                    [new ConceptRevisionContext("c1", "제목", "본문", [1], "held")],
                    ["c1"], ConceptRevisionPrompt.Version, true, true), cancellation);
                break;
            case "vision":
                await provider.ExtractPageContentAsync(new DocumentVisionInput("자료.pdf", 1,
                    "image/png", [1], "hash", DocumentVisionPrompt.Version), cancellation);
                break;
        }
        Assert.Equal(1, handler.CallCount);
    }

    [Fact]
    public void StructuredQuestionsUseSupportedStrictSchemaAndOnlyAllocatedConceptIds()
    {
        var input = new QuestionGenerationInput("학습 내용", 1, ["shortAnswer"], null, "test",
            ConceptPlans: [
                new(new("low", "제목", "내용", "veryLow"), 0),
                new(new("high", "제목", "내용", "veryHigh"), 1)
            ], ReflectConceptImportance: true);
        var schema = OpenAiStructuredOutputSchema.Build(QuestionGenerationPrompt.BuildQuestionSchema(input));
        using var document = JsonDocument.Parse(schema.ToJsonString());
        ValidateSchema(document.RootElement);
        Assert.Equal("[\"high\"]", schema["properties"]!["questions"]!["items"]!
            ["properties"]!["primaryConceptId"]!["enum"]!.ToJsonString());
    }

    private static void ValidateSchema(JsonElement schema)
    {
        // Validate the on-the-wire schema, not just its top-level envelope.
        // Do not descend into enum values or treat names in properties as keywords.
        var allowed = new HashSet<string>(StringComparer.Ordinal)
        {
            "type", "properties", "required", "additionalProperties", "items", "enum", "description",
            "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
            "minItems", "maxItems", "pattern", "format", "anyOf", "$defs", "$ref"
        };
        foreach (var field in schema.EnumerateObject())
            Assert.Contains(field.Name, allowed);
        if (schema.TryGetProperty("properties", out var properties))
        {
            Assert.False(schema.GetProperty("additionalProperties").GetBoolean());
            var required = schema.GetProperty("required").EnumerateArray().Select(value => value.GetString()).ToList();
            var names = properties.EnumerateObject().Select(field => field.Name).ToList();
            Assert.Equal(names.Order(), required.Order());
            foreach (var field in properties.EnumerateObject()) ValidateSchema(field.Value);
        }
        if (schema.TryGetProperty("items", out var items)) ValidateSchema(items);
        if (schema.TryGetProperty("anyOf", out var anyOf))
            foreach (var item in anyOf.EnumerateArray()) ValidateSchema(item);
        if (schema.TryGetProperty("$defs", out var definitions))
            foreach (var field in definitions.EnumerateObject()) ValidateSchema(field.Value);
    }

    private sealed class SchemaValidationHandler(string operation) : HttpMessageHandler
    {
        public int CallCount { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
            var format = body.RootElement.GetProperty("text").GetProperty("format");
            Assert.True(format.GetProperty("strict").GetBoolean());
            ValidateSchema(format.GetProperty("schema"));
            var text = operation switch
            {
                "questions" => "{\"questions\":[]}",
                "concepts" => "{\"concepts\":[]}",
                "revision" => "{\"revisions\":[],\"additions\":[],\"deletions\":[]}",
                _ => "{\"text\":\"\"}"
            };
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new
                {
                    status = "completed", output = new[] { new { type = "message", content = new[] {
                        new { type = "output_text", text } } } }
                }), Encoding.UTF8, "application/json")
            };
        }
    }
}
