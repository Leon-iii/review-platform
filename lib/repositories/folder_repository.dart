import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:uuid/uuid.dart';

abstract interface class FolderRepository {
  Future<String> createFolder({required String name, String? parentId});

  Future<void> renameFolder({required String id, required String name});

  Future<void> moveFolder({required String id, String? parentId});

  Future<FolderDeletionImpact> getDeletionImpact(String id);

  Future<void> deleteFolder(String id);

  Stream<List<FolderNode>> watchFolderTree();

  Future<List<String>> getDescendantIds(String id);
}

class DriftFolderRepository implements FolderRepository {
  DriftFolderRepository(this._database);

  final AppDatabase _database;
  final Uuid _uuid = const Uuid();

  @override
  Future<String> createFolder({required String name, String? parentId}) {
    return _guard(() async {
      final normalizedName = _validateName(name);
      final now = DateTime.now().toUtc();
      final id = _uuid.v4();

      await _database.transaction(() async {
        if (parentId != null) {
          await _requireFolder(parentId);
        }

        await _database.folderDao.insertFolder(
          FoldersCompanion.insert(
            id: id,
            parentId: Value(parentId),
            name: normalizedName,
            createdAt: now,
            updatedAt: now,
          ),
        );
      });

      return id;
    }, '폴더를 생성하지 못했어요.');
  }

  @override
  Future<void> renameFolder({required String id, required String name}) {
    return _guard(() async {
      final normalizedName = _validateName(name);

      await _database.transaction(() async {
        await _requireFolder(id);
        await _database.folderDao.renameFolder(
          id: id,
          name: normalizedName,
          updatedAt: DateTime.now().toUtc(),
        );
      });
    }, '폴더 이름을 변경하지 못했어요.');
  }

  @override
  Future<void> moveFolder({required String id, String? parentId}) {
    return _guard(() async {
      await _database.transaction(() async {
        await _requireFolder(id);

        if (parentId != null) {
          await _requireFolder(parentId);
          if (id == parentId) {
            throw const ValidationFailure('폴더를 자기 자신 안으로 옮길 수 없어요.');
          }

          final descendantIds = await _database.folderDao.getDescendantIds(id);
          if (descendantIds.contains(parentId)) {
            throw const ValidationFailure('하위 폴더 안으로 옮길 수 없어요.');
          }
        }

        await _database.folderDao.moveFolder(
          id: id,
          parentId: parentId,
          updatedAt: DateTime.now().toUtc(),
        );
      });
    }, '폴더를 옮기지 못했어요.');
  }

  @override
  Future<FolderDeletionImpact> getDeletionImpact(String id) {
    return _guard(() async {
      await _requireFolder(id);
      final descendantIds = await _database.folderDao.getDescendantIds(id);
      final folderIds = [id, ...descendantIds];

      return FolderDeletionImpact(
        descendantFolderCount: descendantIds.length,
        questionCount: await _database.questionDao
            .countActiveQuestionsInFolders(folderIds),
      );
    }, '삭제할 폴더 정보를 확인하지 못했어요.');
  }

  @override
  Future<void> deleteFolder(String id) {
    return _guard(() async {
      await _database.transaction(() async {
        await _requireFolder(id);
        final descendantIds = await _database.folderDao.getDescendantIds(id);
        final deletedAt = DateTime.now().toUtc();
        final folderIds = [id, ...descendantIds];

        await _database.folderDao.softDeleteFolders(
          ids: folderIds,
          deletedAt: deletedAt,
        );
        await _database.questionDao.softDeleteQuestionsInFolders(
          folderIds: folderIds,
          deletedAt: deletedAt,
        );
      });
    }, '폴더를 삭제하지 못했어요.');
  }

  @override
  Stream<List<FolderNode>> watchFolderTree() async* {
    try {
      await for (final rows in _database.folderDao.watchActiveFolders()) {
        yield _buildTree(rows);
      }
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure('폴더 목록을 불러오지 못했어요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<List<String>> getDescendantIds(String id) {
    return _guard(() async {
      await _requireFolder(id);
      return _database.folderDao.getDescendantIds(id);
    }, '하위 폴더를 확인하지 못했어요.');
  }

  Future<FolderRow> _requireFolder(String id) async {
    final folder = await _database.folderDao.getActiveFolder(id);
    if (folder == null) {
      throw const ValidationFailure('폴더를 찾을 수 없어요.');
    }
    return folder;
  }

  String _validateName(String name) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw const ValidationFailure('폴더 이름을 입력해 주세요.');
    }
    return normalizedName;
  }

  List<FolderNode> _buildTree(List<FolderRow> rows) {
    final foldersByParent = <String?, List<FolderRow>>{};
    for (final row in rows) {
      foldersByParent.putIfAbsent(row.parentId, () => []).add(row);
    }

    FolderNode buildNode(FolderRow row) {
      final children = foldersByParent[row.id] ?? const <FolderRow>[];
      return FolderNode(
        folder: _toDomain(row),
        children: List.unmodifiable(children.map(buildNode)),
      );
    }

    final roots = foldersByParent[null] ?? const <FolderRow>[];
    return List.unmodifiable(roots.map(buildNode));
  }

  Folder _toDomain(FolderRow row) {
    return Folder(
      id: row.id,
      parentId: row.parentId,
      name: row.name,
      createdAt: row.createdAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
      deletedAt: row.deletedAt?.toUtc(),
    );
  }

  Future<T> _guard<T>(Future<T> Function() action, String message) async {
    try {
      return await action();
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure(message, cause: error),
        stackTrace,
      );
    }
  }
}
