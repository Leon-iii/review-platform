using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class QuestionGenerationPromptTests
{
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
