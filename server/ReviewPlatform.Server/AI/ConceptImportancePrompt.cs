namespace ReviewPlatform.Server.AI;

public static class ConceptImportancePrompt
{
    public const string SchemaDescription =
        "Judge whether the content is worth retaining first. Use veryLow for dispensable example-specific details; low requires supporting knowledge worth retaining. A small memorization load never promotes veryLow to low. Assess necessary recall load and precision only within the learning-value ceiling.";

    public const string Instructions = """
        Evaluate importance separately for each independent concept in two stages:
        1. Learning value first: does it support core understanding, application, problem solving,
           or meaningful assessment of learner competence in the supplied material?
           First ask: if the learner forgets these specific facts but understands the general
           principle, would core understanding, application, or problem solving be impaired?
           If not, and there is no explicit requirement to retain the facts, use veryLow.
           Distinguish a general principle from dispensable details of the example illustrating it.
           The value of explaining a principle through an example does not make the example's
           particular names, locations, colors, counts, or sequence worth memorizing.
           Peripheral trivia, isolated historical dates, names, counts, and incidental details
           without a meaningful connection to core understanding or application must stay
           veryLow, regardless of how many facts they contain or how precisely they could be
           memorized. Reserve low for supporting knowledge that is genuinely worth retaining
           but has limited learning priority. This is a ceiling, not a weighted score that quantity can offset.
           An exception requires explicit evidence in the supplied learning objectives, assessment
           scope, or user request that those details must be learned. Mere presence on a slide,
           a box, table, bold text, or a long list is not such evidence. Do not invent exam likelihood.
        2. Within that learning-value ceiling, evaluate necessary memorization burden:
           Only proceed after deciding that the content is worth retaining. Do not promote
           veryLow to low merely because a short fact or a simple sequence is easy to memorize.
           - Memorization load: count independent memorization elements that must actually be
             retained to understand or use the concept, not every fact enumerated in its content.
           - Required recall precision: how exactly those necessary elements must be reproduced,
             including notation, order, conditions, wording, and mappings. Do not assume verbatim
             recall is required merely because the source contains exact dates or detailed wording.
        Use exactly one of five importance levels:
        - "veryLow": dispensable background, peripheral trivia, or example-specific details
          that can be forgotten without impairing core understanding or problem solving;
          neither numerous facts nor a small memorization load raises this rating.
        - "low": supporting knowledge worth retaining, but with limited learning priority.
          A modest necessary recall burden alone is not sufficient to assign this level.
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
