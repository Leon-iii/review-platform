import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/folders.dart';
import 'package:review_platform/core/database/tables/questions.dart';
import 'package:review_platform/core/database/tables/study_sources.dart';

part 'folder_dao.g.dart';

class FolderRowWithCounts {
  const FolderRowWithCounts({
    required this.folder,
    required this.questionCount,
    required this.sourceCount,
  });

  final FolderRow folder;
  final int questionCount;
  final int sourceCount;
}

@DriftAccessor(tables: [Folders, Questions, StudySources])
class FolderDao extends DatabaseAccessor<AppDatabase> with _$FolderDaoMixin {
  FolderDao(super.attachedDatabase);

  Stream<List<FolderRow>> watchActiveFolders() {
    return (select(folders)
          ..where((folder) => folder.deletedAt.isNull())
          ..orderBy([(folder) => OrderingTerm.asc(folder.name)]))
        .watch();
  }

  Stream<List<FolderRowWithCounts>> watchActiveFoldersWithCounts() {
    final questionCount = questions.id.count(distinct: true);
    final sourceCount = studySources.id.count(distinct: true);
    final query = select(folders).join([
      leftOuterJoin(
        questions,
        questions.folderId.equalsExp(folders.id) & questions.deletedAt.isNull(),
      ),
      leftOuterJoin(studySources, studySources.folderId.equalsExp(folders.id)),
    ]);
    query
      ..addColumns([questionCount, sourceCount])
      ..where(folders.deletedAt.isNull())
      ..groupBy([folders.id])
      ..orderBy([OrderingTerm.asc(folders.name)]);
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => FolderRowWithCounts(
              folder: row.readTable(folders),
              questionCount: row.read(questionCount) ?? 0,
              sourceCount: row.read(sourceCount) ?? 0,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<FolderRow?> getActiveFolder(String id) {
    return (select(folders)
          ..where((folder) => folder.id.equals(id) & folder.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<FolderRow?> getFolder(String id) {
    return (select(
      folders,
    )..where((folder) => folder.id.equals(id))).getSingleOrNull();
  }

  Future<void> upsertFolder(FoldersCompanion folder) {
    return into(folders).insertOnConflictUpdate(folder);
  }

  Future<void> insertFolder(FoldersCompanion folder) {
    return into(folders).insert(folder);
  }

  Future<void> renameFolder({
    required String id,
    required String name,
    required DateTime updatedAt,
  }) {
    return (update(folders)..where((folder) => folder.id.equals(id))).write(
      FoldersCompanion(name: Value(name), updatedAt: Value(updatedAt)),
    );
  }

  Future<void> moveFolder({
    required String id,
    required String? parentId,
    required DateTime updatedAt,
  }) {
    return (update(folders)..where((folder) => folder.id.equals(id))).write(
      FoldersCompanion(parentId: Value(parentId), updatedAt: Value(updatedAt)),
    );
  }

  Future<List<String>> getDescendantIds(String folderId) async {
    final rows = await customSelect(
      '''
      WITH RECURSIVE folder_tree(id) AS (
        SELECT id
        FROM folders
        WHERE id = ? AND deleted_at IS NULL

        UNION ALL

        SELECT child.id
        FROM folders AS child
        INNER JOIN folder_tree AS parent ON child.parent_id = parent.id
        WHERE child.deleted_at IS NULL
      )
      SELECT id FROM folder_tree WHERE id != ?
      ''',
      variables: [Variable.withString(folderId), Variable.withString(folderId)],
      readsFrom: {folders},
    ).get();

    return [for (final row in rows) row.read<String>('id')];
  }

  Future<void> softDeleteFolders({
    required Iterable<String> ids,
    required DateTime deletedAt,
  }) async {
    await batch((batch) {
      for (final id in ids) {
        batch.update(
          folders,
          FoldersCompanion(
            updatedAt: Value(deletedAt),
            deletedAt: Value(deletedAt),
          ),
          where: (folder) => folder.id.equals(id),
        );
      }
    });
  }
}
