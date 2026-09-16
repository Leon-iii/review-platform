using System.Text.Json;

namespace ReviewPlatform.Server.Contracts;

public sealed record PushRequest(IReadOnlyList<PushChange> Changes);

public sealed record PushChange(
    string OperationId,
    string EntityType,
    string EntityId,
    string Operation,
    JsonElement? Payload,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record PushResponse(
    IReadOnlyList<string> AcknowledgedOperationIds,
    long ServerRevision);

public sealed record PullResponse(
    IReadOnlyList<PullChange> Changes,
    long ServerRevision,
    bool HasMore);

public sealed record PullChange(
    string EntityType,
    string EntityId,
    string Operation,
    JsonElement? Payload,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt,
    long Revision);
