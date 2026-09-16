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
}
