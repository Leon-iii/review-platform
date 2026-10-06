using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;

public sealed class SyncService(SyncDbContext database)
{
    private static readonly HashSet<string> EntityTypes =
    [
        "folder",
        "question",
        "source",
        "concept",
        "quizSession",
        "attempt"
    ];

    public async Task<PushResponse> PushAsync(
        PushRequest request,
        CancellationToken cancellationToken = default)
    {
        if (request.Changes.Count > 500)
        {
            throw new SyncValidationException("한 번에 최대 500개 변경을 전송할 수 있습니다.");
        }

        Validate(request.Changes);
        await using var transaction = await database.Database.BeginTransactionAsync(
            cancellationToken);
        var revisionState = await database.SyncRevisions.SingleOrDefaultAsync(
            state => state.Id == SyncRevisionState.SingletonId,
            cancellationToken);
        if (revisionState is null)
        {
            revisionState = new SyncRevisionState();
            database.SyncRevisions.Add(revisionState);
        }

        var acknowledged = new List<string>(request.Changes.Count);
        foreach (var change in request.Changes)
        {
            var wasProcessed = await database.ProcessedOperations.AnyAsync(
                operation => operation.Id == change.OperationId,
                cancellationToken);
            if (wasProcessed)
            {
                acknowledged.Add(change.OperationId);
                continue;
            }

            var existing = await database.SyncEntities.FindAsync(
                [change.EntityType, change.EntityId],
                cancellationToken);
            var shouldApply = SyncConflictPolicy.ShouldApply(
                change.EntityType,
                existing is not null,
                change.UpdatedAt,
                existing?.UpdatedAt ?? DateTimeOffset.MinValue,
                IsAnswerCorrection(change, existing));
            if (shouldApply)
            {
                revisionState.CurrentRevision++;
                if (existing is null)
                {
                    existing = new SyncEntityRecord
                    {
                        EntityType = change.EntityType,
                        EntityId = change.EntityId
                    };
                    database.SyncEntities.Add(existing);
                }

                existing.PayloadJson = change.Operation == "delete"
                    ? null
                    : QuestionAnswerFormatMigration.Normalize(change.EntityType, change.Payload!.Value.GetRawText());
                existing.UpdatedAt = change.UpdatedAt.ToUniversalTime();
                existing.DeletedAt = change.Operation == "delete"
                    ? (change.DeletedAt ?? change.UpdatedAt).ToUniversalTime()
                    : null;
                existing.Revision = revisionState.CurrentRevision;
            }

            database.ProcessedOperations.Add(new ProcessedSyncOperation
            {
                Id = change.OperationId,
                ProcessedAt = DateTimeOffset.UtcNow
            });
            acknowledged.Add(change.OperationId);
        }

        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return new PushResponse(acknowledged, revisionState.CurrentRevision);
    }

    public async Task<PullResponse> PullAsync(
        long sinceRevision,
        int limit,
        CancellationToken cancellationToken = default)
    {
        if (sinceRevision < 0)
        {
            throw new SyncValidationException("revision은 0 이상이어야 합니다.");
        }

        var rows = await database.SyncEntities
            .AsNoTracking()
            .Where(record => record.Revision > sinceRevision)
            .OrderBy(record => record.Revision)
            .Take(limit + 1)
            .ToListAsync(cancellationToken);
        var hasMore = rows.Count > limit;
        if (hasMore)
        {
            rows.RemoveAt(rows.Count - 1);
        }

        var currentRevision = await database.SyncRevisions
            .AsNoTracking()
            .Where(state => state.Id == SyncRevisionState.SingletonId)
            .Select(state => state.CurrentRevision)
            .SingleOrDefaultAsync(cancellationToken);
        return new PullResponse(
            rows.Select(ToPullChange).ToList(),
            currentRevision,
            hasMore);
    }

    private static PullChange ToPullChange(SyncEntityRecord record)
    {
        JsonElement? payload = record.PayloadJson is null
            ? null
            : JsonSerializer.Deserialize<JsonElement>(record.PayloadJson);
        return new PullChange(
            record.EntityType,
            record.EntityId,
            record.DeletedAt is null ? "upsert" : "delete",
            payload,
            record.UpdatedAt,
            record.DeletedAt,
            record.Revision);
    }

    // Attempts remain append-only except for an explicit short-answer regrade.
    // Preserve response and content; only its score and accepted answers vary.
    private static bool IsAnswerCorrection(PushChange change, SyncEntityRecord? existing)
    {
        if (change.EntityType != "attempt" || change.Operation != "upsert" ||
            change.Payload is null || existing?.PayloadJson is null) return false;
        var incoming = JsonNode.Parse(change.Payload.Value.GetRawText()) as JsonObject;
        var original = JsonNode.Parse(existing.PayloadJson) as JsonObject;
        if (incoming is null || original is null ||
            incoming["response"] is not JsonObject response ||
            incoming["questionSnapshot"] is not JsonObject snapshot ||
            snapshot["type"]?.GetValue<string>() != "shortAnswer" ||
            response["gradingCorrectionUpdatedAt"] is not JsonValue version ||
            !version.TryGetValue<string>(out var timestamp) ||
            !DateTimeOffset.TryParse(timestamp, out var correctedAt) ||
            correctedAt != change.UpdatedAt) return false;
        if (incoming["score"] is not JsonValue score ||
            incoming["maxScore"] is not JsonValue maximum ||
            !score.TryGetValue<double>(out var value) ||
            !maximum.TryGetValue<double>(out var max) ||
            max <= 0 || (value != 0 && value != max)) return false;
        if (response["textAnswer"] is not JsonValue submittedValue ||
            !submittedValue.TryGetValue<string>(out var submittedText) ||
            string.IsNullOrWhiteSpace(submittedText) ||
            response["isUnknown"] is JsonValue unknown && unknown.TryGetValue<bool>(out var isUnknown) && isUnknown ||
            snapshot["acceptableAnswers"] is not JsonArray newAnswers ||
            original["questionSnapshot"]?["acceptableAnswers"] is not JsonArray oldAnswers) return false;
        var submitted = submittedText.Trim();
        bool Appended(JsonArray shorter, JsonArray longer) =>
            longer.Count == shorter.Count + 1 &&
            longer.Last() is JsonValue last && last.TryGetValue<string>(out var text) && text == submitted &&
            shorter.Select((answer, index) => JsonNode.DeepEquals(answer, longer[index])).All(equal => equal);
        if (!JsonNode.DeepEquals(oldAnswers, newAnswers) &&
            !Appended(oldAnswers, newAnswers) && !Appended(newAnswers, oldAnswers)) return false;
        if (value == max)
        {
            var caseSensitive = snapshot["caseSensitive"]?.GetValue<bool>() ?? false;
            var whitespaceSensitive = snapshot["whitespaceSensitive"]?.GetValue<bool>() ?? false;
            string Normalize(string text)
            {
                text = text.Trim();
                if (!whitespaceSensitive) text = System.Text.RegularExpressions.Regex.Replace(text, @"\s+", "");
                return caseSensitive ? text : text.ToLowerInvariant();
            }
            if (!newAnswers.OfType<JsonValue>().Any(answer =>
                answer.TryGetValue<string>(out var text) && Normalize(text) == Normalize(submitted))) return false;
        }
        foreach (var document in new[] { incoming, original })
        {
            document.Remove("score");
            if (document["response"] is JsonObject answer)
                answer.Remove("gradingCorrectionUpdatedAt");
            if (document["questionSnapshot"] is JsonObject content)
                content.Remove("acceptableAnswers");
        }
        return JsonNode.DeepEquals(incoming, original);
    }

    private static void Validate(IEnumerable<PushChange> changes)
    {
        foreach (var change in changes)
        {
            if (string.IsNullOrWhiteSpace(change.OperationId) ||
                string.IsNullOrWhiteSpace(change.EntityId))
            {
                throw new SyncValidationException("operationId와 entityId가 필요합니다.");
            }
            if (!EntityTypes.Contains(change.EntityType))
            {
                throw new SyncValidationException("지원하지 않는 entityType입니다.");
            }
            if (change.Operation is not ("upsert" or "delete"))
            {
                throw new SyncValidationException("지원하지 않는 operation입니다.");
            }
            if (change.Operation == "upsert" && change.Payload is null)
            {
                throw new SyncValidationException("upsert에는 payload가 필요합니다.");
            }
        }
    }
}
