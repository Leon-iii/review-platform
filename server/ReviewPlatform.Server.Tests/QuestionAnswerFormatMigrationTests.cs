using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class QuestionAnswerFormatMigrationTests : IAsyncLifetime
{
    private readonly SqliteConnection connection = new("Data Source=:memory:");
    private SyncDbContext database = null!;
    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        database = new(new DbContextOptionsBuilder<SyncDbContext>().UseSqlite(connection).Options);
        await database.Database.EnsureCreatedAsync();
    }
    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync(); await connection.DisposeAsync();
    }

    [Fact]
    public async Task StartupMigrationPreservesFieldsAndHistoryAndIsIdempotent()
    {
        var timestamp = DateTimeOffset.Parse("2030-01-01T00:00:00Z");
        database.SyncRevisions.Add(new() { CurrentRevision = 4 });
        database.SyncEntities.AddRange(
            Record("question", "legacy", """{"id":"legacy","type":"shortAnswer","prompt":"기존 질문","acceptableAnswers":[{"id":"answer","text":"기존 답안"}],"difficulty":4,"status":"draft"}""", 1),
            Record("question", "modern", """{"type":"shortAnswer","answerFormatVersion":2}""", 2),
            Record("attempt", "history", """{"score":1,"questionSnapshot":{"type":"shortAnswer"}}""", 3),
            Record("quizSession", "ongoing", """{"finishedAt":null,"items":[{"attemptId":null,"questionSnapshot":{"type":"shortAnswer"}},{"attemptId":"history","questionSnapshot":{"type":"shortAnswer"}}]}""", 4));
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);
        await QuestionAnswerFormatMigration.MigrateAsync(database, TestContext.Current.CancellationToken);
        var legacy = (await database.SyncEntities.FindAsync(["question", "legacy"], TestContext.Current.CancellationToken))!;
        var json = JsonNode.Parse(legacy.PayloadJson!)!;
        Assert.Equal("essay", json["type"]!.GetValue<string>());
        Assert.Equal(2, json["answerFormatVersion"]!.GetValue<int>());
        Assert.Equal("기존 질문", json["prompt"]!.GetValue<string>());
        Assert.Equal("answer", json["acceptableAnswers"]![0]!["id"]!.GetValue<string>());
        Assert.Equal("draft", json["status"]!.GetValue<string>());
        Assert.True(legacy.UpdatedAt > timestamp);
        var ongoing = (await database.SyncEntities.FindAsync(["quizSession", "ongoing"], TestContext.Current.CancellationToken))!;
        var items = JsonNode.Parse(ongoing.PayloadJson!)!["items"]!;
        Assert.Equal("essay", items[0]!["questionSnapshot"]!["type"]!.GetValue<string>());
        Assert.Equal("shortAnswer", items[1]!["questionSnapshot"]!["type"]!.GetValue<string>());
        var pulled = await new SyncService(database).PullAsync(4, 100, TestContext.Current.CancellationToken);
        Assert.Equal(2, pulled.Changes.Count);
        Assert.All(pulled.Changes, change => Assert.True(change.Revision > 4));
        await QuestionAnswerFormatMigration.MigrateAsync(database, TestContext.Current.CancellationToken);
        Assert.Equal(6, (await database.SyncRevisions.SingleAsync(TestContext.Current.CancellationToken)).CurrentRevision);
        var modern = (await database.SyncEntities.FindAsync(["question", "modern"], TestContext.Current.CancellationToken))!;
        Assert.Equal(2, modern.Revision);
        var history = (await database.SyncEntities.FindAsync(["attempt", "history"], TestContext.Current.CancellationToken))!;
        Assert.Equal(3, history.Revision);
        Assert.Contains("shortAnswer", history.PayloadJson!);

        SyncEntityRecord Record(string type, string id, string payload, long revision) => new()
        { EntityType = type, EntityId = id, PayloadJson = payload, UpdatedAt = timestamp, Revision = revision };
    }

    [Theory]
    [InlineData(null, "essay")]
    [InlineData(1, "essay")]
    [InlineData(2, "shortAnswer")]
    [InlineData(3, "shortAnswer")]
    public async Task SyncPushNormalizesOnlyLegacyShortAnswers(int? version, string expected)
    {
        var payload = new JsonObject { ["id"] = "question", ["type"] = "shortAnswer", ["answerFormatVersion"] = version };
        var service = new SyncService(database);
        await service.PushAsync(new PushRequest([new PushChange("op", "question", "question", "upsert",
            JsonSerializer.SerializeToElement(payload), DateTimeOffset.UtcNow, null)]), TestContext.Current.CancellationToken);
        var pulled = await service.PullAsync(0, 100, TestContext.Current.CancellationToken);
        Assert.Equal(expected, Assert.Single(pulled.Changes).Payload!.Value.GetProperty("type").GetString());
    }

    [Fact]
    public void FinishedSessionsAndCompletedAttemptsRemainHistorical()
    {
        const string finished = """{"finishedAt":"2026-01-01T00:00:00Z","items":[{"attemptId":null,"questionSnapshot":{"type":"shortAnswer"}}]}""";
        Assert.Equal(finished, QuestionAnswerFormatMigration.Normalize("quizSession", finished));
        const string attempt = """{"questionSnapshot":{"type":"shortAnswer"}}""";
        Assert.Equal(attempt, QuestionAnswerFormatMigration.Normalize("attempt", attempt));
    }
}
