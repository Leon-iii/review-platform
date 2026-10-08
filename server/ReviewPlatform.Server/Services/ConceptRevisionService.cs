using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;

namespace ReviewPlatform.Server.Services;

public sealed class ConceptRevisionService(
    ILlmProviderResolver providerResolver,
    ILogger<ConceptRevisionService> logger,
    IConceptRevisionSourceReader sourceReader)
{
    public async Task<ReviseConceptsResponse> ReviseAsync(
        ReviseConceptsRequest request,
        CancellationToken cancellationToken = default)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var stage = "request-validation";
        ILLMProvider? provider = null;
        var sourcePages = 0;
        try
        {
            var input = Validate(request);
            stage = "provider-resolution";
            provider = await providerResolver.ResolveAsync(
                LlmPurposes.ConceptRevision,
                cancellationToken);
            var selected = input.EditableConceptIds.ToHashSet(StringComparer.Ordinal);
            var pages = input.Concepts.Where(item => selected.Contains(item.Id))
                .SelectMany(item => item.PageNumbers).Distinct().Order().ToArray();
            if (pages.Length > 0)
            {
                stage = "source-reference";
                sourcePages = pages.Length;
                if (!provider.SupportsRevisionPdf)
                    throw new LlmProviderUnavailableException("선택한 개념 수정 모델은 PDF 원본 첨부를 지원하지 않습니다. PDF 입력을 지원하는 OpenAI 모델을 선택해 주세요.");
                input = input with
                {
                    Source = await sourceReader.ReadAsync(input.SourceId,
                    input.PageCount, pages, request.ContentHash, cancellationToken)
                };
            }
            logger.LogInformation(
                "Concept revision started. SourceId={SourceId} " +
                "ConceptCount={ConceptCount} TargetCount={TargetCount} " +
                "Provider={Provider} Model={Model}",
                input.SourceId,
                input.Concepts.Count,
                input.EditableConceptIds.Count,
                provider.ProviderName,
                provider.ModelName);

            stage = "provider-request";
            var generated = await provider.ReviseConceptsAsync(input, cancellationToken);
            stage = "output-validation";
            var comment = generated.Comment?.Trim() ?? "";
            var question = generated.ClarificationQuestion?.Trim() ?? "";
            if (generated.Changes is null || comment.Length is < 1 or > 4000 || question.Length > 2000 ||
                generated.Status is not ("ready" or "needsClarification" or "noChanges") ||
                (generated.Status == "needsClarification") != (question.Length > 0) ||
                (generated.Status == "ready") != (generated.Changes.Count > 0))
                throw new LlmProviderRequestException("LLM의 개념 수정 상태·코멘트·확인 질문이 올바르지 않습니다.");
            var revisions = ValidateOutput(generated.Changes, input);
            if (generated.Status == "ready" && revisions.Count == 0)
                generated = generated with { Status = "noChanges" };
            logger.LogInformation(
                "Concept revision succeeded. SourceId={SourceId} RevisionCount={RevisionCount} " +
                "Provider={Provider} Model={Model} Status={Status} ClarificationAnswers={Answers} " +
                "SourcePages={SourcePages} DurationMs={Duration}",
                input.SourceId,
                revisions.Count,
                provider.ProviderName,
                provider.ModelName, generated.Status, input.Clarifications?.Count ?? 0,
                sourcePages, started.ElapsedMilliseconds);
            return new ReviseConceptsResponse(
                revisions.Where(item => item.Kind == "update").ToList(),
                revisions.Where(item => item.Kind == "add").Select(item => new GeneratedConceptAddition(
                    item.Title, item.Content, item.PageNumbers, item.Importance, item.GroupId, item.Reason)).ToList(),
                revisions.Where(item => item.Kind == "delete").Select(item => new GeneratedConceptDeletion(
                    item.Id, item.Reason, item.GroupId)).ToList(),
                generated.Status, comment, question);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            logger.LogInformation("Concept revision cancelled. SourceId={SourceId} Stage={Stage} DurationMs={Duration}",
                request.SourceId, stage, started.ElapsedMilliseconds);
            throw;
        }
        catch (Exception exception)
        {
            // No request text, PDF bytes, credentials, or provider response bodies.
            logger.LogWarning(exception, "Concept revision failed. SourceId={SourceId} Stage={Stage} " +
                "Provider={Provider} Model={Model} SourcePages={SourcePages} DurationMs={Duration}",
                request.SourceId, stage, provider?.ProviderName, provider?.ModelName,
                sourcePages, started.ElapsedMilliseconds);
            throw;
        }
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
        if (request.PageCount is < 0 or > 2000)
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

        var clarifications = request.Clarifications ?? [];
        if (clarifications.Count > 10 || clarifications.Any(item => item is null ||
            string.IsNullOrWhiteSpace(item.Question) || item.Question.Length > 2000 ||
            string.IsNullOrWhiteSpace(item.Answer) || item.Answer.Length > 4000))
            throw new ConceptRevisionRequestException("확인 질문·답변은 최대 10회이며 질문은 2,000자, 답변은 4,000자 이하여야 합니다.");
        return new ConceptRevisionInput(
            sourceId,
            fileName,
            request.PageCount,
            instruction,
            normalized,
            editableIds,
            ConceptRevisionPrompt.Version,
            request.AllowAdditions,
            request.AllowDeletions,
            clarifications.Select(item => new ConceptRevisionClarification(item.Question.Trim(), item.Answer.Trim())).ToList());
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
                    importance is null || revision.PageNumbers is null || reason.Length == 0 ||
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
                pages.Any(page => !allowedPages.Contains(page)) ||
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
            if (reason.Length == 0)
                throw new LlmProviderRequestException("LLM이 개념 수정 이유를 반환하지 않았습니다.");
            result.Add(new GeneratedConceptRevision(id, title, content, pages, importance, groupId, Reason: reason));
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
