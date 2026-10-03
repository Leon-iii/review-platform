using System.Text.Json.Nodes;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class ConceptExtractionPrompt
{
    public const string Version = "concept-extraction-v10-typed-regions";
    public const int MaximumConceptsPerRequest = 8;

    public const string SystemPrompt = """
        Extract distinct, study-worthy concepts using only the supplied PDF page text.
        Do not add facts that are absent from the source. Each concept needs a concise title,
        self-contained study content, and every page number that directly
        supports it. Merge repeated explanations of the same concept, but keep unrelated
        concepts separate. Ignore headers, footers, page numbers, and table-of-contents noise.
        Return at most 8 of the most study-worthy concepts for this page batch. Keep each
        content concise and focused on the supplied pages.
        Split by semantic independence, not by page or visual container. One page can support
        multiple concepts, and different concepts can share the same source page number.
        Before rating importance, separate material with a different learning purpose that can
        have its own self-contained title, explanation, and meaningful review question.
        A definition, principle, or mechanism inserted into a timeline, case study, or surrounding
        narrative must be a separate concept when it has that independent learning purpose.
        [VISUAL_REGION_START] and [VISUAL_REGION_END] mark boundaries of a visible box,
        callout, or sidebar, not an automatic instruction to create a concept. Use these boundaries
        as clues: keep a region's related content together, but retain supporting examples and
        caveats with their parent concept when they do not introduce independent knowledge.
        Apply the same semantic test to text-only pages where no region markers are available.
        [USER_INDEPENDENT_REGION_START] and [USER_INDEPENDENT_REGION_END] identify a region
        explicitly marked independent by the user. Keep its concept(s) separate from surrounding
        regions; never merge it back into an adjacent timeline or narrative. This user boundary
        does not imply high importance: evaluate its learning value independently. User-reviewed
        page text is the authoritative source; do not reinsert excluded passages from outside
        knowledge. Never copy user boundary markers into the final title or content.
        [CONTENT_KIND:diagram], [CONTENT_KIND:table], and [CONTENT_KIND:uncertain] with
        [/CONTENT_KIND] label region presentation, not concept independence or importance.
        For diagrams preserve only observed labels, directions, grouping and relationships;
        never infer a missing connection or new causal explanation. For tables preserve
        row/column associations. For uncertain regions use only the legible facts, retain
        limitations when relevant, and omit claims that require guessing unreadable content.
        Never copy kind markers into the final title or content. User kind corrections do not
        imply changes to independent-region boundaries or importance.
        Do not split each timeline date, table entry, bullet, or step into its own concept.
        Visual transcription and the text layer may repeat the same content; reconcile them
        without duplicating facts or concepts. Never copy extraction boundary markers into the
        final title or content. Only reference pages that directly support each concept.
        """ + "\n" + ConceptImportancePrompt.Instructions + "\n" + """
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
                                ["enum"] = new JsonArray("veryLow", "low", "medium", "high", "veryHigh"),
                                ["description"] = ConceptImportancePrompt.SchemaDescription
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
