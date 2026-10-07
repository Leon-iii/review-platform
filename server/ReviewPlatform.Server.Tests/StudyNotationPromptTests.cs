using System.Text.Json;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class StudyNotationPromptTests
{
    [Fact]
    public void AllAiPathsShareLosslessMathRules()
    {
        foreach (var prompt in new[] {
            ConceptExtractionPrompt.SystemPrompt, ConceptExtractionPrompt.OllamaSystemPrompt, DirectPdfConceptPrompt.SystemPrompt,
            ConceptRevisionPrompt.SystemPrompt, DocumentVisionPrompt.SystemPrompt,
            DocumentVisionPrompt.StructuredSystemPrompt, QuestionGenerationPrompt.SystemPrompt,
            QuestionGenerationPrompt.ConceptSystemPrompt })
        {
            Assert.Contains(StudyNotationPrompt.Instructions, prompt);
            Assert.Contains("Never flatten an index or exponent", prompt);
            Assert.Contains(@"_{...}", prompt);
            Assert.Contains(@"^{...}", prompt);
            Assert.Contains(@"\(...\)", prompt);
            Assert.Contains(@"\[...\]", prompt);
            Assert.Contains("[수식 판독 불확실]", prompt);
            Assert.Contains("never guess a lost script", prompt);
        }
        // Instructions contain no source-specific example concepts.
        Assert.DoesNotContain("Performance", StudyNotationPrompt.Instructions);
    }

    [Fact]
    public void KoreanConceptsRetainOriginalTermsPerTitleAndPerConceptBody()
    {
        foreach (var prompt in new[] {
            ConceptExtractionPrompt.SystemPrompt, ConceptExtractionPrompt.OllamaSystemPrompt, DirectPdfConceptPrompt.SystemPrompt,
            ConceptRevisionPrompt.SystemPrompt })
        {
            Assert.Contains(ConceptLanguagePrompt.Instructions, prompt);
            Assert.Contains("In EACH concept's content", prompt);
            Assert.Contains("even if already present in", prompt);
            Assert.Contains("Do not invent absent English terms", prompt);
            Assert.Contains("only", ConceptLanguagePrompt.Instructions);
            Assert.Contains("These language rules never translate math identifiers", prompt);
        }
        Assert.Contains("do not rewrite untouched passages", ConceptRevisionPrompt.SystemPrompt);
    }

    [Fact]
    public void ExtractedSourceAndRevisionDataRetainBackslashesAndScriptScopeThroughJson()
    {
        const string notation = @"성능 (Performance): \(\mathrm{Performance}_{X} = \frac{1}{T_{X}}\), \[a_{i,j}^{(k)}\]";
        var extraction = ConceptExtractionPrompt.BuildUserPrompt(new ConceptExtractionInput(
            "source", "notation.pdf", [new ExtractedDocumentPage(1, notation)], ConceptExtractionPrompt.Version));
        Assert.Contains(notation, extraction);
        var revision = ConceptRevisionPrompt.BuildUserPrompt(new ConceptRevisionInput(
            "source", "notation.pdf", 1, "표현만 정리",
            [new ConceptRevisionContext("concept", "성능 (Performance)", notation, [1], "held")],
            ["concept"], ConceptRevisionPrompt.Version));
        var targetJson = revision.Split("TARGET CONCEPTS TO REVISE (complete content):\n", 2)[1]
            .Split("\n\nOTHER CONCEPTS FOR CONTEXT", 2)[0].Trim();
        using var targets = JsonDocument.Parse(targetJson);
        Assert.Equal(notation, targets.RootElement[0].GetProperty("content").GetString());
        // JSON escaping is transport encoding, not a replacement of stored notation.
        Assert.Equal(notation, JsonSerializer.Deserialize<string>(JsonSerializer.Serialize(notation)));
    }
}
