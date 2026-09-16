import 'package:drift/drift.dart';

@DataClassName('SyncOutboxRow')
class SyncOutbox extends Table {
  TextColumn get id => text()();

  TextColumn get entityType => text()();

  TextColumn get entityId => text()();

  TextColumn get operation => text()();

  DateTimeColumn get createdAt => dateTime()();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  TextColumn get lastError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
