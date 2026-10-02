using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public sealed class ConceptRevisionService(
    ILlmProviderResolver providerResolver,
    ILogger<ConceptRevisionService> logger)
{
    public async Task<ReviseConceptsResponse> ReviseAsync(
        ReviseConceptsRequest request,
        CancellationToken cancellationToken = default)
    {
        var input = Validate(request);
        var provider = await providerResolver.ResolveAsync(
            LlmPurposes.ConceptRevision,
            cancellationToken);
        logger.LogInformation(
            "Concept revision started. SourceId={SourceId} " +
            "ConceptCount={ConceptCount} TargetCount={TargetCount} " +
            "Provider={Provider} Model={Model}",
            input.SourceId,
            input.Concepts.Count,
            input.EditableConceptIds.Count,
            provider.ProviderName,
            provider.ModelName);

        var generated = await provider.ReviseConceptsAsync(input, cancellationToken);
        var revisions = ValidateOutput(generated, input);
        logger.LogInformation(
            "Concept revision succeeded. SourceId={SourceId} RevisionCount={RevisionCount} " +
            "Provider={Provider} Model={Model}",
            input.SourceId,
            revisions.Count,
            provider.ProviderName,
            provider.ModelName);
        return new ReviseConceptsResponse(
            revisions.Where(item => item.Kind == "update").ToList(),
            revisions.Where(item => item.Kind == "add").Select(item => new GeneratedConceptAddition(
                item.Title, item.Content, item.PageNumbers, item.Importance, item.GroupId, item.Reason)).ToList(),
            revisions.Where(item => item.Kind == "delete").Select(item => new GeneratedConceptDeletion(
                item.Id, item.Reason, item.GroupId)).ToList());
    }

    private static ConceptRevisionInput Validate(ReviseConceptsRequest request)
    {
        var sourceId = request.SourceId?.Trim() ?? string.Empty;
        var fileName = request.FileName?.Trim() ?? string.Empty;
        var instruction = request.Instruction?.Trim() ?? string.Empty;
        if (sourceId.Length is < 1 or > 100 || fileName.Length is < 1 or > 300)
        {
            throw new ConceptRevisionRequestException(
                "수정할 자료 정보가 올바르지 않습니다.");
        }
        if (request.PageCount is < 0 or > 300)
        {
            throw new ConceptRevisionRequestException(
                "자료 페이지 수가 올바르지 않습니다.");
        }
        if (instruction.Length is < 1 or > 4_000)
        {
            throw new ConceptRevisionRequestException(
                "수정 요청사항은 1자에서 4,000자 사이여야 합니다.");
        }
        if (request.Concepts is null || request.Concepts.Count > 200 ||
            (request.Concepts.Count == 0 && !request.AllowAdditions))
        {
            throw new ConceptRevisionRequestException(
                "수정할 개념은 1개에서 200개 사이여야 합니다.");
        }

        var normalized = new List<ConceptRevisionContext>(request.Concepts.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var totalCharacters = 0;
        foreach (var concept in request.Concepts)
        {
            var id = concept.Id?.Trim() ?? string.Empty;
            var title = concept.Title?.Trim() ?? string.Empty;
            var content = concept.Content?.Trim() ?? string.Empty;
            var importance = ConceptImportanceLevels.Normalize(concept.Importance);
            var pages = concept.PageNumbers?.Distinct().Order().ToList() ?? [];
            if (id.Length is < 1 or > 100 || !ids.Add(id) ||
                title.Length is < 1 or > 200 || content.Length is < 1 or > 8_000 ||
                concept.PageNumbers is null || pages.Any(page => page < 1 || page > request.PageCount) ||
                concept.Status is not "held" and not "approved" ||
                importance is null)
            {
                throw new ConceptRevisionRequestException(
                    "수정할 개념 정보가 올바르지 않습니다.");
            }
            totalCharacters += title.Length + content.Length;
            normalized.Add(new ConceptRevisionContext(
                id,
                title,
                content,
                pages,
                concept.Status,
                importance));
        }
        if (totalCharacters > 300_000)
        {
            throw new ConceptRevisionRequestException(
                "수정 요청에 포함된 개념 내용이 너무 깁니다.");
        }

        if (request.TargetConceptIds is null ||
            request.TargetConceptIds.Count > 200 ||
            (request.TargetConceptIds.Count == 0 && !request.AllowAdditions))
        {
            throw new ConceptRevisionRequestException(
                "수정할 개념을 하나 이상 선택해 주세요.");
        }
        var requestedIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var requestedId in request.TargetConceptIds)
        {
            var id = requestedId?.Trim() ?? string.Empty;
            if (id.Length is < 1 or > 100 || !requestedIds.Add(id) ||
                !ids.Contains(id))
            {
                throw new ConceptRevisionRequestException(
                    "선택한 수정 대상 개념이 올바르지 않습니다.");
            }
        }
        var editableIds = normalized
            .Where(concept => requestedIds.Contains(concept.Id))
            .Select(concept => concept.Id)
            .ToList();

        return new ConceptRevisionInput(
            sourceId,
            fileName,
            request.PageCount,
            instruction,
            normalized,
            editableIds,
            ConceptRevisionPrompt.Version,
            request.AllowAdditions,
            request.AllowDeletions);
    }

    private static IReadOnlyList<GeneratedConceptRevision> ValidateOutput(
        IReadOnlyList<GeneratedConceptRevision> generated,
        ConceptRevisionInput input)
    {
        if (generated.Count > input.EditableConceptIds.Count +
            (input.AllowAdditions ? ConceptRevisionPrompt.MaximumAdditions : 0))
        {
            throw new LlmProviderRequestException(
                "LLM이 허용된 개수보다 많은 개념 수정안을 반환했습니다.");
        }
        var originals = input.Concepts.ToDictionary(
            concept => concept.Id,
            StringComparer.Ordinal);
        var editable = input.EditableConceptIds.ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var allowedPages = input.Concepts.Where(item => editable.Contains(item.Id))
            .SelectMany(item => item.PageNumbers).ToHashSet();
        var additionCount = 0;
        var result = new List<GeneratedConceptRevision>(generated.Count);
        foreach (var revision in generated)
        {
            var id = revision.Id?.Trim() ?? string.Empty;
            var title = revision.Title?.Trim() ?? string.Empty;
            var content = revision.Content?.Trim() ?? string.Empty;
            var importance = ConceptImportanceLevels.Normalize(revision.Importance);
            var pages = revision.PageNumbers?.Distinct().Order().ToList() ?? [];
            var groupId = revision.GroupId?.Trim() ?? string.Empty;
            var reason = revision.Reason?.Trim() ?? string.Empty;
            if (groupId.Length > 100 || reason.Length > 1000)
                throw new LlmProviderRequestException("LLM이 올바르지 않은 개념 변경 그룹을 반환했습니다.");
            if (revision.Kind == "add")
            {
                if (!input.AllowAdditions || ++additionCount > ConceptRevisionPrompt.MaximumAdditions ||
                    title.Length is < 1 or > 200 || content.Length is < 1 or > 8000 ||
                    importance is null || revision.PageNumbers is null ||
                    pages.Any(page => !allowedPages.Contains(page)))
                    throw new LlmProviderRequestException("LLM이 허용되지 않거나 올바르지 않은 새 개념을 반환했습니다.");
                result.Add(new GeneratedConceptRevision("", title, content, pages, importance, groupId, "add", reason));
                continue;
            }
            if (revision.Kind == "delete")
            {
                if (!input.AllowDeletions || !editable.Contains(id) || !seen.Add(id) || reason.Length == 0)
                    throw new LlmProviderRequestException("LLM이 허용되지 않거나 올바르지 않은 개념 삭제안을 반환했습니다.");
                result.Add(new GeneratedConceptRevision(id, "", "", [], "medium", groupId, "delete", reason));
                continue;
            }
            var original = originals.GetValueOrDefault(id);
            if (revision.Kind != "update" || !editable.Contains(id) || !seen.Add(id) || original is null ||
                title.Length is < 1 or > 200 || content.Length is < 1 or > 8_000 ||
                revision.PageNumbers is null ||
                (pages.Count == 0) != (original.PageNumbers.Count == 0) ||
                pages.Any(page => page < 1 || page > input.PageCount) ||
                importance is null)
            {
                throw new LlmProviderRequestException(
                    "LLM이 올바르지 않은 개념 수정안을 반환했습니다.");
            }
            if (title == original.Title && content == original.Content &&
                pages.SequenceEqual(original.PageNumbers) && importance == original.Importance)
            {
                if (groupId.Length != 0)
                    throw new LlmProviderRequestException("연결된 변경 그룹에 변경되지 않은 개념이 포함되어 있습니다.");
                continue;
            }
            result.Add(new GeneratedConceptRevision(id, title, content, pages, importance, groupId));
        }
        if (input.Concepts.Count + additionCount - result.Count(item => item.Kind == "delete") > 200)
            throw new LlmProviderRequestException("자료의 개념 수는 200개를 초과할 수 없습니다.");
        var deleted = result.Where(item => item.Kind == "delete").Select(item => item.Id).ToHashSet();
        var updates = result.Where(item => item.Kind == "update").ToDictionary(item => item.Id);
        var titles = input.Concepts.Where(item => !deleted.Contains(item.Id))
            .Select(item => updates.GetValueOrDefault(item.Id)?.Title ?? item.Title).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var addition in result.Where(item => item.Kind == "add"))
            if (!titles.Add(addition.Title))
                throw new LlmProviderRequestException("LLM이 기존 개념과 제목이 중복된 새 개념을 반환했습니다.");
        return result;
    }
}

public sealed class ConceptRevisionRequestException(string message)
    : Exception(message);
