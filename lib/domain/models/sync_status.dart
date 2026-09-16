import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';

class SyncOutboxEntry {
  const SyncOutboxEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.createdAt,
    required this.retryCount,
    this.lastError,
  });

  final String id;
  final SyncEntityType entityType;
  final String entityId;
  final SyncOperation operation;
  final DateTime createdAt;
  final int retryCount;
  final String? lastError;
}

class SyncStatus {
  const SyncStatus({
    required this.pendingCount,
    required this.lastPulledRevision,
    this.lastSyncedAt,
    this.lastError,
  });

  final int pendingCount;
  final int lastPulledRevision;
  final DateTime? lastSyncedAt;
  final String? lastError;
}
