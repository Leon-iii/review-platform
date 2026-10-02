using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.Data;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ServerDatabaseInitializerTests
{
    [Fact]
    public async Task ExistingProfiles_ArePreservedWithAutomaticContextAfterUpgrade()
    {
        await using var connection = new SqliteConnection("Data Source=:memory:");
        await connection.OpenAsync(TestContext.Current.CancellationToken);
        await using var database = new SyncDbContext(
            new DbContextOptionsBuilder<SyncDbContext>().UseSqlite(connection).Options);
        await database.Database.ExecuteSqlRawAsync("""
            CREATE TABLE "LlmProfiles" (
                "Id" TEXT NOT NULL PRIMARY KEY,
                "Name" TEXT NOT NULL,
                "Provider" TEXT NOT NULL,
                "Model" TEXT NOT NULL,
                "BaseUrl" TEXT NOT NULL,
                "UpdatedAt" TEXT NOT NULL
            );
            INSERT INTO "LlmProfiles" VALUES (
                'existing', '기존 프로필', 'ollama', 'qwen3:8b',
                'http://127.0.0.1:11434', '2026-10-01T00:00:00+00:00');
            """, TestContext.Current.CancellationToken);

        await ServerDatabaseInitializer.InitializeAsync(database,
            TestContext.Current.CancellationToken);
        await ServerDatabaseInitializer.InitializeAsync(database,
            TestContext.Current.CancellationToken);

        var existing = await database.LlmProfiles.SingleAsync(
            TestContext.Current.CancellationToken);
        Assert.Equal("기존 프로필", existing.Name);
        Assert.Equal("qwen3:8b", existing.Model);
        Assert.Null(existing.ContextWindowTokens);
        Assert.Null(existing.ReasoningEffort);
        Assert.Equal(120, existing.MaximumQuestionsPerRequest);
        existing.MaximumQuestionsPerRequest = 45;
        await database.SaveChangesAsync(TestContext.Current.CancellationToken);
        await ServerDatabaseInitializer.InitializeAsync(database,
            TestContext.Current.CancellationToken);
        database.ChangeTracker.Clear();
        Assert.Equal(45, (await database.LlmProfiles.SingleAsync(
            TestContext.Current.CancellationToken)).MaximumQuestionsPerRequest);
    }
}
