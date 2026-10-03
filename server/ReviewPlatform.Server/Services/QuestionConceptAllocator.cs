using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public static class QuestionConceptAllocator
{
    public static IReadOnlyList<QuestionConceptPlan> Allocate(
        IReadOnlyList<QuestionGenerationConcept>? supplied, bool reflectImportance,
        bool automatic, string? density, int manualCount, int limit)
    {
        if (supplied is null || supplied.Count == 0)
        {
            if (reflectImportance)
                throw new QuestionGenerationRequestException("중요도 반영에는 출처 개념이 필요합니다.");
            return [];
        }
        if (supplied.Count > 500)
            throw new QuestionGenerationRequestException("한 번에 최대 500개 개념을 사용할 수 있습니다.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var concepts = new List<QuestionGenerationConcept>();
        foreach (var raw in supplied)
        {
            var id = raw.Id?.Trim() ?? "";
            var title = raw.Title?.Trim() ?? "";
            var content = raw.Content?.Trim() ?? "";
            var importance = ConceptImportanceLevels.Normalize(raw.Importance);
            if (id.Length is < 1 or > 128 || !ids.Add(id) || title.Length is < 1 or > 200 ||
                content.Length is < 1 or > 8000 || importance is null)
                throw new QuestionGenerationRequestException("문제 생성에 사용할 개념 ID·제목·내용·중요도가 올바르지 않습니다.");
            concepts.Add(new(id, title, content, importance));
        }
        if (concepts.Sum(c => c.Title.Length + c.Content.Length + c.Id.Length + 30) > 50_000)
            throw new QuestionGenerationRequestException("문제 생성에 사용할 개념 내용은 총 50,000자 이하여야 합니다.");
        var weights = concepts.Select(c => reflectImportance ? Weight(c.Importance) : 3).ToArray();
        var baseCount = density switch { "low" => 2, "high" => 6, _ => 4 };
        var desired = weights.Select(w => Math.Max(1, (int)Math.Round(
            baseCount * w / 3.0, MidpointRounding.AwayFromZero))).ToArray();
        var total = automatic ? Math.Min(limit, desired.Sum()) : manualCount;
        // Coverage first when it fits. With an insufficient budget, cover the
        // highest-priority concepts first, keeping source order as the tie-break.
        var counts = new int[concepts.Count];
        foreach (var index in Enumerable.Range(0, concepts.Count)
                     .OrderByDescending(i => weights[i]).Take(total)) counts[index] = 1;
        var remaining = total - counts.Sum();
        if (remaining > 0)
        {
            // Automatic mode distributes the residual of each desired count;
            // manual mode uses relative 1-5 weights for its fixed total.
            var residualWeights = automatic
                ? desired.Select((value, i) => Math.Max(0, value - counts[i])).ToArray()
                : weights;
            var sum = residualWeights.Sum();
            var shares = residualWeights.Select(w => remaining * w / (double)sum).ToArray();
            for (var i = 0; i < counts.Length; i++) counts[i] += (int)Math.Floor(shares[i]);
            var leftovers = total - counts.Sum();
            foreach (var i in Enumerable.Range(0, counts.Length)
                         .OrderByDescending(i => shares[i] - Math.Floor(shares[i]))
                         .ThenByDescending(i => weights[i]).Take(leftovers)) counts[i]++;
        }
        return concepts.Select((concept, i) => new QuestionConceptPlan(concept, counts[i])).ToArray();
    }

    public static int Weight(string importance) => importance switch
    {
        "veryLow" => 1, "low" => 2, "high" => 4, "veryHigh" => 5, _ => 3
    };
}
