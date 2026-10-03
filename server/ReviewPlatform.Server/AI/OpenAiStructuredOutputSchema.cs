using System.Text.Json;
using System.Text.Json.Nodes;

namespace ReviewPlatform.Server.AI;

public static class OpenAiStructuredOutputSchema
{
    public static JsonObject Build(object schema)
    {
        // Clone: Ollama still uses the original, more restrictive shared schema.
        var result = JsonSerializer.SerializeToNode(schema,
            new JsonSerializerOptions(JsonSerializerDefaults.Web))!.AsObject();
        Adapt(result);
        return result;
    }

    private static void Adapt(JsonObject schema)
    {
        // OpenAI strict output supports only a JSON Schema subset. Express these
        // constraints as guidance; existing service validation remains authoritative.
        var guidance = new List<string>();
        if (schema.Remove("minLength", out var minimum))
            guidance.Add($"Use at least {minimum} characters.");
        if (schema.Remove("maxLength", out var maximum))
            guidance.Add($"Use at most {maximum} characters.");
        if (schema.Remove("uniqueItems", out var unique) && unique?.GetValue<bool>() == true)
            guidance.Add("Do not repeat array items.");
        if (guidance.Count > 0)
        {
            var existing = schema["description"]?.GetValue<string>();
            schema["description"] = string.Join(" ",
                new[] { existing }.Concat(guidance).Where(value => !string.IsNullOrWhiteSpace(value)));
        }

        // Traverse schema positions only: field names and enum values are data,
        // even if they happen to be named maxLength or uniqueItems.
        foreach (var container in new[] { "properties", "$defs" })
            if (schema[container] is JsonObject children)
                foreach (var child in children.Select(entry => entry.Value).OfType<JsonObject>())
                    Adapt(child);
        if (schema["items"] is JsonObject items)
            Adapt(items);
        if (schema["anyOf"] is JsonArray alternatives)
            foreach (var alternative in alternatives.OfType<JsonObject>())
                Adapt(alternative);
    }
}
