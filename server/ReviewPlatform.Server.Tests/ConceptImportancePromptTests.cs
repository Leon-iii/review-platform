using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptImportancePromptTests
{
    [Fact]
    public void ExtractionAndRevisionSchemasUseSameFiveOrderedLevels()
    {
        var extraction = DirectPdfConceptPrompt.Schema(new DirectPdfInput("source", "자료.pdf", [], 1, 64000));
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
        Assert.Contains("Required recall precision", DirectPdfConceptPrompt.SystemPrompt);
        Assert.Contains("Preserve pageNumbers and importance exactly", ConceptRevisionPrompt.SystemPrompt);
    }

    [Fact]
    public void LearningValueCeiling_IsSharedByExtractionAndRevision()
    {
        foreach (var prompt in new[] { DirectPdfConceptPrompt.SystemPrompt, DirectPdfConceptPrompt.SystemPrompt, ConceptRevisionPrompt.SystemPrompt })
        {
            Assert.Contains(ConceptImportancePrompt.Instructions, prompt);
            Assert.Contains("Learning value first", prompt);
            Assert.Contains("veryLow, regardless of how many facts", prompt);
            Assert.Contains("a ceiling, not a weighted score", prompt);
            Assert.Contains("not every fact enumerated", prompt);
            Assert.Contains("explicit evidence", prompt);
            Assert.Contains("Do not invent exam likelihood", prompt);
        }
        Assert.DoesNotContain("Do not make exam likelihood the primary criterion", DirectPdfConceptPrompt.SystemPrompt);
        Assert.DoesNotContain("exam suitability is secondary", ConceptRevisionPrompt.SystemPrompt);
        Assert.Contains("keep all other existing importance values unchanged", ConceptRevisionPrompt.SystemPrompt);
    }

    [Fact]
    public void VeryLowAndLow_DistinguishRetentionValue_NotSmallRecallLoad()
    {
        foreach (var prompt in new[] { DirectPdfConceptPrompt.SystemPrompt, DirectPdfConceptPrompt.SystemPrompt, ConceptRevisionPrompt.SystemPrompt })
        {
            Assert.Contains("if the learner forgets these specific facts", prompt);
            Assert.Contains("If not, and there is no explicit requirement to retain the facts, use veryLow.", prompt);
            Assert.Contains("Reserve low for supporting knowledge that is genuinely worth retaining", prompt);
            Assert.Contains("Do not promote", prompt);
            Assert.Contains("veryLow to low merely because", prompt);
            Assert.Contains("general principle from dispensable details", prompt);
            Assert.DoesNotContain("veryLow or low", prompt);
            Assert.DoesNotContain("or modest necessary recall burden", prompt);
            // Do not introduce concrete source examples that could contaminate generated concepts.
            Assert.DoesNotContain("Swiss", prompt);
            Assert.DoesNotContain("traffic light", prompt);
        }
        Assert.Contains("low requires supporting knowledge worth retaining", ConceptImportancePrompt.SchemaDescription);
        Assert.Contains("never promotes veryLow to low", ConceptImportancePrompt.SchemaDescription);
    }

    [Fact]
    public void ImportanceSchemaDescriptions_UseLearningValueCeilingForAllConceptKinds()
    {
        var extraction = DirectPdfConceptPrompt.Schema(new DirectPdfInput("source", "자료.pdf", [], 1, 64000));
        var revision = ConceptRevisionPrompt.BuildSchema(new ConceptRevisionInput(
            "source", "자료.pdf", 1, "요청",
            [new ConceptRevisionContext("concept", "제목", "내용", [1], "held")],
            ["concept"], ConceptRevisionPrompt.Version, true));
        var direct = DirectPdfConceptPrompt.Schema(new DirectPdfInput("source", "자료.pdf", [], 1, 64000));
        foreach (var (schema, collection) in new[] { (extraction, "concepts"), (direct, "concepts"), (revision, "revisions"), (revision, "additions") })
            Assert.Equal(ConceptImportancePrompt.SchemaDescription,
                schema["properties"]![collection]!["items"]!["properties"]!["importance"]!["description"]!.GetValue<string>());
    }

    [Fact]
    public void RegionBoundariesAndSemanticIndependence_AreUsedWithoutExampleContent()
    {
        var extraction = DirectPdfConceptPrompt.SystemPrompt;
        Assert.Contains("One page can support", extraction);
        Assert.Contains("multiple concepts", extraction);
        Assert.Contains("independent learning purpose", extraction);
        Assert.Contains("not", extraction);
        Assert.Contains("automatic concept boundaries", extraction);
        Assert.Contains("Do not split each timeline date", extraction);
        Assert.DoesNotContain("Cerf", extraction);
        Assert.DoesNotContain("ARPAnet", extraction);
    }

    [Fact]
    public void Examples_AreClassifiedByLearningValueBeforeIndependenceAndScope()
    {
        var prompt = DirectPdfConceptPrompt.SystemPrompt;
        Assert.Contains("learning value,\nsemantic independence, then explanatory scope", prompt.Replace("\r\n", "\n"));
        Assert.Contains("whether another example could", prompt);
        Assert.Contains("forgetting this case's specific facts", prompt);
        Assert.Contains("Illustrative example:", prompt);
        Assert.Contains("integrate the useful illustration naturally", prompt);
        Assert.Contains("Learning-worthy case within its parent:", prompt);
        Assert.Contains("explicitly explain what the learner should understand", prompt);
        Assert.Contains("Independent learning-worthy case:", prompt);
        Assert.Contains("review question beyond isolated trivia", prompt);
        Assert.Contains("Length, visual emphasis, or number of", prompt);
        Assert.Contains("facts alone never justifies promotion", prompt);
        Assert.Contains("Repetition is only a clue", prompt);
        Assert.Contains("source explicitly requires learning them", prompt);
    }

    [Fact]
    public void ExampleHandling_PreservesContextAndProvenanceWithoutInventingStudyRequirements()
    {
        var prompt = DirectPdfConceptPrompt.SystemPrompt;
        Assert.Contains("If learning-value evidence is insufficient", prompt);
        Assert.Contains("without claiming mandatory memorization", prompt);
        Assert.Contains("do not duplicate the case's detailed facts", prompt);
        Assert.Contains("context needed to understand it", prompt);
        Assert.Contains("page numbers for each resulting concept, including across slides", prompt);
        Assert.Contains("Do not add outside facts or invent case details", prompt);
        Assert.Contains("These treatments do not override separation", prompt);
        Assert.Contains(ConceptLanguagePrompt.Instructions, prompt);
        Assert.Contains(StudyNotationPrompt.Instructions, prompt);
        // Policy must not inject the discussion's examples into generated learning content.
        Assert.DoesNotContain("Swiss", prompt);
        Assert.DoesNotContain("traffic light", prompt);
        Assert.DoesNotContain("Cerf", prompt);
        Assert.DoesNotContain("Kahn", prompt);
    }

    [Fact]
    public void IllustrativeDetails_DoNotInflateParentOrSeparatedCaseImportance()
    {
        foreach (var prompt in new[] { DirectPdfConceptPrompt.SystemPrompt, ConceptRevisionPrompt.SystemPrompt })
        {
            Assert.Contains("Rate a parent concept by its learning-worthy knowledge", prompt);
            Assert.Contains("incidental details in embedded illustrative examples", prompt);
            Assert.Contains("not automatically important merely because it was extracted", prompt);
        }
    }
}
