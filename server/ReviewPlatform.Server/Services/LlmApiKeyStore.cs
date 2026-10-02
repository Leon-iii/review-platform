using Microsoft.AspNetCore.DataProtection;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;

public interface ILlmApiKeyStore
{
    Task EnsureBootstrapKeysAsync(CancellationToken cancellationToken = default);

    Task<string> GetAsync(
        string provider,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyDictionary<string, bool>> GetConfiguredAsync(
        CancellationToken cancellationToken = default);

    Task UpdateAsync(
        IReadOnlyDictionary<string, string?>? apiKeys,
        CancellationToken cancellationToken = default);
}

public sealed class LlmApiKeyStore(
    SyncDbContext database,
    IDataProtectionProvider dataProtectionProvider,
    IConfiguration configuration) : ILlmApiKeyStore
{
    private readonly IDataProtector protector = dataProtectionProvider.CreateProtector(
        "ReviewPlatform.Server.LlmApiKeys.v1");

    public async Task EnsureBootstrapKeysAsync(
        CancellationToken cancellationToken = default)
    {
        var existing = await database.LlmProviderSecrets
            .Select(secret => secret.Provider)
            .ToHashSetAsync(StringComparer.Ordinal, cancellationToken);
        var bootstrap = new Dictionary<string, string?>
        {
            [LlmApiKeyProviders.OpenAi] =
                configuration["OPENAI_API_KEY"] ?? configuration["Llm:ApiKey"],
            [LlmApiKeyProviders.Gemini] = configuration["GEMINI_API_KEY"],
            [LlmApiKeyProviders.Claude] =
                configuration["ANTHROPIC_API_KEY"] ?? configuration["CLAUDE_API_KEY"]
        };
        var changed = false;
        foreach (var pair in bootstrap)
        {
            var value = pair.Value?.Trim() ?? string.Empty;
            if (value.Length == 0 || existing.Contains(pair.Key)) continue;
            database.LlmProviderSecrets.Add(new LlmProviderSecretRecord
            {
                Provider = pair.Key,
                ProtectedValue = protector.Protect(value),
                UpdatedAt = DateTimeOffset.UtcNow
            });
            changed = true;
        }
        if (changed) await database.SaveChangesAsync(cancellationToken);
    }

    public async Task<string> GetAsync(
        string provider,
        CancellationToken cancellationToken = default)
    {
        ValidateProvider(provider);
        await EnsureBootstrapKeysAsync(cancellationToken);
        var protectedValue = await database.LlmProviderSecrets
            .AsNoTracking()
            .Where(secret => secret.Provider == provider)
            .Select(secret => secret.ProtectedValue)
            .SingleOrDefaultAsync(cancellationToken);
        if (string.IsNullOrEmpty(protectedValue)) return string.Empty;
        try
        {
            return protector.Unprotect(protectedValue);
        }
        catch (Exception exception)
        {
            throw new LlmApiKeyStoreException(
                $"'{provider}' API Key를 복호화하지 못했습니다. 키를 다시 저장해 주세요.",
                exception);
        }
    }

    public async Task<IReadOnlyDictionary<string, bool>> GetConfiguredAsync(
        CancellationToken cancellationToken = default)
    {
        await EnsureBootstrapKeysAsync(cancellationToken);
        var configured = await database.LlmProviderSecrets
            .AsNoTracking()
            .Select(secret => secret.Provider)
            .ToHashSetAsync(StringComparer.Ordinal, cancellationToken);
        return LlmApiKeyProviders.All.ToDictionary(
            provider => provider,
            configured.Contains,
            StringComparer.Ordinal);
    }

    public async Task UpdateAsync(
        IReadOnlyDictionary<string, string?>? apiKeys,
        CancellationToken cancellationToken = default)
    {
        if (apiKeys is null || apiKeys.Count == 0) return;
        foreach (var pair in apiKeys)
        {
            ValidateProvider(pair.Key);
            var value = pair.Value?.Trim() ?? string.Empty;
            if (value.Length == 0) continue;
            if (value.Length > 2_000)
            {
                throw new LlmApiKeyStoreException(
                    "API Key는 2,000자 이하여야 합니다.");
            }
            var existing = await database.LlmProviderSecrets.FindAsync(
                [pair.Key],
                cancellationToken);
            if (existing is null)
            {
                database.LlmProviderSecrets.Add(new LlmProviderSecretRecord
                {
                    Provider = pair.Key,
                    ProtectedValue = protector.Protect(value),
                    UpdatedAt = DateTimeOffset.UtcNow
                });
            }
            else
            {
                existing.ProtectedValue = protector.Protect(value);
                existing.UpdatedAt = DateTimeOffset.UtcNow;
            }
        }
        await database.SaveChangesAsync(cancellationToken);
    }

    private static void ValidateProvider(string provider)
    {
        if (!LlmApiKeyProviders.All.Contains(provider))
        {
            throw new LlmApiKeyStoreException(
                $"지원하지 않는 API Key Provider입니다: '{provider}'.");
        }
    }
}

public sealed class LlmApiKeyStoreException(
    string message,
    Exception? inner = null) : Exception(message, inner);
