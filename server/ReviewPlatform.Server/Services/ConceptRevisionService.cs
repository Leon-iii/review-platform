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
        return new ReviseConceptsResponse(revisions);
    }

    private static ConceptRevisionInput Validate(ReviseConceptsRequest request)
    {
        var sourceId = request.SourceId?.Trim() ?? string.Empty;
        var fileName = request.FileName?.Trim() ?? string.Empty;
        var instruction = request.Instruction?.Trim() ?? string.Empty;
        if (sourceId.Length is < 1 or > 100 || fileName.Length is < 1 or > 300)
        {
            throw new ConceptRevisionRequestException(
                "수정할 PDF 자료 정보가 올바르지 않습니다.");
        }
        if (request.PageCount is < 1 or > 300)
        {
            throw new ConceptRevisionRequestException(
                "PDF 페이지 수가 올바르지 않습니다.");
        }
        if (instruction.Length is < 1 or > 4_000)
        {
            throw new ConceptRevisionRequestException(
                "수정 요청사항은 1자에서 4,000자 사이여야 합니다.");
        }
        if (request.Concepts is null || request.Concepts.Count is < 1 or > 200)
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
            var importance = concept.Importance?.Trim().ToLowerInvariant() ?? string.Empty;
            var pages = concept.PageNumbers?.Distinct().Order().ToList() ?? [];
            if (id.Length is < 1 or > 100 || !ids.Add(id) ||
                title.Length is < 1 or > 200 || content.Length is < 1 or > 8_000 ||
                pages.Count == 0 || pages.Any(page => page < 1 || page > request.PageCount) ||
                concept.Status is not "held" and not "approved" ||
                importance is not "low" and not "medium" and not "high")
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
            request.TargetConceptIds.Count is < 1 or > 200)
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
            ConceptRevisionPrompt.Version);
    }

    private static IReadOnlyList<GeneratedConceptRevision> ValidateOutput(
        IReadOnlyList<GeneratedConceptRevision> generated,
        ConceptRevisionInput input)
    {
        if (generated.Count > input.EditableConceptIds.Count)
        {
            throw new LlmProviderRequestException(
                "LLM이 허용된 개수보다 많은 개념 수정안을 반환했습니다.");
        }
        var originals = input.Concepts.ToDictionary(
            concept => concept.Id,
            StringComparer.Ordinal);
        var editable = input.EditableConceptIds.ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<GeneratedConceptRevision>(generated.Count);
        foreach (var revision in generated)
        {
            var id = revision.Id?.Trim() ?? string.Empty;
            var title = revision.Title?.Trim() ?? string.Empty;
            var content = revision.Content?.Trim() ?? string.Empty;
            var importance = revision.Importance?.Trim().ToLowerInvariant() ?? string.Empty;
            var pages = revision.PageNumbers?.Distinct().Order().ToList() ?? [];
            if (!editable.Contains(id) || !seen.Add(id) ||
                title.Length is < 1 or > 200 || content.Length is < 1 or > 8_000 ||
                pages.Count == 0 || pages.Any(page => page < 1 || page > input.PageCount) ||
                importance is not "low" and not "medium" and not "high")
            {
                throw new LlmProviderRequestException(
                    "LLM이 올바르지 않은 개념 수정안을 반환했습니다.");
            }
            var original = originals[id];
            if (title == original.Title && content == original.Content &&
                pages.SequenceEqual(original.PageNumbers) && importance == original.Importance)
            {
                continue;
            }
            result.Add(new GeneratedConceptRevision(id, title, content, pages, importance));
        }
        return result;
    }
}

public sealed class ConceptRevisionRequestException(string message)
    : Exception(message);
