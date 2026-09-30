using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;

namespace ReviewPlatform.Server.Services;

public sealed class LlmProfileService(
    SyncDbContext database,
    IOptions<LlmOptions> bootstrapOptions)
{
    public async Task EnsureInitializedAsync(
        CancellationToken cancellationToken = default)
    {
        var options = bootstrapOptions.Value;
        var profiles = await database.LlmProfiles.ToListAsync(cancellationToken);
        var assignments = await database.LlmPurposeAssignments
            .ToListAsync(cancellationToken);
        if (profiles.Count == 0)
        {
            var provider = NormalizeProvider(options.Provider);
            var profile = new LlmProfileRecord
            {
                Id = "default",
                Name = "기본 프로필",
                Provider = provider,
                Model = NormalizeBootstrapModel(provider, options.Model),
                BaseUrl = LocalBaseUrl(provider),
                UpdatedAt = DateTimeOffset.UtcNow
            };
            profiles.Add(profile);
            database.LlmProfiles.Add(profile);
        }

        var isLegacyProfileState = assignments.All(assignment =>
            assignment.Purpose != LlmPurposes.DocumentVision);
        var defaultProfile = profiles.FirstOrDefault(profile =>
            profile.Id == "default");
        var assignedVisionProfileId = assignments.FirstOrDefault(assignment =>
            assignment.Purpose == LlmPurposes.DocumentVision)?.ProfileId;
        var managedVisionProfiles = profiles.Where(profile =>
            profile.Provider.Equals("ollama", StringComparison.OrdinalIgnoreCase) &&
            profile.Model.Equals("qwen3-vl:8b", StringComparison.OrdinalIgnoreCase) &&
            ((profile.Id == "default" && profile.Id == assignedVisionProfileId) ||
             profile.Id.StartsWith("document-vision", StringComparison.Ordinal)))
            .ToList();
        foreach (var profile in managedVisionProfiles)
        {
            profile.Model = "qwen3-vl:8b-instruct";
            profile.UpdatedAt = DateTimeOffset.UtcNow;
        }
        if (isLegacyProfileState &&
            defaultProfile is not null &&
            defaultProfile.Provider.Equals("ollama", StringComparison.OrdinalIgnoreCase) &&
            defaultProfile.Model.Equals("qwen3:8b", StringComparison.OrdinalIgnoreCase))
        {
            defaultProfile.Model = "qwen3-vl:8b-instruct";
            defaultProfile.UpdatedAt = DateTimeOffset.UtcNow;
        }

        var fallbackProfile = defaultProfile ?? profiles[0];
        EnsureAssignment(
            assignments,
            LlmPurposes.QuestionGeneration,
            fallbackProfile.Id);
        EnsureAssignment(
            assignments,
            LlmPurposes.ConceptExtraction,
            fallbackProfile.Id);

        var visionProfile = profiles.FirstOrDefault(profile =>
            profile.Provider.Equals("ollama", StringComparison.OrdinalIgnoreCase) &&
            profile.Model.Equals(
                "qwen3-vl:8b-instruct",
                StringComparison.OrdinalIgnoreCase)) ??
            profiles.FirstOrDefault(profile =>
                profile.Provider.Equals("ollama", StringComparison.OrdinalIgnoreCase) &&
                profile.Model.Contains("vl", StringComparison.OrdinalIgnoreCase));
        if (visionProfile is null)
        {
            visionProfile = new LlmProfileRecord
            {
                Id = NextProfileId(profiles, "document-vision"),
                Name = "PDF 이미지 OCR",
                Provider = "ollama",
                Model = "qwen3-vl:8b-instruct",
                BaseUrl = LlmOptions.LocalOllamaBaseUrl,
                UpdatedAt = DateTimeOffset.UtcNow
            };
            profiles.Add(visionProfile);
            database.LlmProfiles.Add(visionProfile);
        }
        EnsureAssignment(
            assignments,
            LlmPurposes.DocumentVision,
            visionProfile.Id);

        await database.SaveChangesAsync(cancellationToken);
    }

    private void EnsureAssignment(
        ICollection<LlmPurposeAssignmentRecord> assignments,
        string purpose,
        string profileId)
    {
        if (assignments.Any(assignment => assignment.Purpose == purpose)) return;
        var assignment = new LlmPurposeAssignmentRecord
        {
            Purpose = purpose,
            ProfileId = profileId
        };
        assignments.Add(assignment);
        database.LlmPurposeAssignments.Add(assignment);
    }

    private static string NextProfileId(
        IReadOnlyCollection<LlmProfileRecord> profiles,
        string preferred)
    {
        var ids = profiles.Select(profile => profile.Id)
            .ToHashSet(StringComparer.Ordinal);
        if (!ids.Contains(preferred)) return preferred;
        for (var suffix = 2; ; suffix++)
        {
            var candidate = $"{preferred}-{suffix}";
            if (!ids.Contains(candidate)) return candidate;
        }
    }

    private static string NormalizeBootstrapModel(string provider, string? model)
    {
        var normalized = model?.Trim() ?? string.Empty;
        if (provider == "ollama" &&
            (normalized.Length == 0 ||
             normalized.Equals("qwen3:8b", StringComparison.OrdinalIgnoreCase) ||
             normalized.Equals("qwen3-vl:8b", StringComparison.OrdinalIgnoreCase)))
        {
            return "qwen3-vl:8b-instruct";
        }
        return normalized.Length > 0 ? normalized : "gpt-4o-mini";
    }

    public async Task<LlmProfileSettingsResponse> GetSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken);
        var profiles = await database.LlmProfiles
            .AsNoTracking()
            .OrderBy(profile => profile.Name)
            .ThenBy(profile => profile.Id)
            .Select(profile => new LlmProfileDto(
                profile.Id,
                profile.Name,
                profile.Provider,
                profile.Model,
                profile.UpdatedAt))
            .ToListAsync(cancellationToken);
        var assignments = await database.LlmPurposeAssignments
            .AsNoTracking()
            .ToDictionaryAsync(
                assignment => assignment.Purpose,
                assignment => assignment.ProfileId,
                cancellationToken);
        return new LlmProfileSettingsResponse(profiles, assignments);
    }

    public async Task<LlmProfileSettingsResponse> UpdateSettingsAsync(
        UpdateLlmProfileSettingsRequest request,
        CancellationToken cancellationToken = default)
    {
        var profiles = ValidateProfiles(request.Profiles);
        var assignments = ValidateAssignments(request.Assignments, profiles);
        var now = DateTimeOffset.UtcNow;

        await using var transaction = await database.Database.BeginTransactionAsync(
            cancellationToken);
        database.LlmPurposeAssignments.RemoveRange(
            await database.LlmPurposeAssignments.ToListAsync(cancellationToken));
        database.LlmProfiles.RemoveRange(
            await database.LlmProfiles.ToListAsync(cancellationToken));
        await database.SaveChangesAsync(cancellationToken);

        database.LlmProfiles.AddRange(profiles.Select(profile =>
            new LlmProfileRecord
            {
                Id = profile.Id,
                Name = profile.Name,
                Provider = profile.Provider,
                Model = profile.Model,
                BaseUrl = LocalBaseUrl(profile.Provider),
                UpdatedAt = now
            }));
        database.LlmPurposeAssignments.AddRange(assignments.Select(pair =>
            new LlmPurposeAssignmentRecord
            {
                Purpose = pair.Key,
                ProfileId = pair.Value
            }));
        await database.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return await GetSettingsAsync(cancellationToken);
    }

    public async Task<LlmProfileDto> GetActiveProfileAsync(
        string purpose,
        CancellationToken cancellationToken = default)
    {
        if (!LlmPurposes.All.Contains(purpose))
        {
            throw new LlmProfileValidationException(
                $"지원하지 않는 LLM 용도입니다: '{purpose}'.");
        }
        await EnsureInitializedAsync(cancellationToken);
        var profile = await (
            from assignment in database.LlmPurposeAssignments.AsNoTracking()
            join item in database.LlmProfiles.AsNoTracking()
                on assignment.ProfileId equals item.Id
            where assignment.Purpose == purpose
            select item).SingleOrDefaultAsync(cancellationToken);
        if (profile is null)
        {
            throw new LlmProviderUnavailableException(
                $"'{purpose}' 용도의 LLM 프로필이 설정되지 않았습니다.");
        }
        return new LlmProfileDto(
            profile.Id,
            profile.Name,
            profile.Provider,
            profile.Model,
            profile.UpdatedAt);
    }

    private static IReadOnlyList<LlmProfileInput> ValidateProfiles(
        IReadOnlyList<LlmProfileInput>? requested)
    {
        if (requested is null || requested.Count is < 1 or > 20)
        {
            throw new LlmProfileValidationException(
                "LLM 프로필은 1개 이상 20개 이하로 설정해 주세요.");
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<LlmProfileInput>(requested.Count);
        foreach (var item in requested)
        {
            var id = item.Id?.Trim() ?? string.Empty;
            var name = item.Name?.Trim() ?? string.Empty;
            var model = item.Model?.Trim() ?? string.Empty;
            if (id.Length is < 1 or > 64 ||
                id.Any(character => !char.IsAsciiLetterOrDigit(character) &&
                    character is not '-' and not '_'))
            {
                throw new LlmProfileValidationException(
                    "프로필 ID는 영문, 숫자, '-'와 '_'만 사용할 수 있습니다.");
            }
            if (!ids.Add(id))
            {
                throw new LlmProfileValidationException(
                    $"중복된 프로필 ID입니다: '{id}'.");
            }
            if (name.Length is < 1 or > 80)
            {
                throw new LlmProfileValidationException(
                    "프로필 이름은 1~80자로 입력해 주세요.");
            }
            if (model.Length is < 1 or > 128)
            {
                throw new LlmProfileValidationException(
                    "모델 이름은 1~128자로 입력해 주세요.");
            }
            var provider = NormalizeProvider(item.Provider);
            result.Add(new LlmProfileInput(
                id,
                name,
                provider,
                model));
        }
        return result;
    }

    private static IReadOnlyDictionary<string, string> ValidateAssignments(
        IReadOnlyDictionary<string, string>? requested,
        IReadOnlyList<LlmProfileInput> profiles)
    {
        if (requested is null ||
            requested.Count != LlmPurposes.All.Count ||
            requested.Keys.Any(key => !LlmPurposes.All.Contains(key)) ||
            LlmPurposes.All.Any(purpose => !requested.ContainsKey(purpose)))
        {
            throw new LlmProfileValidationException(
                "모든 LLM 용도에 프로필을 할당해 주세요.");
        }
        var profileIds = profiles.Select(profile => profile.Id)
            .ToHashSet(StringComparer.Ordinal);
        foreach (var pair in requested)
        {
            if (!profileIds.Contains(pair.Value))
            {
                throw new LlmProfileValidationException(
                    $"'{pair.Key}'에 존재하지 않는 프로필이 할당되었습니다.");
            }
        }
        var documentVisionProfileId = requested[LlmPurposes.DocumentVision];
        var documentVisionProfile = profiles.Single(profile =>
            profile.Id == documentVisionProfileId);
        if (documentVisionProfile.Provider == "ollama" &&
            documentVisionProfile.Model.Equals(
                "qwen3-vl:8b",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new LlmProfileValidationException(
                "PDF 이미지 OCR에는 'qwen3-vl:8b-instruct'를 사용해 주세요. " +
                "'qwen3-vl:8b'는 OCR 결과를 thinking 필드에만 반환할 수 있습니다.");
        }
        return new Dictionary<string, string>(requested, StringComparer.Ordinal);
    }

    private static string NormalizeProvider(string? value)
    {
        var provider = value?.Trim().ToLowerInvariant() ?? string.Empty;
        return provider is "ollama" or "openai"
            ? provider
            : throw new LlmProfileValidationException(
                "LLM Provider는 ollama 또는 openai여야 합니다.");
    }

    private static string LocalBaseUrl(string provider) =>
        provider == "ollama" ? LlmOptions.LocalOllamaBaseUrl : string.Empty;
}

public sealed class LlmProfileValidationException(string message)
    : Exception(message);
