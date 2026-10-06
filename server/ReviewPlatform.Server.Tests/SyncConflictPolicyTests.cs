using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class SyncConflictPolicyTests
{
    private static readonly DateTimeOffset ExistingTime =
        DateTimeOffset.Parse("2026-09-16T00:00:00Z");

    [Fact]
    public void NewEntity_IsApplied()
    {
        var result = SyncConflictPolicy.ShouldApply(
            "question",
            exists: false,
            ExistingTime.AddDays(-1),
            ExistingTime);

        Assert.True(result);
    }

    [Fact]
    public void MutableEntity_UsesLastWriteWins()
    {
        Assert.True(SyncConflictPolicy.ShouldApply(
            "folder",
            exists: true,
            ExistingTime.AddMinutes(1),
            ExistingTime));
        Assert.False(SyncConflictPolicy.ShouldApply(
            "folder",
            exists: true,
            ExistingTime.AddMinutes(-1),
            ExistingTime));
    }

    [Fact]
    public void ExistingAttempt_IsNeverOverwritten()
    {
        var result = SyncConflictPolicy.ShouldApply(
            "attempt",
            exists: true,
            ExistingTime.AddDays(1),
            ExistingTime);

        Assert.False(result);
    }

    [Fact]
    public void ExplicitAnswerCorrection_UsesStrictlyNewerVersion()
    {
        Assert.True(SyncConflictPolicy.ShouldApply("attempt", true,
            ExistingTime.AddSeconds(1), ExistingTime, isAnswerCorrection: true));
        Assert.False(SyncConflictPolicy.ShouldApply("attempt", true,
            ExistingTime, ExistingTime, isAnswerCorrection: true));
        Assert.False(SyncConflictPolicy.ShouldApply("attempt", true,
            ExistingTime.AddSeconds(-1), ExistingTime, isAnswerCorrection: true));
    }
}
