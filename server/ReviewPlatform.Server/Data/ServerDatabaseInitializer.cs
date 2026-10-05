using Microsoft.EntityFrameworkCore;

namespace ReviewPlatform.Server.Data;

public static class ServerDatabaseInitializer
{
    public static async Task InitializeAsync(
        SyncDbContext database,
        CancellationToken cancellationToken = default)
    {
        await database.Database.EnsureCreatedAsync(cancellationToken);
        await database.Database.ExecuteSqlRawAsync(
            """
            CREATE TABLE IF NOT EXISTS "AiGenerationRecords" (
                "Id" TEXT NOT NULL CONSTRAINT "PK_AiGenerationRecords" PRIMARY KEY,
                "Provider" TEXT NOT NULL,
                "Model" TEXT NOT NULL,
                "PromptVersion" TEXT NOT NULL,
                "RequestedAt" TEXT NOT NULL,
                "InputHash" TEXT NOT NULL,
                "SourceLabel" TEXT NULL,
                "RequestedQuestionCount" INTEGER NOT NULL,
                "QuestionTypesJson" TEXT NOT NULL,
                "Status" TEXT NOT NULL,
                "OutputJson" TEXT NULL,
                "Error" TEXT NULL
            );
            CREATE INDEX IF NOT EXISTS "IX_AiGenerationRecords_RequestedAt"
                ON "AiGenerationRecords" ("RequestedAt");
            CREATE TABLE IF NOT EXISTS "LlmProfiles" (
                "Id" TEXT NOT NULL CONSTRAINT "PK_LlmProfiles" PRIMARY KEY,
                "Name" TEXT NOT NULL,
                "Provider" TEXT NOT NULL,
                "Model" TEXT NOT NULL,
                "BaseUrl" TEXT NOT NULL,
                "UpdatedAt" TEXT NOT NULL,
                "ContextWindowTokens" INTEGER NULL,
                "ReasoningEffort" TEXT NULL,
                "MaximumQuestionsPerRequest" INTEGER NOT NULL DEFAULT 120
            );
            CREATE TABLE IF NOT EXISTS "LlmPurposeAssignments" (
                "Purpose" TEXT NOT NULL CONSTRAINT "PK_LlmPurposeAssignments" PRIMARY KEY,
                "ProfileId" TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS "LlmProviderSecrets" (
                "Provider" TEXT NOT NULL CONSTRAINT "PK_LlmProviderSecrets" PRIMARY KEY,
                "ProtectedValue" TEXT NOT NULL,
                "UpdatedAt" TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS "DocumentJobs" (
                "Id" TEXT NOT NULL PRIMARY KEY,
                "FileName" TEXT NOT NULL,
                "Status" TEXT NOT NULL,
                "CheckpointJson" TEXT NOT NULL,
                "VisionProfileJson" TEXT NOT NULL,
                "ConceptProfileJson" TEXT NOT NULL,
                "ResultJson" TEXT NULL,
                "Error" TEXT NULL,
                "UpdatedAt" TEXT NOT NULL
            );
            """,
            cancellationToken);

        // EnsureCreated does not update an existing SQLite schema.
        var connection = database.Database.GetDbConnection();
        await database.Database.OpenConnectionAsync(cancellationToken);
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA table_info(\"LlmProfiles\")";
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var hasContextColumn = false;
            var hasReasoningColumn = false;
            var hasQuestionLimitColumn = false;
            while (await reader.ReadAsync(cancellationToken))
            {
                if (reader.GetString(1) == "ContextWindowTokens")
                    hasContextColumn = true;
                if (reader.GetString(1) == "ReasoningEffort")
                    hasReasoningColumn = true;
                if (reader.GetString(1) == "MaximumQuestionsPerRequest")
                    hasQuestionLimitColumn = true;
            }
            await reader.DisposeAsync();
            if (!hasContextColumn)
            {
                await database.Database.ExecuteSqlRawAsync(
                    "ALTER TABLE \"LlmProfiles\" ADD COLUMN \"ContextWindowTokens\" INTEGER NULL",
                    cancellationToken);
            }
            if (!hasReasoningColumn)
            {
                await database.Database.ExecuteSqlRawAsync(
                    "ALTER TABLE \"LlmProfiles\" ADD COLUMN \"ReasoningEffort\" TEXT NULL",
                    cancellationToken);
            }
            if (!hasQuestionLimitColumn)
            {
                await database.Database.ExecuteSqlRawAsync(
                    "ALTER TABLE \"LlmProfiles\" ADD COLUMN \"MaximumQuestionsPerRequest\" INTEGER NOT NULL DEFAULT 120",
                    cancellationToken);
            }
        }
        finally
        {
            await database.Database.CloseConnectionAsync();
        }
        await QuestionAnswerFormatMigration.MigrateAsync(database, cancellationToken);
    }
}
