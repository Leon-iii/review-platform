using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptExtractionPromptTests
{
    [Fact]
    public void SharedDefaultIsUncapped_OnlyOllamaHasEightConceptLimit()
    {
        var input = new ConceptExtractionInput("source", "자료.pdf",
            [new ExtractedDocumentPage(1, "내용")], ConceptExtractionPrompt.Version);
        Assert.Contains("Extract ALL study-worthy concepts", ConceptExtractionPrompt.SystemPrompt);
        Assert.DoesNotContain("at most 8", ConceptExtractionPrompt.SystemPrompt);
        Assert.DoesNotContain("at most 8", DirectPdfConceptPrompt.SystemPrompt);
        Assert.Contains("at most 8", ConceptExtractionPrompt.OllamaSystemPrompt);
        Assert.DoesNotContain("Extract ALL study-worthy concepts", ConceptExtractionPrompt.OllamaSystemPrompt);

        var shared = ConceptExtractionPrompt.BuildSchema(input);
        var ollama = ConceptExtractionPrompt.BuildOllamaSchema(input);
        Assert.Equal(8, ollama["properties"]!["concepts"]!["maxItems"]!.GetValue<int>());
        Assert.Null(shared["properties"]!["concepts"]!["maxItems"]);
        // Local request construction must never mutate future cloud requests.
        Assert.Null(ConceptExtractionPrompt.BuildSchema(input)["properties"]!["concepts"]!["maxItems"]);
    }

    [Fact]
    public void BothPoliciesRetainCommonSourceLanguageImportanceAndNotationRules()
    {
        foreach (var prompt in new[] { ConceptExtractionPrompt.SystemPrompt, ConceptExtractionPrompt.OllamaSystemPrompt })
        {
            Assert.Contains("Do not add facts that are absent from the source", prompt);
            Assert.Contains("USER_INDEPENDENT_REGION_START", prompt);
            Assert.Contains(ConceptImportancePrompt.Instructions, prompt);
            Assert.Contains(ConceptLanguagePrompt.Instructions, prompt);
            Assert.Contains(StudyNotationPrompt.Instructions, prompt);
        }
    }
}
