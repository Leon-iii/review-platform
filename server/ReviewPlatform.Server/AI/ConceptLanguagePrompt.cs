namespace ReviewPlatform.Server.AI;

public static class ConceptLanguagePrompt
{
    public const string Instructions = """
        OUTPUT LANGUAGE AND ORIGINAL TERMINOLOGY:
        Write explanations in natural Korean, but retain source English terminology alongside
        the Korean term rather than replacing it with a Korean translation alone.
        Retain concept names, technical terms, algorithms, protocols, methods, component names,
        and abbreviations, not merely the few terms you consider most important.
        If the source supplies a corresponding English term for a concept title, use
        "한국어 제목 (English term)". In EACH concept's content, independently include the
        original term in parentheses on its first occurrence, even if already present in
        the title or an earlier concept. Later repetitions need not repeat the parentheses.
        Preserve source spelling, capitalization, hyphens, proper nouns, standard acronyms,
        code, identifiers, formulas and symbols. Include an acronym's expanded form only
        when the source supplies it. Do not invent absent English terms or expanded forms.
        For an uncertain technical translation, keep the original English term and explain
        it in Korean; do not guess or freely paraphrase it. Do not bilingually duplicate
        ordinary words or entire sentences. These language rules never translate math identifiers.
        """;
}
