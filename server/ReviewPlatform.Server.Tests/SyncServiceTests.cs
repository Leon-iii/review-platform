using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class SyncServiceTests : IAsyncLifetime
{
    private readonly SqliteConnection connection = new("Data Source=:memory:");
    private SyncDbContext database = null!;
    private SyncService service = null!;

    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        var options = new DbContextOptionsBuilder<SyncDbContext>()
            .UseSqlite(connection)
            .Options;
        database = new SyncDbContext(options);
        await database.Database.EnsureCreatedAsync();
        service = new SyncService(database);
    }

    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync();
        await connection.DisposeAsync();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Ordering_PreservesIdentityBasedAnswerAndRejectsInvalidPermutations(bool invalid)
    {
        var payload = JsonSerializer.SerializeToElement(new {
            id = "ordered-q", type = "ordering", correctChoiceIds = invalid ? new[] { "a", "a", "x" } : new[] { "b", "a", "c" },
            choices = new[] { new { id = "a", text = "단계 1", isCorrect = true }, new { id = "b", text = "단계 2", isCorrect = true },
                new { id = "c", text = "단계 3", isCorrect = true } }, acceptableAnswers = Array.Empty<string>() });
        var change = new PushChange("order-op", "question", "ordered-q", "upsert", payload, DateTimeOffset.UtcNow, null);
        if (invalid)
            await Assert.ThrowsAsync<SyncValidationException>(() => service.PushAsync(new([change]), TestContext.Current.CancellationToken));
        else {
            await service.PushAsync(new([change]), TestContext.Current.CancellationToken);
            var pulled = await service.PullAsync(0, 100, TestContext.Current.CancellationToken);
            Assert.Equal("[\"b\",\"a\",\"c\"]", pulled.Changes.Single().Payload!.Value.GetProperty("correctChoiceIds").GetRawText());
        }
    }

    [Fact]
    public async Task PushThenPull_AssignsIncreasingRevisions()
    {
        var timestamp = DateTimeOffset.Parse("2026-09-16T00:00:00Z");
        var response = await service.PushAsync(new PushRequest(
        [
            Change("op-1", "folder", "folder-1", timestamp),
            Change("op-2", "question", "question-1", timestamp)
        ]), TestContext.Current.CancellationToken);

        var pulled = await service.PullAsync(
            0,
            100,
            TestContext.Current.CancellationToken);

        Assert.Equal(2, response.ServerRevision);
        Assert.Equal(["op-1", "op-2"], response.AcknowledgedOperationIds);
        Assert.Equal(2, pulled.Changes.Count);
        Assert.Equal([1, 2], pulled.Changes.Select(change => change.Revision));
    }

    [Fact]
    public async Task OlderMutableChange_DoesNotReplaceNewerValue()
    {
        var newer = DateTimeOffset.Parse("2026-09-16T02:00:00Z");
        await service.PushAsync(new PushRequest(
        [
            Change("new", "question", "question-1", newer, "new value")
        ]), TestContext.Current.CancellationToken);
        await service.PushAsync(new PushRequest(
        [
            Change("old", "question", "question-1", newer.AddHours(-1), "old value")
        ]), TestContext.Current.CancellationToken);

        var pulled = await service.PullAsync(
            0,
            100,
            TestContext.Current.CancellationToken);

        Assert.Single(pulled.Changes);
        Assert.Equal("new value", pulled.Changes[0].Payload?.GetProperty("value").GetString());
        Assert.Equal(1, pulled.ServerRevision);
    }

    [Fact]
    public async Task ExistingAttempt_RemainsAppendOnly()
    {
        var timestamp = DateTimeOffset.Parse("2026-09-16T00:00:00Z");
        await service.PushAsync(new PushRequest(
        [
            Change("first", "attempt", "attempt-1", timestamp, "first")
        ]), TestContext.Current.CancellationToken);
        await service.PushAsync(new PushRequest(
        [
            Change("second", "attempt", "attempt-1", timestamp.AddDays(1), "second")
        ]), TestContext.Current.CancellationToken);

        var pulled = await service.PullAsync(
            0,
            100,
            TestContext.Current.CancellationToken);

        Assert.Single(pulled.Changes);
        Assert.Equal("first", pulled.Changes[0].Payload?.GetProperty("value").GetString());
    }

    [Fact]
    public async Task RetriedOperation_IsIdempotent()
    {
        var timestamp = DateTimeOffset.Parse("2026-09-16T00:00:00Z");
        var request = new PushRequest(
        [
            Change("same-operation", "folder", "folder-1", timestamp)
        ]);

        await service.PushAsync(request, TestContext.Current.CancellationToken);
        var retried = await service.PushAsync(
            request,
            TestContext.Current.CancellationToken);

        Assert.Equal(1, retried.ServerRevision);
        Assert.Equal(["same-operation"], retried.AcknowledgedOperationIds);
    }

    private static PushChange Change(
        string operationId,
        string entityType,
        string entityId,
        DateTimeOffset updatedAt,
        string value = "value")
    {
        return new PushChange(
            operationId,
            entityType,
            entityId,
            "upsert",
            JsonSerializer.SerializeToElement(new { value }),
            updatedAt,
            null);
    }

    [Fact]
    public async Task VersionedAnswerCorrectionAndUndo_UpdateScoreWithoutReplacingOriginalResponse()
    {
        var started = DateTimeOffset.Parse("2026-10-06T01:00:00Z");
        PushChange AttemptChange(string operation, DateTimeOffset updated, double score,
            bool accepted, bool corrected, string answer = "new answer") => new(
            operation, "attempt", "a", "upsert", JsonSerializer.SerializeToElement(new
            {
                id = "a", questionId = "q", sessionId = "s", answeredAt = started,
                createdAt = started, durationMs = 100, gradingType = "automatic", maxScore = 1,
                score,
                response = corrected
                    ? new Dictionary<string, object> { ["textAnswer"] = answer,
                        ["gradingCorrectionUpdatedAt"] = updated.ToString("O") }
                    : new Dictionary<string, object> { ["textAnswer"] = answer },
                questionSnapshot = new { questionId = "q", type = "shortAnswer",
                    answerFormatVersion = 2, prompt = "question", choices = Array.Empty<object>(),
                    acceptableAnswers = accepted ? new[] { "old answer", "new answer" } : new[] { "old answer" } }
            }), updated, null);
        async Task Push(PushChange change) => await service.PushAsync(
            new PushRequest([change]), TestContext.Current.CancellationToken);
        await Push(AttemptChange("original", started, 0, false, false));
        var accepted = AttemptChange("accept", started.AddSeconds(1), 1, true, true);
        await Push(accepted);
        var pulled = await service.PullAsync(0, 100, TestContext.Current.CancellationToken);
        Assert.Equal(1, pulled.Changes.Single().Payload!.Value.GetProperty("score").GetDouble());
        await Push(AttemptChange("undo", started.AddSeconds(2), 0, false, true));
        await Push(accepted with { OperationId = "stale" });
        await Push(AttemptChange("tamper", started.AddSeconds(3), 1, true, true, "right"));
        pulled = await service.PullAsync(0, 100, TestContext.Current.CancellationToken);
        Assert.Equal(3, pulled.ServerRevision);
        var payload = pulled.Changes.Single().Payload!.Value;
        Assert.Equal(0, payload.GetProperty("score").GetDouble());
        Assert.Equal("new answer", payload.GetProperty("response").GetProperty("textAnswer").GetString());
        Assert.Single(payload.GetProperty("questionSnapshot").GetProperty("acceptableAnswers").EnumerateArray());
    }

    [Fact]
    public async Task MultipleChoiceCorrection_IsNoLongerSupported()
    {
        var started = DateTimeOffset.Parse("2026-10-06T01:00:00Z");
        PushChange AttemptChange(string operation, bool corrected) => new(
            operation, "attempt", "mc", "upsert", JsonSerializer.SerializeToElement(new
            {
                id = "mc", questionId = "q", sessionId = "s", answeredAt = started,
                createdAt = started, durationMs = 100, gradingType = "automatic", maxScore = 1,
                score = corrected ? 1 : 0,
                response = corrected
                    ? new Dictionary<string, object> { ["selectedChoiceId"] = "wrong",
                        ["gradingCorrectionUpdatedAt"] = started.AddSeconds(1).ToString("O") }
                    : new Dictionary<string, object> { ["selectedChoiceId"] = "wrong" },
                questionSnapshot = new { questionId = "q", type = "multipleChoice", prompt = "question",
                    choices = new[] { new { id = "right", text = "right", isCorrect = true },
                        new { id = "wrong", text = "wrong", isCorrect = corrected } },
                    acceptableAnswers = Array.Empty<string>() }
            }), corrected ? started.AddSeconds(1) : started, null);
        await service.PushAsync(new PushRequest([AttemptChange("original", false)]), TestContext.Current.CancellationToken);
        await service.PushAsync(new PushRequest([AttemptChange("unsupported", true)]), TestContext.Current.CancellationToken);
        var pulled = await service.PullAsync(0, 100, TestContext.Current.CancellationToken);
        Assert.Equal(1, pulled.ServerRevision);
        Assert.Equal(0, pulled.Changes.Single().Payload!.Value.GetProperty("score").GetDouble());
    }
}
