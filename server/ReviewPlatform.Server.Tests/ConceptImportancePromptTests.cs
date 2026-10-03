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
        Assert.Contains("Preserve pageNumbers and importance exactly", ConceptRevisionPrompt.SystemPrompt);
    }

    [Fact]
    public void LearningValueCeiling_IsSharedByExtractionAndRevision()
    {
        foreach (var prompt in new[] { ConceptExtractionPrompt.SystemPrompt, ConceptRevisionPrompt.SystemPrompt })
        {
            Assert.Contains(ConceptImportancePrompt.Instructions, prompt);
            Assert.Contains("Learning value first", prompt);
            Assert.Contains("veryLow or low, regardless of how many facts", prompt);
            Assert.Contains("a ceiling, not a weighted score", prompt);
            Assert.Contains("not every fact enumerated", prompt);
            Assert.Contains("explicit evidence", prompt);
            Assert.Contains("Do not invent exam likelihood", prompt);
        }
        Assert.DoesNotContain("Do not make exam likelihood the primary criterion", ConceptExtractionPrompt.SystemPrompt);
        Assert.DoesNotContain("exam suitability is secondary", ConceptRevisionPrompt.SystemPrompt);
        Assert.Contains("keep all other existing importance values unchanged", ConceptRevisionPrompt.SystemPrompt);
    }

    [Fact]
    public void ImportanceSchemaDescriptions_UseLearningValueCeilingForAllConceptKinds()
    {
        var extraction = ConceptExtractionPrompt.BuildSchema(new ConceptExtractionInput(
            "source", "자료.pdf", [new ExtractedDocumentPage(1, "내용")], ConceptExtractionPrompt.Version));
        var revision = ConceptRevisionPrompt.BuildSchema(new ConceptRevisionInput(
            "source", "자료.pdf", 1, "요청",
            [new ConceptRevisionContext("concept", "제목", "내용", [1], "held")],
            ["concept"], ConceptRevisionPrompt.Version, true));
        foreach (var (schema, collection) in new[] { (extraction, "concepts"), (revision, "revisions"), (revision, "additions") })
            Assert.Equal(ConceptImportancePrompt.SchemaDescription,
                schema["properties"]![collection]!["items"]!["properties"]!["importance"]!["description"]!.GetValue<string>());
    }

    [Fact]
    public void RegionBoundariesAndSemanticIndependence_AreUsedWithoutExampleContent()
    {
        foreach (var prompt in new[] { DocumentVisionPrompt.SystemPrompt, DocumentVisionPrompt.StructuredSystemPrompt })
        {
            Assert.Contains("visualRegion=true", prompt);
            Assert.Contains("Do not put boundary markers in text", prompt);
            Assert.Contains("never interleave", prompt);
            Assert.Contains("do not classify concepts or evaluate importance", prompt);
        }
        var extraction = ConceptExtractionPrompt.SystemPrompt;
        Assert.Contains("One page can support", extraction);
        Assert.Contains("multiple concepts", extraction);
        Assert.Contains("independent learning purpose", extraction);
        Assert.Contains("not an automatic instruction", extraction);
        Assert.Contains("text-only pages", extraction);
        Assert.Contains("Do not split each timeline date", extraction);
        Assert.Contains("Never copy extraction boundary markers", extraction);
        Assert.DoesNotContain("Cerf", extraction);
        Assert.DoesNotContain("ARPAnet", extraction);
    }
}
