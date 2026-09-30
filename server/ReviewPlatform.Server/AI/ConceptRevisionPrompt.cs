using System.Text.Json;
using System.Text.Json.Nodes;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class ConceptRevisionPrompt
{
    public const string Version = "concept-revision-v1";

    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web);

    public const string SystemPrompt = """
        Revise study concepts according to the user's request. You receive every concept
        from one PDF so that terminology and coverage stay consistent. Only concepts whose
        IDs are listed as editable may be changed. Never invent, remove, merge, or rename
        concept IDs. Do not introduce unrelated topics or completely new concepts. Return
        only concepts whose title, content, or supporting page numbers actually need to
        change. Write titles and content in natural Korean while preserving proper nouns,
        acronyms, code, identifiers, formulas, and symbols. Output only the requested JSON.
        """;

    public static string BuildUserPrompt(ConceptRevisionInput input)
    {
        var concepts = JsonSerializer.Serialize(input.Concepts, JsonOptions);
        var editableIds = JsonSerializer.Serialize(
            input.EditableConceptIds,
            JsonOptions);
        return $"""
            Source ID: {input.SourceId}
            File name: {input.FileName}
            PDF page count: {input.PageCount}
            Prompt version: {input.PromptVersion}
            Revision scope: {input.Scope}

            USER REVISION REQUEST:
            {input.Instruction}

            EDITABLE CONCEPT IDS:
            {editableIds}

            ALL CONCEPTS FOR CONTEXT:
            {concepts}

            Return only revisions that actually differ from the supplied concept.
            Keep each revision grounded in the supplied concepts and user request.
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
                            }
                        },
                        ["required"] = new JsonArray(
                            "id",
                            "title",
                            "content",
                            "pageNumbers")
                    }
                }
            },
            ["required"] = new JsonArray("revisions")
        };
    }
}
