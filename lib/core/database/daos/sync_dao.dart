import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/sync_outbox.dart';
import 'package:review_platform/core/database/tables/sync_states.dart';
import 'package:uuid/uuid.dart';

part 'sync_dao.g.dart';

class SyncDatabaseStatus {
  const SyncDatabaseStatus({required this.pendingCount, required this.state});

  final int pendingCount;
  final SyncStateRow state;
}

@DriftAccessor(tables: [SyncOutbox, SyncStates])
class SyncDao extends DatabaseAccessor<AppDatabase> with _$SyncDaoMixin {
  SyncDao(super.attachedDatabase);

  static const stateId = 'primary';
  static const _uuid = Uuid();

  Future<void> enqueue({
    required String entityType,
    required String entityId,
    required String operation,
    required DateTime createdAt,
  }) {
    return into(syncOutbox).insert(
      SyncOutboxCompanion.insert(
        id: _uuid.v4(),
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        createdAt: createdAt,
      ),
    );
  }

  Future<List<SyncOutboxRow>> getPending({int limit = 100}) {
    return (select(syncOutbox)
          ..orderBy([(entry) => OrderingTerm.asc(entry.createdAt)])
          ..limit(limit))
        .get();
  }

  Stream<int> watchPendingCount() {
    final count = syncOutbox.id.count();
    final query = selectOnly(syncOutbox)..addColumns([count]);
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  Future<int> getPendingCount() async {
    final count = syncOutbox.id.count();
    final row = await (selectOnly(syncOutbox)..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> markFailed({required String id, required String error}) {
    return customStatement(
      '''
      UPDATE sync_outbox
      SET retry_count = retry_count + 1, last_error = ?
      WHERE id = ?
      ''',
      [error, id],
    );
  }

  Future<void> removeAcknowledged(Iterable<String> ids) {
    final values = ids.toList(growable: false);
    if (values.isEmpty) return Future.value();
    return (delete(syncOutbox)..where((entry) => entry.id.isIn(values))).go();
  }

  Future<SyncStateRow> getState() async {
    final existing = await (select(
      syncStates,
    )..where((state) => state.id.equals(stateId))).getSingleOrNull();
    if (existing != null) return existing;

    await into(syncStates).insert(
      SyncStatesCompanion.insert(id: stateId),
      mode: InsertMode.insertOrIgnore,
    );
    return (select(
      syncStates,
    )..where((state) => state.id.equals(stateId))).getSingle();
  }

  Stream<SyncStateRow> watchState() async* {
    await getState();
    yield* (select(
      syncStates,
    )..where((state) => state.id.equals(stateId))).watchSingle();
  }

  Stream<SyncDatabaseStatus> watchStatus() async* {
    await getState();
    final changes = customSelect(
      'SELECT 1 AS value',
      readsFrom: {syncOutbox, syncStates},
    ).watch();
    await for (final _ in changes) {
      final countExpression = syncOutbox.id.count();
      final countRow = await (selectOnly(
        syncOutbox,
      )..addColumns([countExpression])).getSingle();
      yield SyncDatabaseStatus(
        pendingCount: countRow.read(countExpression) ?? 0,
        state: await getState(),
      );
    }
  }

  Future<void> updateState({
    required int lastPulledRevision,
    required DateTime lastSyncedAt,
    String? lastError,
  }) {
    return into(syncStates).insertOnConflictUpdate(
      SyncStatesCompanion.insert(
        id: stateId,
        lastPulledRevision: Value(lastPulledRevision),
        lastSyncedAt: Value(lastSyncedAt),
        lastError: Value(lastError),
      ),
    );
  }

  Future<void> setLastError(String error) async {
    await getState();
    await (update(syncStates)..where((state) => state.id.equals(stateId)))
        .write(SyncStatesCompanion(lastError: Value(error)));
  }
}
