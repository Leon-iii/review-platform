namespace ReviewPlatform.Server.Services;

public static class SyncConflictPolicy
{
    public static bool ShouldApply(
        string entityType,
        bool exists,
        DateTimeOffset incomingUpdatedAt,
        DateTimeOffset existingUpdatedAt,
        bool isAnswerCorrection = false)
    {
        if (!exists)
        {
            return true;
        }

        if (entityType.Equals("attempt", StringComparison.Ordinal))
        {
            return isAnswerCorrection && incomingUpdatedAt > existingUpdatedAt;
        }

        return incomingUpdatedAt >= existingUpdatedAt;
    }
}

public sealed class SyncValidationException(string message) : Exception(message);
