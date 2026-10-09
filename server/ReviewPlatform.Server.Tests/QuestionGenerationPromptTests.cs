using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class QuestionGenerationPromptTests
{
    [Theory]
    [InlineData(false, "manual")]
    [InlineData(true, "manual")]
    [InlineData(false, "automatic")]
    [InlineData(true, "automatic")]
    public void QuestionsRequireIndependentContextWithoutLeakingAnswers(bool bind, string mode)
    {
        var input = Input(bind) with { GenerationMode = mode };
        var prompt = QuestionGenerationPrompt.GetSystemPrompt(input);
        Assert.Contains("QUESTION CONTEXT AND INDEPENDENCE", prompt);
        Assert.Contains("concept title, or any other question", prompt);
        Assert.Contains("subject,", prompt);
        Assert.Contains("situation, premises, scope, and conditions", prompt);
        Assert.Contains("protocol or algorithm variants", prompt);
        Assert.Contains("variable meanings, units", prompt);
        Assert.Contains("referent is explicitly established within this question", prompt);
        Assert.Contains("Put essential context in prompt, not only in explanation", prompt);
        Assert.Contains("do not reveal the correct answer", prompt);
        Assert.Contains("supply the definition or rule being assessed", prompt);
        Assert.Contains("never hide answer-changing assumptions", prompt);
        Assert.Contains("Provide only the context needed", prompt);
        Assert.Contains("pad every question with a long introduction", prompt);
        Assert.Contains("Repair unclear subjects, missing premises, and ambiguous conditions", prompt);
        Assert.Contains("Do not return this internal check or extra context fields", prompt);
        var fields = QuestionGenerationPrompt.BuildQuestionSchema(input)
            ["properties"]!["questions"]!["items"]!["properties"]!.AsObject();
        var description = fields["prompt"]!["description"]!.GetValue<string>();
        Assert.Contains("Self-contained question", description);
        Assert.Contains("not only in explanation", description);
        Assert.Contains("No unresolved references, answer leakage, or unnecessary background", description);
        Assert.DoesNotContain("context", fields.Select(field => field.Key));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AutomaticCoversMeaningfulObjectivesBeforePracticeWithoutReturningPlan(bool bind)
    {
        var input = Input(bind) with { GenerationMode = "automatic", AutomaticDensity = "low" };
        var prompt = QuestionGenerationPrompt.GetSystemPrompt(input);
        Assert.Contains("Assess every objective at least once before adding practice questions", prompt);
        Assert.Contains("only when answering a question requires that knowledge", prompt);
        Assert.Contains("Do not treat every sentence", prompt);
        Assert.Contains("independent learning value", prompt);
        Assert.Contains("never cram unrelated objectives", prompt);
        Assert.Contains("remove extra practice first", prompt);
        Assert.Contains("Repair omissions within the cap", prompt);
        Assert.Contains("Do not return the internal", prompt);
        Assert.Contains("full coverage is not guaranteed within a fixed count", prompt);
        var fields = QuestionGenerationPrompt.BuildQuestionSchema(input)["properties"]!["questions"]!["items"]!["properties"]!.AsObject();
        Assert.DoesNotContain("coverage", fields.Select(f => f.Key));
        Assert.DoesNotContain("objectives", fields.Select(f => f.Key));
        Assert.Null(input.PlannedQuestionCount);
        Assert.Equal(120, input.MaximumOutputQuestions);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void TypesAreChosenPerObjectiveWithoutQuotasOrReturnedReasons(bool bind)
    {
        var input = Input(bind);
        var prompt = QuestionGenerationPrompt.GetSystemPrompt(input);
        Assert.Contains("Choose per question, not once for", prompt);
        Assert.Contains("candidate pool, not quotas", prompt);
        Assert.Contains("Do not distribute types equally", prompt);
        Assert.Contains("force every allowed type to appear", prompt);
        Assert.Contains("paraphrasing the same question", prompt);
        Assert.Contains("Choose trueFalse for a clearly decidable factual claim or condition", prompt);
        Assert.Contains("Choose multipleChoice to distinguish similar", prompt);
        Assert.Contains("plausible, clearly incorrect", prompt);
        Assert.Contains("Choose shortAnswer to recall one specific word or term", prompt);
        Assert.Contains("Choose ordering only for a", prompt);
        Assert.Contains("Choose essay when the objective genuinely requires", prompt);
        Assert.Contains("Do not choose essay merely to increase difficulty", prompt);
        Assert.Contains("Basic coverage is independent of concept importance and density", prompt);
        Assert.Contains("Do not return selection reasons, comments, or extra fields", prompt);
        var userPrompt = QuestionGenerationPrompt.BuildUserPrompt(input);
        Assert.Contains("learning objective", userPrompt);
        Assert.Contains("no allowed type is suitable", userPrompt);
        var array = QuestionGenerationPrompt.BuildQuestionSchema(input)["properties"]!["questions"]!;
        Assert.True(array["minItems"] is null || array["minItems"]!.GetValue<int>() == 0);
        var fields = array["items"]!["properties"]!.AsObject();
        Assert.Equal(bind ? 7 : 8, fields.Count);
        Assert.DoesNotContain("selectionReason", fields.Select(field => field.Key));
        Assert.DoesNotContain("comment", fields.Select(field => field.Key));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void GenerationPromptsRequireHaeraCheWithoutChangingAnswerFormats(bool bindConceptOnServer)
    {
        var prompt = QuestionGenerationPrompt.GetSystemPrompt(Input(bindConceptOnServer));
        Assert.Contains("every question prompt and sentence-form choice in Korean haera-che (해라체)", prompt);
        Assert.Contains("~이다.", prompt);
        Assert.Contains("~해라.", prompt);
        Assert.Contains("~인가?", prompt);
        Assert.Contains("Do not mix in polite or formal endings", prompt);
        Assert.Contains("do not copy SOURCE's tone when it conflicts", prompt);
        Assert.Contains("Bare word/term choices may remain words/terms", prompt);
        Assert.Contains("Keep trueFalse labels exactly O and X", prompt);
        Assert.Contains("Do not rewrite shortAnswer acceptableAnswers to fit this tone", prompt);
        Assert.Contains("valid aliases", prompt);
        Assert.Contains("for other fields", prompt);
        Assert.DoesNotContain("Respond in the primary language used by SOURCE and output", prompt);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SchemaDescribesTheSameStyleForQuestionAndChoiceFields(bool bindConceptOnServer)
    {
        var fields = QuestionGenerationPrompt.BuildQuestionSchema(Input(bindConceptOnServer))
            ["properties"]!["questions"]!["items"]!["properties"]!;
        var questionStyle = fields["prompt"]!["description"]!.GetValue<string>();
        var choiceStyle = fields["choices"]!["items"]!["properties"]!["text"]!["description"]!
            .GetValue<string>();
        Assert.Contains("haera-che (해라체)", questionStyle);
        Assert.Contains("~해라.", questionStyle);
        Assert.Contains("~인가?", questionStyle);
        Assert.Contains("haera-che (해라체)", choiceStyle);
        Assert.Contains("Bare words/terms need no sentence ending", choiceStyle);
        Assert.Contains("exactly O and X", choiceStyle);
        Assert.Contains("as many unambiguously valid synonyms",
            fields["acceptableAnswers"]!["description"]!.GetValue<string>());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Ordering_HasNoDistractors_AndUsesRequiredOneBasedPermutation(bool bind)
    {
        var prompt = QuestionGenerationPrompt.GetSystemPrompt(Input(bind));
        Assert.Contains("exactly 3-6 distinct steps", prompt);
        Assert.Contains("never include", prompt);
        Assert.Contains("distractors or optional steps", prompt);
        Assert.Contains("simultaneous, branching, reversible, or interchangeable", prompt);
        Assert.Contains("1-based array positions", prompt);
        var input = Input(bind) with { QuestionTypes = ["ordering"] };
        var item = QuestionGenerationPrompt.BuildQuestionSchema(input)["properties"]!["questions"]!["items"]!;
        Assert.Contains("ordering", item["properties"]!["type"]!["enum"]!.ToJsonString());
        Assert.Contains("correctOrder", item["required"]!.ToJsonString());
        Assert.Equal("integer", item["properties"]!["correctOrder"]!["items"]!["type"]!.GetValue<string>());
    }

    private static QuestionGenerationInput Input(bool bindConceptOnServer) => new(
        "Web caches return cached objects to clients.", 1,
        ["multipleChoice", "trueFalse", "shortAnswer", "essay"], "자료",
        QuestionGenerationService.PromptVersion,
        ConceptPlans: bindConceptOnServer
            ? [new(new("concept-one", "웹 캐시", "캐시에서 객체를 반환한다."), 1)] : null,
        BindConceptOnServer: bindConceptOnServer);
}
