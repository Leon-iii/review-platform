import 'package:drift/drift.dart';

@DataClassName('SyncStateRow')
class SyncStates extends Table {
  TextColumn get id => text()();

  IntColumn get lastPulledRevision =>
      integer().withDefault(const Constant(0))();

  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  TextColumn get lastError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
