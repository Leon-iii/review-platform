import 'package:drift/drift.dart';

@DataClassName('DocumentJobRow')
class DocumentJobs extends Table {
  TextColumn get id => text()();
  TextColumn get folderId => text()();
  // No tokens or API keys are stored here. Credentials come from secure storage.
  TextColumn get serverUrl => text()();
  TextColumn get statusJson => text()();
  BoolColumn get applied => boolean().withDefault(const Constant(false))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}
