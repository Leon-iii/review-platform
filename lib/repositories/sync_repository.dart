import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/sync_status.dart';

abstract interface class SyncRepository {
  Stream<SyncStatus> watchStatus();

  Future<List<SyncOutboxEntry>> getPending({int limit = 100});

  Future<void> markFailed({required String id, required String error});

  Future<void> removeAcknowledged(Iterable<String> ids);

  Future<List<PushSyncChange>> buildPushBatch({int limit = 100});

  Future<SyncStatus> getStatus();

  Future<void> applyPulledChanges(List<PullSyncChange> changes);

  Future<void> recordSuccess({required int revision, required DateTime at});

  Future<void> recordFailure(String error);
}

class DriftSyncRepository implements SyncRepository {
  DriftSyncRepository(this._database);

  final AppDatabase _database;

  @override
  Stream<SyncStatus> watchStatus() async* {
    try {
      await for (final value in _database.syncDao.watchStatus()) {
        yield SyncStatus(
          pendingCount: value.pendingCount,
          lastPulledRevision: value.state.lastPulledRevision,
          lastSyncedAt: value.state.lastSyncedAt?.toUtc(),
          lastError: value.state.lastError,
        );
      }
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure('동기화 상태를 불러오지 못했어요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<List<SyncOutboxEntry>> getPending({int limit = 100}) {
    return _guard(() async {
      final rows = await _database.syncDao.getPending(limit: limit);
      return [
        for (final row in rows)
          SyncOutboxEntry(
            id: row.id,
            entityType: SyncEntityType.fromStorage(row.entityType),
            entityId: row.entityId,
            operation: SyncOperation.fromStorage(row.operation),
            createdAt: row.createdAt.toUtc(),
            retryCount: row.retryCount,
            lastError: row.lastError,
          ),
      ];
    }, '동기화 대기 목록을 불러오지 못했어요.');
  }

  @override
  Future<void> markFailed({required String id, required String error}) {
    return _guard(
      () => _database.syncDao.markFailed(id: id, error: error),
      '동기화 실패 상태를 저장하지 못했어요.',
    );
  }

  @override
  Future<void> removeAcknowledged(Iterable<String> ids) {
    return _guard(
      () => _database.syncDao.removeAcknowledged(ids),
      '완료된 동기화 항목을 정리하지 못했어요.',
    );
  }

  @override
  Future<List<PushSyncChange>> buildPushBatch({int limit = 100}) {
    return _guard(() async {
      final entries = await getPending(limit: limit);
      return Future.wait(entries.map(_buildPushChange));
    }, '동기화할 로컬 데이터를 준비하지 못했어요.');
  }

  @override
  Future<SyncStatus> getStatus() {
    return _guard(() async {
      final state = await _database.syncDao.getState();
      return SyncStatus(
        pendingCount: await _database.syncDao.getPendingCount(),
        lastPulledRevision: state.lastPulledRevision,
        lastSyncedAt: state.lastSyncedAt?.toUtc(),
        lastError: state.lastError,
      );
    }, '동기화 상태를 불러오지 못했어요.');
  }

  @override
  Future<void> applyPulledChanges(List<PullSyncChange> changes) {
    return _guard(() async {
      await _database.transaction(() async {
        for (final change in changes) {
          await _applyChange(change);
        }
      });
    }, '서버 변경사항을 로컬 데이터에 반영하지 못했어요.');
  }

  @override
  Future<void> recordSuccess({required int revision, required DateTime at}) {
    return _guard(
      () => _database.syncDao.updateState(
        lastPulledRevision: revision,
        lastSyncedAt: at.toUtc(),
      ),
      '동기화 완료 상태를 저장하지 못했어요.',
    );
  }

  @override
  Future<void> recordFailure(String error) {
    return _guard(
      () => _database.syncDao.setLastError(error),
      '동기화 오류 상태를 저장하지 못했어요.',
    );
  }

  Future<PushSyncChange> _buildPushChange(SyncOutboxEntry entry) async {
    final deleteRequested = entry.operation == SyncOperation.delete;
    switch (entry.entityType) {
      case SyncEntityType.folder:
        final row = await _database.folderDao.getFolder(entry.entityId);
        final deletedAt = row?.deletedAt?.toUtc();
        final isDelete = deleteRequested || deletedAt != null;
        return PushSyncChange(
          operationId: entry.id,
          entityType: entry.entityType.name,
          entityId: entry.entityId,
          operation: isDelete ? 'delete' : 'upsert',
          updatedAt: row?.updatedAt.toUtc() ?? entry.createdAt,
          deletedAt: isDelete ? deletedAt ?? entry.createdAt : null,
          payload: isDelete
              ? null
              : {
                  'id': row!.id,
                  'parentId': row.parentId,
                  'name': row.name,
                  'createdAt': row.createdAt.toUtc().toIso8601String(),
                  'updatedAt': row.updatedAt.toUtc().toIso8601String(),
                  'deletedAt': null,
                },
        );
      case SyncEntityType.question:
        final row = await _database.questionDao.getQuestion(entry.entityId);
        final deletedAt = row?.deletedAt?.toUtc();
        final isDelete = deleteRequested || deletedAt != null;
        final choices = isDelete
            ? const <QuestionChoiceRow>[]
            : await _database.questionDao.getChoices(entry.entityId);
        final answers = isDelete
            ? const <AcceptableAnswerRow>[]
            : await _database.questionDao.getAcceptableAnswers(entry.entityId);
        return PushSyncChange(
          operationId: entry.id,
          entityType: entry.entityType.name,
          entityId: entry.entityId,
          operation: isDelete ? 'delete' : 'upsert',
          updatedAt: row?.updatedAt.toUtc() ?? entry.createdAt,
          deletedAt: isDelete ? deletedAt ?? entry.createdAt : null,
          payload: isDelete
              ? null
              : {
                  'id': row!.id,
                  'folderId': row.folderId,
                  'type': row.type,
                  'status': row.status,
                  'prompt': row.prompt,
                  'explanation': row.explanation,
                  'difficulty': row.difficulty,
                  'createdAt': row.createdAt.toUtc().toIso8601String(),
                  'updatedAt': row.updatedAt.toUtc().toIso8601String(),
                  'deletedAt': null,
                  'choices': [
                    for (final choice in choices)
                      {
                        'id': choice.id,
                        'position': choice.position,
                        'text': choice.choiceText,
                        'isCorrect': choice.isCorrect,
                      },
                  ],
                  'acceptableAnswers': [
                    for (final answer in answers)
                      {'id': answer.id, 'text': answer.answerText},
                  ],
                },
        );
      case SyncEntityType.quizSession:
        final row = await _database.quizDao.getSession(entry.entityId);
        final deletedAt = row?.deletedAt?.toUtc();
        final isDelete = deleteRequested || deletedAt != null;
        final items = isDelete
            ? const <QuizSessionItemRow>[]
            : await _database.quizDao.getSessionItems(entry.entityId);
        return PushSyncChange(
          operationId: entry.id,
          entityType: entry.entityType.name,
          entityId: entry.entityId,
          operation: isDelete ? 'delete' : 'upsert',
          updatedAt: row?.updatedAt.toUtc() ?? entry.createdAt,
          deletedAt: isDelete ? deletedAt ?? entry.createdAt : null,
          payload: isDelete
              ? null
              : {
                  'id': row!.id,
                  'startedAt': row.startedAt.toUtc().toIso8601String(),
                  'finishedAt': row.finishedAt?.toUtc().toIso8601String(),
                  'sourceFolderId': row.sourceFolderId,
                  'totalQuestions': row.totalQuestions,
                  'completedQuestions': row.completedQuestions,
                  'filter': jsonDecode(row.filterJson),
                  'createdAt': row.createdAt.toUtc().toIso8601String(),
                  'updatedAt': row.updatedAt.toUtc().toIso8601String(),
                  'deletedAt': null,
                  'items': [
                    for (final item in items)
                      {
                        'id': item.id,
                        'questionId': item.questionId,
                        'position': item.position,
                        'questionSnapshot': jsonDecode(
                          item.questionSnapshotJson,
                        ),
                        'attemptId': item.attemptId,
                      },
                  ],
                },
        );
      case SyncEntityType.attempt:
        final row = await _database.attemptDao.getAttempt(entry.entityId);
        if (row == null) {
          throw const SyncFailure('동기화할 풀이 기록을 찾을 수 없어요.');
        }
        return PushSyncChange(
          operationId: entry.id,
          entityType: entry.entityType.name,
          entityId: entry.entityId,
          operation: 'upsert',
          updatedAt: row.createdAt.toUtc(),
          payload: {
            'id': row.id,
            'questionId': row.questionId,
            'sessionId': row.sessionId,
            'answeredAt': row.answeredAt.toUtc().toIso8601String(),
            'response': jsonDecode(row.responseJson),
            'questionSnapshot': jsonDecode(row.questionSnapshotJson),
            'score': row.score,
            'maxScore': row.maxScore,
            'gradingType': row.gradingType,
            'durationMs': row.durationMs,
            'createdAt': row.createdAt.toUtc().toIso8601String(),
          },
        );
    }
  }

  Future<void> _applyChange(PullSyncChange change) async {
    final entityType = SyncEntityType.fromStorage(change.entityType);
    final isDelete = change.operation == 'delete';
    switch (entityType) {
      case SyncEntityType.folder:
        final existing = await _database.folderDao.getFolder(change.entityId);
        if (existing != null &&
            existing.updatedAt.toUtc().isAfter(change.updatedAt)) {
          return;
        }
        if (isDelete) {
          if (existing != null) {
            await _database.folderDao.softDeleteFolders(
              ids: [change.entityId],
              deletedAt: change.deletedAt ?? change.updatedAt,
            );
          }
          return;
        }
        final payload = _requirePayload(change);
        await _database.folderDao.upsertFolder(
          FoldersCompanion.insert(
            id: change.entityId,
            parentId: Value(payload['parentId'] as String?),
            name: payload['name']! as String,
            createdAt: _date(payload, 'createdAt'),
            updatedAt: change.updatedAt,
            deletedAt: const Value(null),
          ),
        );
      case SyncEntityType.question:
        final existing = await _database.questionDao.getQuestion(
          change.entityId,
        );
        if (existing != null &&
            existing.updatedAt.toUtc().isAfter(change.updatedAt)) {
          return;
        }
        if (isDelete) {
          if (existing != null) {
            await _database.questionDao.softDeleteQuestion(
              change.entityId,
              change.deletedAt ?? change.updatedAt,
            );
          }
          return;
        }
        final payload = _requirePayload(change);
        await _database.questionDao.upsertQuestion(
          QuestionsCompanion.insert(
            id: change.entityId,
            folderId: payload['folderId']! as String,
            type: payload['type']! as String,
            status: payload['status']! as String,
            prompt: payload['prompt']! as String,
            explanation: Value(payload['explanation'] as String?),
            difficulty: Value((payload['difficulty'] as num?)?.toInt()),
            createdAt: _date(payload, 'createdAt'),
            updatedAt: change.updatedAt,
            deletedAt: const Value(null),
          ),
        );
        await _database.questionDao.replaceChoices(change.entityId, [
          for (final raw in payload['choices']! as List)
            QuestionChoicesCompanion.insert(
              id: (raw as Map)['id']! as String,
              questionId: change.entityId,
              position: (raw['position']! as num).toInt(),
              choiceText: raw['text']! as String,
              isCorrect: raw['isCorrect']! as bool,
            ),
        ]);
        await _database.questionDao.replaceAcceptableAnswers(change.entityId, [
          for (final raw in payload['acceptableAnswers']! as List)
            AcceptableAnswersCompanion.insert(
              id: (raw as Map)['id']! as String,
              questionId: change.entityId,
              answerText: raw['text']! as String,
            ),
        ]);
      case SyncEntityType.quizSession:
        final existing = await _database.quizDao.getSession(change.entityId);
        if (existing != null &&
            existing.updatedAt.toUtc().isAfter(change.updatedAt)) {
          return;
        }
        if (isDelete) {
          if (existing != null) {
            await _database.quizDao.softDeleteSession(
              sessionId: change.entityId,
              deletedAt: change.deletedAt ?? change.updatedAt,
            );
          }
          return;
        }
        final payload = _requirePayload(change);
        await _database.quizDao.upsertSession(
          QuizSessionsCompanion.insert(
            id: change.entityId,
            startedAt: _date(payload, 'startedAt'),
            finishedAt: Value(_nullableDate(payload['finishedAt'])),
            sourceFolderId: Value(payload['sourceFolderId'] as String?),
            totalQuestions: (payload['totalQuestions']! as num).toInt(),
            completedQuestions: (payload['completedQuestions']! as num).toInt(),
            filterJson: jsonEncode(payload['filter']),
            createdAt: _date(payload, 'createdAt'),
            updatedAt: change.updatedAt,
            deletedAt: const Value(null),
          ),
        );
        await _database.quizDao.replaceSessionItems(change.entityId, [
          for (final raw in payload['items']! as List)
            QuizSessionItemsCompanion.insert(
              id: (raw as Map)['id']! as String,
              sessionId: change.entityId,
              questionId: raw['questionId']! as String,
              position: (raw['position']! as num).toInt(),
              questionSnapshotJson: jsonEncode(raw['questionSnapshot']),
              attemptId: Value(raw['attemptId'] as String?),
            ),
        ]);
      case SyncEntityType.attempt:
        if (isDelete ||
            await _database.attemptDao.getAttempt(change.entityId) != null) {
          return;
        }
        final payload = _requirePayload(change);
        await _database.attemptDao.insertAttemptIfMissing(
          AttemptsCompanion.insert(
            id: change.entityId,
            questionId: payload['questionId']! as String,
            sessionId: payload['sessionId']! as String,
            answeredAt: _date(payload, 'answeredAt'),
            responseJson: jsonEncode(payload['response']),
            questionSnapshotJson: jsonEncode(payload['questionSnapshot']),
            score: (payload['score']! as num).toDouble(),
            maxScore: (payload['maxScore']! as num).toDouble(),
            gradingType: payload['gradingType']! as String,
            durationMs: (payload['durationMs']! as num).toInt(),
            createdAt: _date(payload, 'createdAt'),
          ),
        );
    }
  }

  Map<String, Object?> _requirePayload(PullSyncChange change) {
    final payload = change.payload;
    if (payload == null) {
      throw const SyncFailure('서버 동기화 데이터가 비어 있어요.');
    }
    return payload;
  }

  DateTime _date(Map<String, Object?> payload, String key) {
    return DateTime.parse(payload[key]! as String).toUtc();
  }

  DateTime? _nullableDate(Object? value) {
    return value == null ? null : DateTime.parse(value as String).toUtc();
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
