using System.Text.Json;
using System.Text.Json.Nodes;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class ConceptRevisionPrompt
{
    public const string Version = "concept-revision-v5-minimal-change";

    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web);

    public const string SystemPrompt = """
        Revise the selected study concepts according to the user's request. You receive the
        complete selected concepts and compact metadata for sibling concepts from the same PDF
        so that terminology and coverage stay consistent. Only concepts whose IDs are listed
        as editable may be changed. Never invent, remove, merge, or rename concept IDs.
        Make the smallest possible change that fully satisfies the user's request. Preserve every
        unrequested part of the original title and content verbatim. In particular, an append or
        prepend request must retain the entire original text and add only the requested text.
        Preserve pageNumbers and importance exactly unless the user explicitly asks to change
        those fields. Do not use sibling metadata, examples from these instructions, or outside
        knowledge as replacement content. Do not introduce unrelated topics or completely new
        concepts. Return only concepts that actually changed. Write newly added or rewritten text
        in natural Korean while preserving proper nouns, acronyms, code, identifiers, formulas,
        and symbols. Importance, when explicitly changed, must be low, medium, or high. Output
        only the requested JSON.
        """;

    public static string BuildUserPrompt(ConceptRevisionInput input)
    {
        var editable = input.EditableConceptIds.ToHashSet(StringComparer.Ordinal);
        var numbered = input.Concepts.Select((concept, index) => new
        {
            number = index + 1,
            concept
        }).ToList();
        var targetConcepts = JsonSerializer.Serialize(
            numbered.Where(item => editable.Contains(item.concept.Id)).Select(item => new
            {
                item.number,
                item.concept.Id,
                item.concept.Title,
                item.concept.Content,
                item.concept.PageNumbers,
                item.concept.Status,
                item.concept.Importance
            }),
            JsonOptions);
        var contextConcepts = JsonSerializer.Serialize(
            numbered.Where(item => !editable.Contains(item.concept.Id)).Select(item => new
            {
                item.number,
                item.concept.Id,
                item.concept.Title,
                item.concept.PageNumbers,
                item.concept.Status,
                item.concept.Importance
            }),
            JsonOptions);
        var editableIds = JsonSerializer.Serialize(
            input.EditableConceptIds,
            JsonOptions);
        return $"""
            Source ID: {input.SourceId}
            File name: {input.FileName}
            PDF page count: {input.PageCount}
            Prompt version: {input.PromptVersion}

            USER REVISION REQUEST:
            {input.Instruction}

            EDITABLE CONCEPT IDS:
            {editableIds}

            TARGET CONCEPTS TO REVISE (complete content):
            {targetConcepts}

            OTHER CONCEPTS FOR CONTEXT (metadata only, never revise these):
            {contextConcepts}

            A phrase such as "1번 개념" refers to the concept whose number is 1.
            Return only revisions that actually differ from the supplied concept.
            Copy every field and every passage not explicitly targeted by the request exactly
            from the target concept. Never replace target content with sibling context.
            """;
    }

    public static JsonObject BuildSchema(ConceptRevisionInput input)
    {
        var ids = input.EditableConceptIds
            .Select(id => (JsonNode?)JsonValue.Create(id))
            .ToArray();
        return new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["properties"] = new JsonObject
            {
                ["revisions"] = new JsonObject
                {
                    ["type"] = "array",
                    ["minItems"] = 0,
                    ["maxItems"] = input.EditableConceptIds.Count,
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object",
                        ["additionalProperties"] = false,
                        ["properties"] = new JsonObject
                        {
                            ["id"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["enum"] = new JsonArray(ids)
                            },
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
                                    ["minimum"] = 1,
                                    ["maximum"] = input.PageCount
                                }
                            },
                            ["importance"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["enum"] = new JsonArray("low", "medium", "high"),
                                ["description"] = "Prioritize memorization load and required recall precision; exam suitability is secondary."
                            }
                        },
                        ["required"] = new JsonArray(
                            "id",
                            "title",
                            "content",
                            "pageNumbers",
                            "importance")
                    }
                }
            },
            ["required"] = new JsonArray("revisions")
        };
    }
}
