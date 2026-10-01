using System.Text.Json.Nodes;

namespace ReviewPlatform.Server.AI;

public static class QuestionGenerationPrompt
{
    public const string SystemPrompt = """
        Generate review questions based primarily on the supplied SOURCE. You may use general knowledge
        when it helps make the wording, distractors, or simple applications natural, but it must stay within
        the subject and conceptual scope established by SOURCE. Do not introduce off-topic material or an
        entirely new concept that SOURCE does not cover. Every question must still have one clear answer
        that is consistent with SOURCE. Prefer concept checks and simple applications; do not require complex
        calculations. Follow the requested generation mode and quantity instructions exactly.
        Multiple-choice questions need 2-6 unique choices and exactly one choice with isCorrect=true;
        their acceptableAnswers array must always be empty. For every
        trueFalse question, choices must be exactly [{"text":"O","isCorrect":...},{"text":"X","isCorrect":...}]
        in that order, exactly one isCorrect value must be true, and acceptableAnswers must be an empty
        array. Never translate or replace the O and X labels. Short-answer questions need one or more concise
        acceptable answers. Keep every explanation grounded in SOURCE.
        After drafting each question, evaluate its difficulty from the question itself,
        including the cognitive demand, reasoning steps, answer ambiguity, and distractor
        plausibility. Always assign an integer difficulty from 1 (very easy) to 5 (very hard).
        Do not rate difficulty from the source topic alone.
        Every question must contain the exact supplied source reference. Do not generate essay questions.
        Respond in the primary language used by SOURCE and output only data matching the JSON schema.
        """;

    public static string BuildUserPrompt(QuestionGenerationInput input)
    {
        var types = string.Join(", ", input.QuestionTypes);
        var quantityInstructions = input.IsAutomatic
            ? $"""
                Generation mode: automatic
                First identify every distinct, study-worthy key concept explicitly supported by SOURCE.
                Generate {input.MinimumQuestionsPerConcept}-{input.MaximumQuestionsPerConcept} questions for EACH identified concept.
                The total question count is determined by the number of identified concepts; there is no fixed total.
                Cover every identified concept, do not merge unrelated concepts to reduce the count, and avoid duplicate questions.
                """
            : $"""
                Generation mode: manual
                Total question count: {input.QuestionCount}
                Return exactly {input.QuestionCount} questions in total.
                """;
        return $"""
            Source label: {input.SourceLabel ?? "untitled"}
            Source reference (copy exactly into sourceIds): {input.SourceReference}
            Allowed question types: {types}
            Prompt version: {input.PromptVersion}

            {quantityInstructions}

            SOURCE:
            {input.SourceText}
            """;
    }

    public static JsonObject BuildQuestionSchema(QuestionGenerationInput input)
    {
        return new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["properties"] = new JsonObject
            {
                ["questions"] = new JsonObject
                {
                    ["type"] = "array",
                    ["minItems"] = input.MinimumOutputQuestions,
                    ["maxItems"] = input.MaximumOutputQuestions,
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["additionalProperties"] = false,
                        ["properties"] = new JsonObject
                        {
                            ["type"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["enum"] = new JsonArray(
                                    input.QuestionTypes.Select(type =>
                                        (JsonNode?)JsonValue.Create(type)).ToArray())
                            },
                            ["prompt"] = new JsonObject
                            {
                                ["type"] = "string"
                            },
                            ["choices"] = new JsonObject
                            {
                                ["type"] = "array",
                                ["description"] = "For multipleChoice, provide 2-6 unique choices and mark exactly one isCorrect=true. For trueFalse, provide exactly O and X. For shortAnswer, use an empty array.",
                                ["items"] = new JsonObject
                                {
                                    ["type"] = "object",
                                    ["additionalProperties"] = false,
                                    ["properties"] = new JsonObject
                                    {
                                        ["text"] = new JsonObject
                                        {
                                            ["type"] = "string"
                                        },
                                        ["isCorrect"] = new JsonObject
                                        {
                                            ["type"] = "boolean"
                                        }
                                    },
                                    ["required"] = new JsonArray("text", "isCorrect")
                                }
                            },
                            ["acceptableAnswers"] = new JsonObject
                            {
                                ["type"] = "array",
                                ["description"] = "Use an empty array for multipleChoice and trueFalse. Only shortAnswer may contain answer strings.",
                                ["items"] = new JsonObject
                                {
                                    ["type"] = "string"
                                }
                            },
                            ["explanation"] = new JsonObject
                            {
                                ["type"] = new JsonArray("string", "null")
                            },
                            ["difficulty"] = new JsonObject
                            {
                                ["type"] = "integer",
                                ["minimum"] = 1,
                                ["maximum"] = 5,
                                ["description"] = "Difficulty assessed after drafting this question: 1 very easy through 5 very hard."
                            },
                            ["sourceIds"] = new JsonObject
                            {
                                ["type"] = "array",
                                ["minItems"] = 1,
                                ["maxItems"] = 1,
                                ["uniqueItems"] = true,
                                ["items"] = new JsonObject
                                {
                                    ["type"] = "string",
                                    ["enum"] = new JsonArray(input.SourceReference)
                                }
                            }
                        },
                        ["required"] = new JsonArray(
                            "type",
                            "prompt",
                            "choices",
                            "acceptableAnswers",
                            "explanation",
                            "difficulty",
                            "sourceIds")
                    }
                }
            },
            ["required"] = new JsonArray("questions")
        };
    }
}
