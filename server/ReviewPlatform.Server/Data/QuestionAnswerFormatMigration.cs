using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;

namespace ReviewPlatform.Server.Data;

public static class QuestionAnswerFormatMigration
{
    public const int CurrentVersion = 2;

    // Normalize legacy uploads too, otherwise an old device can resurrect the
    // unrestricted short-answer type after the one-time startup migration.
    public static string Normalize(string entityType, string json)
    {
        if (entityType is not ("question" or "quizSession")) return json;
        var payload = JsonNode.Parse(json) as JsonObject;
        if (payload is null) return json;
        var changed = false;
        if (entityType == "question") changed = NormalizeSnapshot(payload);
        else if (payload["finishedAt"] is null && payload["items"] is JsonArray items)
        {
            foreach (var item in items.OfType<JsonObject>())
                if (item["attemptId"] is null && item["questionSnapshot"] is JsonObject snapshot)
                    changed |= NormalizeSnapshot(snapshot);
        }
        return changed ? payload.ToJsonString() : json;
    }

    private static bool NormalizeSnapshot(JsonObject snapshot)
    {
        if (snapshot["type"] is not JsonValue type || !type.TryGetValue<string>(out var name) || name != "shortAnswer")
            return false;
        if (snapshot["answerFormatVersion"] is JsonValue version && version.TryGetValue<int>(out var number) && number >= CurrentVersion)
            return false;
        snapshot["type"] = "essay";
        snapshot["answerFormatVersion"] = CurrentVersion;
        return true;
    }

    public static async Task MigrateAsync(SyncDbContext database, CancellationToken cancellationToken = default)
    {
        var hasSyncTable = await database.Database.SqlQueryRaw<int>(
            "SELECT COUNT(*) AS Value FROM sqlite_master WHERE type = 'table' AND name = 'SyncEntities'")
            .SingleAsync(cancellationToken);
        if (hasSyncTable == 0) return;
        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        var records = await database.SyncEntities
            .Where(row => row.DeletedAt == null && row.PayloadJson != null &&
                (row.EntityType == "question" || row.EntityType == "quizSession"))
            .ToListAsync(cancellationToken);
        SyncRevisionState? revision = null;
        foreach (var record in records)
        {
            var updated = Normalize(record.EntityType, record.PayloadJson!);
            if (updated == record.PayloadJson) continue;
            revision ??= await database.SyncRevisions.SingleOrDefaultAsync(row => row.Id == SyncRevisionState.SingletonId, cancellationToken);
            if (revision is null)
            {
                revision = new SyncRevisionState();
                database.SyncRevisions.Add(revision);
            }
            revision.CurrentRevision++;
            var now = DateTimeOffset.UtcNow;
            var nextTimestamp = record.UpdatedAt.AddSeconds(1);
            record.UpdatedAt = nextTimestamp > now ? nextTimestamp : now;
            var payload = JsonNode.Parse(updated)!.AsObject();
            payload["updatedAt"] = record.UpdatedAt.ToString("O");
            record.PayloadJson = payload.ToJsonString();
            record.Revision = revision.CurrentRevision;
        }
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }
}
