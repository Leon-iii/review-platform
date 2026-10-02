using Microsoft.AspNetCore.DataProtection;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class LlmApiKeyStoreTests : IAsyncLifetime
{
    private readonly SqliteConnection connection = new("Data Source=:memory:");
    private SyncDbContext database = null!;

    public async ValueTask InitializeAsync()
    {
        await connection.OpenAsync();
        database = new SyncDbContext(
            new DbContextOptionsBuilder<SyncDbContext>()
                .UseSqlite(connection)
                .Options);
        await ServerDatabaseInitializer.InitializeAsync(database);
    }

    public async ValueTask DisposeAsync()
    {
        await database.DisposeAsync();
        await connection.DisposeAsync();
    }

    [Fact]
    public async Task StoresThreeProviderKeysEncryptedAndReturnsOnlyConfiguredState()
    {
        var store = CreateStore();
        var rawKeys = new Dictionary<string, string?>
        {
            [LlmApiKeyProviders.OpenAi] = "openai-secret",
            [LlmApiKeyProviders.Gemini] = "gemini-secret",
            [LlmApiKeyProviders.Claude] = "claude-secret"
        };

        await store.UpdateAsync(rawKeys, TestContext.Current.CancellationToken);

        foreach (var pair in rawKeys)
        {
            Assert.Equal(pair.Value, await store.GetAsync(
                pair.Key,
                TestContext.Current.CancellationToken));
        }
        var records = await database.LlmProviderSecrets.AsNoTracking().ToListAsync(
            TestContext.Current.CancellationToken);
        Assert.Equal(3, records.Count);
        Assert.All(records, record =>
        {
            Assert.DoesNotContain("secret", record.ProtectedValue);
            Assert.True(record.ProtectedValue.Length > 20);
        });
        var configured = await store.GetConfiguredAsync(
            TestContext.Current.CancellationToken);
        Assert.All(LlmApiKeyProviders.All,
            provider => Assert.True(configured[provider]));
    }

    [Fact]
    public async Task ImportsEnvironmentBootstrapKeyWithoutOverwritingSavedKey()
    {
        var store = CreateStore(new Dictionary<string, string?>
        {
            ["OPENAI_API_KEY"] = "bootstrap-key"
        });
        await store.EnsureBootstrapKeysAsync(TestContext.Current.CancellationToken);
        await store.UpdateAsync(
            new Dictionary<string, string?>
            {
                [LlmApiKeyProviders.OpenAi] = "saved-key"
            },
            TestContext.Current.CancellationToken);
        await store.EnsureBootstrapKeysAsync(TestContext.Current.CancellationToken);

        Assert.Equal("saved-key", await store.GetAsync(
            LlmApiKeyProviders.OpenAi,
            TestContext.Current.CancellationToken));
    }

    private LlmApiKeyStore CreateStore(
        IReadOnlyDictionary<string, string?>? values = null)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();
        return new LlmApiKeyStore(
            database,
            new EphemeralDataProtectionProvider(),
            configuration);
    }
}
