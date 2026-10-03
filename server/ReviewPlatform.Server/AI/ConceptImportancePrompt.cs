namespace ReviewPlatform.Server.AI;

public static class ConceptImportancePrompt
{
    public const string SchemaDescription =
        "Judge learning value first. Peripheral trivia stays veryLow or low regardless of memorization load; assess necessary recall load and precision only within that learning-value ceiling.";

    public const string Instructions = """
        Evaluate importance separately for each independent concept in two stages:
        1. Learning value first: does it support core understanding, application, problem solving,
           or meaningful assessment of learner competence in the supplied material?
           Distinguish peripheral background from knowledge the learner actually needs to retain.
           Peripheral trivia, isolated historical dates, names, counts, and incidental details
           without a meaningful connection to core understanding or application must stay
           veryLow or low, regardless of how many facts they contain or how precisely they
           could be memorized. This is a ceiling, not a weighted score that quantity can offset.
           An exception requires explicit evidence in the supplied learning objectives, assessment
           scope, or user request that those details must be learned. Mere presence on a slide,
           a box, table, bold text, or a long list is not such evidence. Do not invent exam likelihood.
        2. Within that learning-value ceiling, evaluate necessary memorization burden:
           - Memorization load: count independent memorization elements that must actually be
             retained to understand or use the concept, not every fact enumerated in its content.
           - Required recall precision: how exactly those necessary elements must be reproduced,
             including notation, order, conditions, wording, and mappings. Do not assume verbatim
             recall is required merely because the source contains exact dates or detailed wording.
        Use exactly one of five importance levels:
        - "veryLow": incidental background or peripheral trivia with negligible learning value;
          numerous enumerated facts do not raise this rating.
        - "low": supporting context with limited learning value, or modest necessary recall burden.
        - "medium": meaningful understanding or application with moderate necessary recall burden;
          also use a cautious rating when evidence does not justify a stronger claim.
        - "high": core, meaningfully assessable knowledge with substantial necessary memorization
          load or critical exact recall requirements.
        - "veryHigh": core, meaningfully assessable knowledge with exceptionally many necessary
          elements, exceptionally demanding exact recall, or both high load and high precision.
        Never rate importance high or veryHigh solely for length, a dense table, a timeline, a
        decorative box, or difficult memorization. Assess separated concepts independently:
        a valuable concept does not raise the importance of adjacent peripheral background.
        """;
}
