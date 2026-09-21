import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
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

  Stream<List<StudyConcept>> watchConcepts(String sourceId);

  Future<StudySourceWithConcepts> getSourceWithConcepts(String sourceId);

  Future<void> approveConcept(String id);

  Future<void> holdConcept(String id);

  Future<void> rejectConcept(String id);

  Future<void> updateAndApproveConcept({
    required String id,
    required String title,
    required String summary,
    required String details,
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
            summary: imported.summary.trim(),
            details: imported.details.trim(),
            pageNumbers: imported.pageNumbers.toSet().toList()..sort(),
            status: ConceptStatus.draft,
            createdAt: now,
            updatedAt: now,
          ),
      ];
      if (concepts.any(
        (concept) =>
            concept.title.isEmpty ||
            concept.summary.isEmpty ||
            concept.details.isEmpty ||
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
              summary: concept.summary,
              details: concept.details,
              pageNumbersJson: jsonEncode(concept.pageNumbers),
              status: concept.status.name,
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
        concepts: concepts,
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
        concepts: conceptRows.map(_conceptFromRow).toList(growable: false),
      );
    }, '학습 자료를 불러오지 못했어요.');
  }

  @override
  Future<void> approveConcept(String id) =>
      _setStatus(id, ConceptStatus.approved);

  @override
  Future<void> holdConcept(String id) => _setStatus(id, ConceptStatus.held);

  @override
  Future<void> rejectConcept(String id) =>
      _setStatus(id, ConceptStatus.rejected);

  @override
  Future<void> updateAndApproveConcept({
    required String id,
    required String title,
    required String summary,
    required String details,
  }) {
    return _guard(() async {
      final normalizedTitle = title.trim();
      final normalizedSummary = summary.trim();
      final normalizedDetails = details.trim();
      if (normalizedTitle.isEmpty ||
          normalizedSummary.isEmpty ||
          normalizedDetails.isEmpty) {
        throw const ValidationFailure('제목, 요약, 상세 내용을 모두 입력해 주세요.');
      }
      await _requireConcept(id);
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.sourceDao.updateConcept(
          id,
          ConceptsCompanion(
            title: Value(normalizedTitle),
            summary: Value(normalizedSummary),
            details: Value(normalizedDetails),
            status: Value(ConceptStatus.approved.name),
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
    summary: row.summary,
    details: row.details,
    pageNumbers: (jsonDecode(row.pageNumbersJson) as List)
        .map((value) => (value as num).toInt())
        .toList(growable: false),
    status: ConceptStatus.fromStorage(row.status),
    createdAt: row.createdAt.toUtc(),
    updatedAt: row.updatedAt.toUtc(),
  );

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
