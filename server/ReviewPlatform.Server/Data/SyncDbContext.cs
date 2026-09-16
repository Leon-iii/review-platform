using Microsoft.EntityFrameworkCore;

namespace ReviewPlatform.Server.Data;

public sealed class SyncDbContext(DbContextOptions<SyncDbContext> options)
    : DbContext(options)
{
    public DbSet<SyncEntityRecord> SyncEntities => Set<SyncEntityRecord>();
    public DbSet<SyncRevisionState> SyncRevisions => Set<SyncRevisionState>();
    public DbSet<ProcessedSyncOperation> ProcessedOperations =>
        Set<ProcessedSyncOperation>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<SyncEntityRecord>(entity =>
        {
            entity.HasKey(record => new { record.EntityType, record.EntityId });
            entity.Property(record => record.EntityType).HasMaxLength(32);
            entity.Property(record => record.EntityId).HasMaxLength(64);
            entity.HasIndex(record => record.Revision).IsUnique();
        });

        modelBuilder.Entity<SyncRevisionState>(entity =>
        {
            entity.HasKey(state => state.Id);
        });

        modelBuilder.Entity<ProcessedSyncOperation>(entity =>
        {
            entity.HasKey(operation => operation.Id);
            entity.Property(operation => operation.Id).HasMaxLength(64);
        });
    }
}

public sealed class SyncEntityRecord
{
    public required string EntityType { get; set; }
    public required string EntityId { get; set; }
    public string? PayloadJson { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public DateTimeOffset? DeletedAt { get; set; }
    public long Revision { get; set; }
}

public sealed class SyncRevisionState
{
    public const int SingletonId = 1;

    public int Id { get; set; } = SingletonId;
    public long CurrentRevision { get; set; }
}

public sealed class ProcessedSyncOperation
{
    public required string Id { get; set; }
    public DateTimeOffset ProcessedAt { get; set; }
}
