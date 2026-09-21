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
                "UpdatedAt" TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS "LlmPurposeAssignments" (
                "Purpose" TEXT NOT NULL CONSTRAINT "PK_LlmPurposeAssignments" PRIMARY KEY,
                "ProfileId" TEXT NOT NULL
            );
            """,
            cancellationToken);
    }
}
