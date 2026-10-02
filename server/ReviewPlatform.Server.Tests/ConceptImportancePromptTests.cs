using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptImportancePromptTests
{
    [Fact]
    public void ExtractionAndRevisionSchemasUseSameFiveOrderedLevels()
    {
        var extraction = ConceptExtractionPrompt.BuildSchema(new ConceptExtractionInput(
            "source", "자료.pdf", [new ExtractedDocumentPage(1, "내용")], ConceptExtractionPrompt.Version));
        var revision = ConceptRevisionPrompt.BuildSchema(new ConceptRevisionInput(
            "source", "자료.pdf", 1, "요청",
            [new ConceptRevisionContext("concept", "제목", "내용", [1], "held")],
            ["concept"], ConceptRevisionPrompt.Version));
        foreach (var (schema, collection) in new[] { (extraction, "concepts"), (revision, "revisions") })
        {
            var values = schema["properties"]![collection]!["items"]!["properties"]!["importance"]!["enum"]!
                .AsArray().Select(value => value!.GetValue<string>()).ToArray();
            Assert.Equal(["veryLow", "low", "medium", "high", "veryHigh"], values);
            Assert.All(values, value => Assert.Equal(value, ConceptImportanceLevels.Normalize(value)));
        }
        Assert.Contains("Required recall precision", ConceptExtractionPrompt.SystemPrompt);
        Assert.Contains("secondary", ConceptExtractionPrompt.SystemPrompt);
        Assert.Contains("Preserve pageNumbers and importance exactly", ConceptRevisionPrompt.SystemPrompt);
    }
}
