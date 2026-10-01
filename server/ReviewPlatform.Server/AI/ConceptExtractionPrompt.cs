using System.Text.Json.Nodes;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class ConceptExtractionPrompt
{
    public const string Version = "concept-extraction-v6-memorization-importance";
    public const int MaximumConceptsPerRequest = 8;

    public const string SystemPrompt = """
        Extract distinct, study-worthy concepts using only the supplied PDF page text.
        Do not add facts that are absent from the source. Each concept needs a concise title,
        self-contained study content, and every page number that directly
        supports it. Merge repeated explanations of the same concept, but keep unrelated
        concepts separate. Ignore headers, footers, page numbers, and table-of-contents noise.
        Return at most 8 of the most study-worthy concepts for this page batch. Keep each
        content concise and focused on the supplied pages.
        Evaluate importance in this strict priority order:
        1. Memorization load: the number of independent facts, entries, mappings, rules,
           formulas, cases, symbols, or steps that must be retained.
        2. Required recall precision: how exactly those elements must be reproduced for a
           correct answer, including notation, order, wording, conditions, and table mappings.
        3. Only after those two, use suitability and likelihood for testing learner competence
           as a secondary tie-breaker. Do not make exam likelihood the primary criterion.
        Assign "high" when there are many independent memorization elements, when exact recall of
        notation, sequence, conditions, or mappings is critical, or both. Do not rate content high
        merely because it is lengthy when approximate recall is sufficient. Use "medium" for
        moderate load or precision, and "low" when both are low.
        Write every title and content field in natural Korean regardless of the
        source language. For an important technical term, use "한국어 (original term)" on
        its first occurrence. Preserve proper nouns, standard acronyms, code, identifiers,
        formulas, and symbols in their original form. Do not guess or freely paraphrase an
        uncertain technical translation. Output only the requested JSON.
        """;

    public static string BuildUserPrompt(ConceptExtractionInput input)
    {
        var pages = string.Join(
            "\n\n",
            input.Pages.Select(page => $"[PAGE {page.PageNumber}]\n{page.Text}"));
        return $"""
            Source ID: {input.SourceId}
            File name: {input.FileName}
            Prompt version: {input.PromptVersion}

            OUTPUT LANGUAGE:
            - Write title and content in Korean.
            - Preserve important original technical terms in parentheses on first use.
            - Keep proper nouns, acronyms, code, identifiers, formulas, and symbols unchanged.

            PDF PAGE TEXT:
            {pages}
            """;
    }

    public static JsonObject BuildSchema(ConceptExtractionInput input)
    {
        var pageNumbers = input.Pages
            .Select(page => page.PageNumber)
            .Distinct()
            .Select(page => (JsonNode?)JsonValue.Create(page))
            .ToArray();
        return new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["properties"] = new JsonObject
            {
                ["concepts"] = new JsonObject
                {
                    ["type"] = "array",
                    ["minItems"] = 1,
                    ["maxItems"] = MaximumConceptsPerRequest,
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["additionalProperties"] = false,
                        ["properties"] = new JsonObject
                        {
                            ["title"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["maxLength"] = 200
                            },
                            ["content"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["maxLength"] = 8_000
                            },
                            ["pageNumbers"] = new JsonObject
                            {
                                ["type"] = "array",
                                ["minItems"] = 1,
                                ["uniqueItems"] = true,
                                ["items"] = new JsonObject
                                {
                                    ["type"] = "integer",
                                    ["enum"] = new JsonArray(pageNumbers)
                                }
                            },
                            ["importance"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["enum"] = new JsonArray("low", "medium", "high"),
                                ["description"] = "Importance prioritized by memorization element count and required recall precision; exam suitability is secondary."
                            }
                        },
                        ["required"] = new JsonArray(
                            "title",
                            "content",
                            "pageNumbers",
                            "importance")
                    }
                }
            },
            ["required"] = new JsonArray("concepts")
        };
    }
}
