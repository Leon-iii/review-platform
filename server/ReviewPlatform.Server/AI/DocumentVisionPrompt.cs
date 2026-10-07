using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class DocumentVisionPrompt
{
    public const string Version = "document-vision-v3-typed-regions";

    private const string ExtractionInstructions = """
        You extract study content from one rendered PDF page image.
        Use only content visibly present in the image.
        Transcribe Korean, Japanese, English, numbers, and mathematical notation faithfully.
        Preserve headings and reading order. Represent tables with compact Markdown.
        Preserve the boundaries of separately titled boxes, callouts, and sidebars, even when
        they appear in the middle of a timeline or narrative. Keep each region's visible title
        and related content together; never interleave its lines with surrounding content.
        Return separate reading-ordered regions for text, diagrams, tables, and uncertain content.
        Set visualRegion=true only for a real separately titled box, callout, or sidebar,
        not decorative borders or a frame around the whole slide. Do not put boundary markers in text.
        Preserve the surrounding reading order and transcribe each passage only once.
        Region kinds describe presentation only: do not classify concepts or evaluate importance.
        kind=text: faithfully transcribe ordinary prose, headings, lists, code, and formulas.
        kind=diagram: record visible labels and observable connections, arrow directions, grouping,
        containment, and legends. Do not invent causal relationships or fill missing labels.
        kind=table: preserve row/column alignment and headers using compact Markdown.
        kind=uncertain: retain legible content and state which labels or relationships cannot
        be read reliably. Never complete the missing information from outside knowledge.
        A page can mix different kinds. Do not classify the whole page as one kind or split
        every label, table cell, or bullet into a separate region. Skip decorative graphics.
        Do not answer questions, explain from outside knowledge, or invent unreadable text.
        If the page is blank or contains no study content, extract no text.
        """;

    public const string SystemPrompt = ExtractionInstructions + "\n" + StudyNotationPrompt.Instructions + "\n" + """
        Return only JSON: {"regions":[{"kind":"text","text":"...","visualRegion":false}]}.
        Use exactly one of the four kind values per region. For a blank page return {"regions":[]}.
        Do not add commentary or code fences, and do not duplicate the same content in multiple regions.
        """;

    public const string StructuredSystemPrompt = SystemPrompt;

    public static object BuildSchema() => new
    {
        type = "object",
        additionalProperties = false,
        properties = new { regions = new {
            type = "array", maxItems = 200,
            items = new {
                type = "object", additionalProperties = false,
                properties = new {
                    kind = new { type = "string", @enum = new[] { "text", "diagram", "table", "uncertain" } },
                    text = new { type = "string" }, visualRegion = new { type = "boolean" }
                },
                required = new[] { "kind", "text", "visualRegion" }
            }
        } },
        required = new[] { "regions" }
    };

    public static string BuildUserPrompt(DocumentVisionInput input) => $"""
        FILE: {input.FileName}
        PAGE: {input.PageNumber}

        Extract all readable study content from this page image.
        Keep formulas and symbols in delimited LaTeX with exact superscript/subscript structure.
        """;

}
