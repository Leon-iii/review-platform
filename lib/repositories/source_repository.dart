import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:uuid/uuid.dart';

abstract interface class SourceRepository {
  Future<StudySourceWithConcepts> saveImport({
    required String folderId,
    required DocumentImportResult result,
  });

  Stream<List<StudySource>> watchSources(String folderId);

  Future<List<StudySource>> getSources(String folderId);

  Stream<List<StudyConcept>> watchConcepts(String sourceId);

  Future<StudySourceWithConcepts> getSourceWithConcepts(String sourceId);

  Future<void> renameSource({required String id, required String fileName});

  Future<void> moveSource({required String id, required String folderId});

  Future<void> deleteSource(String id);

  Future<void> setConceptApproval({required String id, required bool approved});

  Future<void> updateConcept({
    required String id,
    required String title,
    required String content,
    required ConceptImportance importance,
  });

  Future<void> deleteConcept(String id);

  Future<ConceptRevisionApplyResult> applyConceptRevisions({
    required String sourceId,
    required List<ConceptRevision> revisions,
  });

  Future<ConceptGenerationSeed> getConceptGenerationSeed(String conceptId);
}

class DriftSourceRepository implements SourceRepository {
  DriftSourceRepository(this._database);

  final AppDatabase _database;
  final Uuid _uuid = const Uuid();

  @override
  Future<StudySourceWithConcepts> saveImport({
    required String folderId,
    required DocumentImportResult result,
  }) {
    return _guard(() async {
      if (await _database.folderDao.getActiveFolder(folderId) == null) {
        throw const ValidationFailure('자료를 저장할 폴더를 찾을 수 없어요.');
      }
      if (result.concepts.isEmpty) {
        throw const ValidationFailure('저장할 개념이 없어요.');
      }
      final now = DateTime.now().toUtc();
      final concepts = [
        for (final imported in result.concepts)
          StudyConcept(
            id: _uuid.v4(),
            sourceId: result.source.id,
            title: imported.title.trim(),
            content: imported.content.trim(),
            pageNumbers: imported.pageNumbers.toSet().toList()..sort(),
            status: ConceptStatus.held,
            importance: imported.importance,
            createdAt: now,
            updatedAt: now,
          ),
      ];
      if (concepts.any(
        (concept) =>
            concept.title.isEmpty ||
            concept.content.isEmpty ||
            concept.pageNumbers.isEmpty,
      )) {
        throw const ValidationFailure('추출된 개념 정보가 올바르지 않아요.');
      }

      await _database.transaction(() async {
        await _database.sourceDao.insertSource(
          StudySourcesCompanion.insert(
            id: result.source.id,
            folderId: folderId,
            fileName: result.source.fileName,
            contentHash: result.source.contentHash,
            pageCount: result.source.pageCount,
            extractionMethod: result.source.extractionMethod,
            importedAt: result.source.importedAt,
          ),
        );
        await _database.sourceDao.insertConcepts([
          for (final concept in concepts)
            ConceptsCompanion.insert(
              id: concept.id,
              sourceId: concept.sourceId,
              title: concept.title,
              content: concept.content,
              pageNumbersJson: jsonEncode(concept.pageNumbers),
              status: concept.status.name,
              importance: Value(concept.importance.name),
              createdAt: concept.createdAt,
              updatedAt: concept.updatedAt,
            ),
        ]);
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.source.name,
          entityId: result.source.id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
        for (var index = 0; index < concepts.length; index++) {
          final concept = concepts[index];
          await _database.syncDao.enqueue(
            entityType: SyncEntityType.concept.name,
            entityId: concept.id,
            operation: SyncOperation.upsert.name,
            createdAt: now.add(Duration(microseconds: index + 1)),
          );
        }
      });

      return StudySourceWithConcepts(
        source: StudySource(
          id: result.source.id,
          folderId: folderId,
          fileName: result.source.fileName,
          contentHash: result.source.contentHash,
          pageCount: result.source.pageCount,
          extractionMethod: result.source.extractionMethod,
          importedAt: result.source.importedAt,
        ),
        concepts: _sortConcepts(concepts),
      );
    }, 'PDF 추출 결과를 저장하지 못했어요.');
  }

  @override
  Stream<List<StudySource>> watchSources(String folderId) {
    return _database.sourceDao
        .watchSources(folderId)
        .map((rows) => rows.map(_sourceFromRow).toList(growable: false));
  }

  @override
  Future<List<StudySource>> getSources(String folderId) {
    return _guard(
      () async =>
          (await _database.sourceDao.getSources(folderId))
              .map(_sourceFromRow)
              .toList(growable: false),
      '학습 자료 목록을 불러오지 못했어요.',
    );
  }

  @override
  Stream<List<StudyConcept>> watchConcepts(String sourceId) {
    return _database.sourceDao
        .watchConcepts(sourceId)
        .map((rows) => rows.map(_conceptFromRow).toList(growable: false));
  }

  @override
  Future<StudySourceWithConcepts> getSourceWithConcepts(String sourceId) {
    return _guard(() async {
      final sourceRow = await _database.sourceDao.getSource(sourceId);
      if (sourceRow == null) {
        throw const ValidationFailure('학습 자료를 찾을 수 없어요.');
      }
      final conceptRows = await _database.sourceDao.getConcepts(sourceId);
      return StudySourceWithConcepts(
        source: _sourceFromRow(sourceRow),
        concepts: _sortConcepts(conceptRows.map(_conceptFromRow)),
      );
    }, '학습 자료를 불러오지 못했어요.');
  }

  @override
  Future<void> moveSource({required String id, required String folderId}) {
    return _guard(() async {
      await _database.transaction(() async {
        final source = await _database.sourceDao.getSource(id);
        if (source == null) {
          throw const ValidationFailure('학습 자료를 찾을 수 없어요.');
        }
        if (await _database.folderDao.getActiveFolder(folderId) == null) {
          throw const ValidationFailure('자료를 이동할 폴더를 찾을 수 없어요.');
        }
        if (source.folderId == folderId) return;

        // Concepts and question source references keep the same source ID.
        await _database.sourceDao.updateSource(
          id,
          StudySourcesCompanion(folderId: Value(folderId)),
        );
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.source.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: DateTime.now().toUtc(),
        );
      });
    }, 'PDF 강의자료를 이동하지 못했어요.');
  }

  @override
  Future<void> renameSource({required String id, required String fileName}) {
    return _guard(() async {
      final source = await _database.sourceDao.getSource(id);
      if (source == null) {
        throw const ValidationFailure('학습 자료를 찾을 수 없어요.');
      }
      var normalized = fileName.trim();
      if (normalized.isEmpty) {
        throw const ValidationFailure('자료 이름을 입력해 주세요.');
      }
      if (!normalized.toLowerCase().endsWith('.pdf')) {
        normalized = '$normalized.pdf';
      }
      if (normalized.length > 200) {
        throw const ValidationFailure('자료 이름은 200자 이하로 입력해 주세요.');
      }
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.sourceDao.updateSource(
          id,
          StudySourcesCompanion(fileName: Value(normalized)),
        );
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.source.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '학습 자료 이름을 변경하지 못했어요.');
  }

  @override
  Future<void> deleteSource(String id) {
    return _guard(() async {
      final source = await _database.sourceDao.getSource(id);
      if (source == null) {
        throw const ValidationFailure('학습 자료를 찾을 수 없어요.');
      }
      final concepts = await _database.sourceDao.getConcepts(id);
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        for (var index = 0; index < concepts.length; index++) {
          await _database.syncDao.enqueue(
            entityType: SyncEntityType.concept.name,
            entityId: concepts[index].id,
            operation: SyncOperation.delete.name,
            createdAt: now.add(Duration(microseconds: index)),
          );
        }
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.source.name,
          entityId: id,
          operation: SyncOperation.delete.name,
          createdAt: now.add(Duration(microseconds: concepts.length)),
        );
        await _database.sourceDao.deleteSourceGraph(id);
      });
    }, '학습 자료를 삭제하지 못했어요.');
  }

  @override
  Future<void> setConceptApproval({
    required String id,
    required bool approved,
  }) => _setStatus(id, approved ? ConceptStatus.approved : ConceptStatus.held);

  @override
  Future<void> updateConcept({
    required String id,
    required String title,
    required String content,
    required ConceptImportance importance,
  }) {
    return _guard(() async {
      final normalizedTitle = title.trim();
      final normalizedContent = content.trim();
      if (normalizedTitle.isEmpty || normalizedContent.isEmpty) {
        throw const ValidationFailure('제목과 내용을 모두 입력해 주세요.');
      }
      await _requireConcept(id);
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.sourceDao.updateConcept(
          id,
          ConceptsCompanion(
            title: Value(normalizedTitle),
            content: Value(normalizedContent),
            importance: Value(importance.name),
            updatedAt: Value(now),
          ),
        );
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.concept.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '개념을 수정하지 못했어요.');
  }

  @override
  Future<void> deleteConcept(String id) {
    return _guard(() async {
      await _requireConcept(id);
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.concept.name,
          entityId: id,
          operation: SyncOperation.delete.name,
          createdAt: now,
        );
        await _database.sourceDao.deleteConcept(id);
      });
    }, '개념을 삭제하지 못했어요.');
  }

  @override
  Future<ConceptRevisionApplyResult> applyConceptRevisions({
    required String sourceId,
    required List<ConceptRevision> revisions,
  }) {
    return _guard(() async {
      final source = await _database.sourceDao.getSource(sourceId);
      if (source == null) {
        throw const ValidationFailure('학습 자료를 찾을 수 없어요.');
      }
      final rows = await _database.sourceDao.getConcepts(sourceId);
      final rowsById = {for (final row in rows) row.id: row};
      final seen = <String>{};
      final normalized = <ConceptRevision>[];
      for (final revision in revisions) {
        final title = revision.title.trim();
        final content = revision.content.trim();
        final pages = revision.pageNumbers.toSet().toList()..sort();
        if (!seen.add(revision.id) ||
            !rowsById.containsKey(revision.id) ||
            title.isEmpty ||
            title.length > 200 ||
            content.isEmpty ||
            content.length > 8000 ||
            pages.isEmpty ||
            pages.any((page) => page < 1 || page > source.pageCount)) {
          throw const ValidationFailure('AI 개념 수정 결과가 올바르지 않아요.');
        }
        normalized.add(
          ConceptRevision(
            id: revision.id,
            title: title,
            content: content,
            pageNumbers: pages,
            importance: revision.importance,
          ),
        );
      }

      var changedCount = 0;
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        for (final revision in normalized) {
          final row = rowsById[revision.id]!;
          final currentPages =
              (jsonDecode(row.pageNumbersJson) as List)
                  .map((value) => (value as num).toInt())
                  .toSet()
                  .toList()
                ..sort();
          if (row.title == revision.title &&
              row.content == revision.content &&
              row.importance == revision.importance.name &&
              _samePages(currentPages, revision.pageNumbers)) {
            continue;
          }
          changedCount++;
          final updatedAt = now.add(Duration(microseconds: changedCount));
          await _database.sourceDao.updateConcept(
            revision.id,
            ConceptsCompanion(
              title: Value(revision.title),
              content: Value(revision.content),
              pageNumbersJson: Value(jsonEncode(revision.pageNumbers)),
              status: Value(ConceptStatus.held.name),
              importance: Value(revision.importance.name),
              updatedAt: Value(updatedAt),
            ),
          );
          await _database.syncDao.enqueue(
            entityType: SyncEntityType.concept.name,
            entityId: revision.id,
            operation: SyncOperation.upsert.name,
            createdAt: updatedAt,
          );
        }
      });

      final updatedRows = await _database.sourceDao.getConcepts(sourceId);
      return ConceptRevisionApplyResult(
        review: StudySourceWithConcepts(
          source: _sourceFromRow(source),
          concepts: _sortConcepts(updatedRows.map(_conceptFromRow)),
        ),
        changedCount: changedCount,
      );
    }, 'AI 개념 수정 결과를 저장하지 못했어요.');
  }

  @override
  Future<ConceptGenerationSeed> getConceptGenerationSeed(String conceptId) {
    return _guard(() async {
      final conceptRow = await _requireConcept(conceptId);
      if (ConceptStatus.fromStorage(conceptRow.status) !=
          ConceptStatus.approved) {
        throw const ValidationFailure('승인된 개념만 문제 생성에 사용할 수 있어요.');
      }
      final sourceRow = await _database.sourceDao.getSource(
        conceptRow.sourceId,
      );
      if (sourceRow == null) {
        throw const ValidationFailure('개념의 원본 자료를 찾을 수 없어요.');
      }
      return ConceptGenerationSeed(
        folderId: sourceRow.folderId,
        source: _sourceFromRow(sourceRow),
        concept: _conceptFromRow(conceptRow),
      );
    }, '개념 정보를 불러오지 못했어요.');
  }

  Future<void> _setStatus(String id, ConceptStatus status) {
    return _guard(() async {
      await _requireConcept(id);
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.sourceDao.updateConcept(
          id,
          ConceptsCompanion(status: Value(status.name), updatedAt: Value(now)),
        );
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.concept.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '개념 상태를 변경하지 못했어요.');
  }

  Future<ConceptRow> _requireConcept(String id) async {
    final concept = await _database.sourceDao.getConcept(id);
    if (concept == null) {
      throw const ValidationFailure('개념을 찾을 수 없어요.');
    }
    return concept;
  }

  StudySource _sourceFromRow(StudySourceRow row) => StudySource(
    id: row.id,
    folderId: row.folderId,
    fileName: row.fileName,
    contentHash: row.contentHash,
    pageCount: row.pageCount,
    extractionMethod: row.extractionMethod,
    importedAt: row.importedAt.toUtc(),
  );

  StudyConcept _conceptFromRow(ConceptRow row) => StudyConcept(
    id: row.id,
    sourceId: row.sourceId,
    title: row.title,
    content: row.content,
    pageNumbers: (jsonDecode(row.pageNumbersJson) as List)
        .map((value) => (value as num).toInt())
        .toList(growable: false),
    status: ConceptStatus.fromStorage(row.status),
    importance: ConceptImportance.fromStorage(row.importance),
    createdAt: row.createdAt.toUtc(),
    updatedAt: row.updatedAt.toUtc(),
  );

  List<StudyConcept> _sortConcepts(Iterable<StudyConcept> concepts) {
    final sorted = concepts.toList();
    sorted.sort((left, right) {
      final pageComparison = left.pageNumbers.first.compareTo(
        right.pageNumbers.first,
      );
      if (pageComparison != 0) return pageComparison;
      return left.title.compareTo(right.title);
    });
    return List.unmodifiable(sorted);
  }

  bool _samePages(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
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
