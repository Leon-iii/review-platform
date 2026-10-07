namespace ReviewPlatform.Server.AI;

/// <summary>Lossless notation rules shared by OCR, extraction, revision and generation.</summary>
public static class StudyNotationPrompt
{
    public const string Instructions = """
        MATHEMATICAL NOTATION:
        Superscripts and subscripts carry meaning, not decoration. Preserve their type,
        base, scope, order, and nesting exactly, including multi-character indices.
        Never flatten an index or exponent into baseline text, omit it, or swap its position.
        Encode mathematical notation with LaTeX: use _{...} for subscripts and ^{...}
        for superscripts, retaining braces even for a single-character script.
        Delimit inline math with \(...\) and standalone equations with \[...\].
        Preserve variable names, case, operators, fractions, roots, parentheses, units,
        Greek letters, and symbols; do not translate or rename mathematical identifiers.
        Use \mathrm{...} for upright multi-letter labels, and standard LaTeX commands for
        mathematical structure. Ordinary text, code identifiers and prose underscores
        are not math; do not invent subscripts or superscripts from a name's spelling.
        Preserve existing explicit math notation when reusing source content. When images
        are supplied, use the visible baseline and script placement to resolve text-layer
        flattening. With text-only input, never guess a lost script or its scope.
        If notation cannot be read reliably, mark the specific unreadable part as
        [수식 판독 불확실] and do not invent or silently complete it.
        Escape LaTeX backslashes correctly in JSON strings so the decoded string retains
        each backslash. Never return HTML sup/sub tags or replace math with an image.
        """;
}
