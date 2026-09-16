class SyncConfiguration {
  const SyncConfiguration({required this.serverUrl, required this.accessToken});

  final String serverUrl;
  final String accessToken;
}

class SyncSettings {
  const SyncSettings({required this.serverUrl, required this.hasAccessToken});

  final String serverUrl;
  final bool hasAccessToken;
}

class PushSyncChange {
  const PushSyncChange({
    required this.operationId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.updatedAt,
    this.payload,
    this.deletedAt,
  });

  final String operationId;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, Object?>? payload;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'entityType': entityType,
    'entityId': entityId,
    'operation': operation,
    'payload': payload,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
  };
}

class PushSyncResponse {
  const PushSyncResponse({
    required this.acknowledgedOperationIds,
    required this.serverRevision,
  });

  final List<String> acknowledgedOperationIds;
  final int serverRevision;
}

class PullSyncChange {
  const PullSyncChange({
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.updatedAt,
    required this.revision,
    this.payload,
    this.deletedAt,
  });

  factory PullSyncChange.fromJson(Map<String, Object?> json) {
    final payload = json['payload'];
    return PullSyncChange(
      entityType: json['entityType']! as String,
      entityId: json['entityId']! as String,
      operation: json['operation']! as String,
      payload: payload == null
          ? null
          : Map<String, Object?>.from(payload as Map),
      updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt']! as String).toUtc(),
      revision: (json['revision']! as num).toInt(),
    );
  }

  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, Object?>? payload;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final int revision;
}

class PullSyncResponse {
  const PullSyncResponse({
    required this.changes,
    required this.serverRevision,
    required this.hasMore,
  });

  final List<PullSyncChange> changes;
  final int serverRevision;
  final bool hasMore;
}

class SyncRunResult {
  const SyncRunResult({
    required this.pushedCount,
    required this.pulledCount,
    required this.serverRevision,
  });

  final int pushedCount;
  final int pulledCount;
  final int serverRevision;
}
