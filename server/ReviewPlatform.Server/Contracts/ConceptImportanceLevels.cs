namespace ReviewPlatform.Server.Contracts;

public static class ConceptImportanceLevels
{
    // Keep camel-case wire values consistent with the client's enum names.
    // Unknown values remain invalid rather than silently becoming medium.
    public static string? Normalize(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "verylow" => "veryLow",
        "low" => "low",
        "medium" => "medium",
        "high" => "high",
        "veryhigh" => "veryHigh",
        _ => null
    };
}
