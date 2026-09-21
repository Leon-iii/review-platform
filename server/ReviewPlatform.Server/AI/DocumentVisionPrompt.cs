using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.AI;

public static class DocumentVisionPrompt
{
    public const string Version = "document-vision-v1";

    public const string SystemPrompt = """
        You extract study content from one rendered PDF page image.
        Use only content visibly present in the image.
        Transcribe Korean, Japanese, English, numbers, and mathematical notation faithfully.
        Preserve headings and reading order. Represent tables with compact Markdown.
        Describe a diagram only when its labels or relationships contain study information.
        Do not answer questions, explain from outside knowledge, or invent unreadable text.
        If the page is blank or contains no study content, return an empty response.
        Return only the extracted text. Do not wrap it in JSON or Markdown code fences.
        """;

    public static string BuildUserPrompt(DocumentVisionInput input) => $"""
        FILE: {input.FileName}
        PAGE: {input.PageNumber}

        Extract all readable study content from this page image.
        Keep formulas and symbols as plain text or Markdown-compatible notation.
        """;

}
