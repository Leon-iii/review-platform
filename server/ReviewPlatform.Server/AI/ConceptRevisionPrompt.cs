using System.Text.Json;
using System.Text.Json.Nodes;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class ConceptRevisionPrompt
{
    public const string Version = "concept-revision-v8-confirmed-changes";
    public const int MaximumAdditions = 20;

    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web);

    public const string SystemPrompt = """
        Revise the selected study concepts according to the user's request. You receive the
        complete selected concepts and compact metadata for sibling concepts from the same material
        so that terminology and coverage stay consistent. Only concepts whose IDs are listed
        as editable may be revised or proposed for deletion. Never rename existing concept IDs.
        Make the smallest possible change that fully satisfies the user's request. Preserve every
        unrequested part of the original title and content verbatim. In particular, an append or
        prepend request must retain the entire original text and add only the requested text.
        Preserve pageNumbers and importance exactly unless the user explicitly asks to change
        those fields. Empty pageNumbers identifies a user-authored concept without PDF provenance:
        always keep that array empty, even when the material also contains PDF-extracted concepts.
        Never remove all pages from a PDF-extracted concept. A page count of zero means a material
        with no PDF, not a missing or unreadable PDF. Do not use sibling metadata, examples from these instructions, or outside
        knowledge as replacement content. New concepts, including entirely new topics, are allowed
        only when additions are enabled AND the user's request calls for them. Never add unrelated
        or unsolicited concepts. Deletion is allowed only when deletions are enabled AND the user
        requests it; return an explicit deletion with its reason, never infer deletion from omission.
        Untouched concepts must remain unchanged and omitted from the response.
        Return three arrays: revisions, additions, deletions. Revisions contain complete rewritten
        fields, not restricted edit commands. Additions have no existing ID. Use empty pageNumbers
        for new concepts without direct PDF evidence; never invent PDF provenance. Nonempty pages
        on additions must come from the selected concepts and genuinely support the new content.
        For splitting, merging, or dependent replacement, give ALL related changes the same nonempty
        groupId so the user can accept or reject the complete group. Independent changes use an empty
        groupId. Never both revise and delete the same existing ID. Avoid duplicate concepts.
        Evaluate importance for every new concept using the memorization criteria below.
        Return only concepts that actually changed. Write newly added or rewritten text
        in natural Korean while preserving proper nouns, acronyms, code, identifiers, formulas,
        and symbols. Importance, when explicitly changed, must be veryLow, low, medium, high,
        or veryHigh. When evaluating importance, prioritize memorization element count and required
        recall precision; exam suitability is secondary. veryLow means minimal elements and only
        approximate understanding is needed; veryHigh means exceptional memorization load or exact
        recall requirements, or both high load and high precision. Output
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
            Material name: {input.FileName}
            Page count (0 = no PDF): {input.PageCount}
            Prompt version: {input.PromptVersion}
            Allow new concepts: {input.AllowAdditions}
            Allow deletions: {input.AllowDeletions}
            Maximum new concepts in this request: {MaximumAdditions}

            USER REVISION REQUEST:
            {input.Instruction}

            EDITABLE CONCEPT IDS:
            {editableIds}

            TARGET CONCEPTS TO REVISE (complete content):
            {targetConcepts}

            OTHER CONCEPTS FOR CONTEXT (metadata only, never revise these):
            {contextConcepts}

            A phrase such as "1번 개념" refers to the concept whose number is 1.
            Return only requested changes. The three arrays must always be present, even when empty.
            Copy every field and every passage not explicitly targeted by the request exactly
            from the target concept. Never replace target content with sibling context.
            """;
    }

    public static JsonObject BuildSchema(ConceptRevisionInput input)
    {
        var ids = input.EditableConceptIds
            .Select(id => (JsonNode?)JsonValue.Create(id))
            .ToArray();
        JsonObject IdSchema() => ids.Length == 0
            ? new JsonObject { ["type"] = "string" }
            : new JsonObject { ["type"] = "string", ["enum"] = new JsonArray(ids.Select(id => id!.DeepClone()).ToArray()) };
        JsonObject GroupSchema() => new() { ["type"] = "string", ["maxLength"] = 100 };
        JsonObject ReasonSchema() => new() { ["type"] = "string", ["maxLength"] = 1000 };
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
                            ["id"] = IdSchema(),
                            ["groupId"] = GroupSchema(),
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
                                ["minItems"] = input.Concepts.Any(concept => concept.PageNumbers.Count == 0) ? 0 : 1,
                                ["maxItems"] = input.PageCount,
                                ["uniqueItems"] = true,
                                ["items"] = new JsonObject
                                {
                                    ["type"] = "integer",
                                    ["minimum"] = 1,
                                    ["maximum"] = Math.Max(1, input.PageCount)
                                }
                            },
                            ["importance"] = new JsonObject
                            {
                                ["type"] = "string",
                                ["enum"] = new JsonArray("veryLow", "low", "medium", "high", "veryHigh"),
                                ["description"] = "Prioritize memorization load and required recall precision; exam suitability is secondary."
                            }
                        },
                        ["required"] = new JsonArray(
                            "id",
                            "title",
                            "content",
                            "pageNumbers",
                            "importance", "groupId")
                    }
                },
                ["additions"] = new JsonObject
                {
                    ["type"] = "array", ["minItems"] = 0,
                    ["maxItems"] = input.AllowAdditions ? MaximumAdditions : 0,
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object", ["additionalProperties"] = false,
                        ["properties"] = new JsonObject
                        {
                            ["title"] = new JsonObject { ["type"] = "string", ["maxLength"] = 200 },
                            ["content"] = new JsonObject { ["type"] = "string", ["maxLength"] = 8000 },
                            ["importance"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("veryLow", "low", "medium", "high", "veryHigh") },
                            ["pageNumbers"] = new JsonObject
                            {
                                ["type"] = "array", ["minItems"] = 0, ["maxItems"] = input.PageCount,
                                ["items"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1, ["maximum"] = Math.Max(1, input.PageCount) }
                            },
                            ["groupId"] = GroupSchema(), ["reason"] = ReasonSchema()
                        },
                        ["required"] = new JsonArray("title", "content", "importance", "pageNumbers", "groupId", "reason")
                    }
                },
                ["deletions"] = new JsonObject
                {
                    ["type"] = "array", ["minItems"] = 0,
                    ["maxItems"] = input.AllowDeletions ? input.EditableConceptIds.Count : 0,
                    ["items"] = new JsonObject
                    {
                        ["type"] = "object", ["additionalProperties"] = false,
                        ["properties"] = new JsonObject { ["id"] = IdSchema(), ["reason"] = ReasonSchema(), ["groupId"] = GroupSchema() },
                        ["required"] = new JsonArray("id", "reason", "groupId")
                    }
                },
            },
            ["required"] = new JsonArray("revisions", "additions", "deletions")
        };
    }
}
