import 'dart:convert';

import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:uuid/uuid.dart';

abstract interface class AttemptRepository {
  Future<String> recordAttempt(AttemptDraft draft);

  Future<List<Attempt>> getAttemptsForQuestion(String questionId);

  Future<List<Attempt>> getAttemptsForSession(String sessionId);

  Future<List<Attempt>> getRecentAttempts({int limit = 50});

  Future<List<Attempt>> getAllAttempts();

  Stream<List<Attempt>> watchAttempts();
}

class DriftAttemptRepository implements AttemptRepository {
  DriftAttemptRepository(this._database);

  final AppDatabase _database;
  final Uuid _uuid = const Uuid();

  @override
  Future<String> recordAttempt(AttemptDraft draft) {
    return _guard(() async {
      if (draft.durationMs < 0) {
        throw const ValidationFailure('풀이 시간은 0 이상이어야 해요.');
      }
      final id = _uuid.v4();
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.attemptDao.insertAttempt(
          AttemptsCompanion.insert(
            id: id,
            questionId: draft.questionId,
            sessionId: draft.sessionId,
            answeredAt: now,
            responseJson: jsonEncode(draft.response),
            questionSnapshotJson: jsonEncode(draft.questionSnapshot.toJson()),
            score: draft.score,
            maxScore: draft.maxScore,
            gradingType: draft.gradingType.name,
            durationMs: draft.durationMs,
            createdAt: now,
          ),
        );
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.attempt.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
      return id;
    }, '풀이 기록을 저장하지 못했어요.');
  }

  @override
  Future<List<Attempt>> getAttemptsForQuestion(String questionId) {
    return _guard(() async {
      final rows = await _database.attemptDao.getAttemptsForQuestion(
        questionId,
      );
      return rows.map(mapAttemptRow).toList(growable: false);
    }, '문제 풀이 기록을 불러오지 못했어요.');
  }

  @override
  Future<List<Attempt>> getAttemptsForSession(String sessionId) {
    return _guard(() async {
      final rows = await _database.attemptDao.getAttemptsForSession(sessionId);
      return rows.map(mapAttemptRow).toList(growable: false);
    }, '학습 세션의 풀이 기록을 불러오지 못했어요.');
  }

  @override
  Future<List<Attempt>> getRecentAttempts({int limit = 50}) {
    return _guard(() async {
      final rows = await _database.attemptDao.getRecentAttempts(limit);
      return rows.map(mapAttemptRow).toList(growable: false);
    }, '최근 풀이 기록을 불러오지 못했어요.');
  }

  @override
  Future<List<Attempt>> getAllAttempts() {
    return _guard(() async {
      final rows = await _database.attemptDao.getAllAttempts();
      return rows.map(mapAttemptRow).toList(growable: false);
    }, '풀이 기록을 불러오지 못했어요.');
  }

  @override
  Stream<List<Attempt>> watchAttempts() async* {
    try {
      await for (final rows in _database.attemptDao.watchAttempts()) {
        yield rows.map(mapAttemptRow).toList(growable: false);
      }
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure('풀이 기록을 불러오지 못했어요.', cause: error),
        stackTrace,
      );
    }
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

Attempt mapAttemptRow(AttemptRow row) {
  return Attempt(
    id: row.id,
    questionId: row.questionId,
    sessionId: row.sessionId,
    answeredAt: row.answeredAt.toUtc(),
    response: Map<String, Object?>.from(jsonDecode(row.responseJson) as Map),
    questionSnapshot: QuestionSnapshot.fromJson(
      Map<String, Object?>.from(jsonDecode(row.questionSnapshotJson) as Map),
    ),
    score: row.score,
    maxScore: row.maxScore,
    gradingType: GradingType.values.byName(row.gradingType),
    durationMs: row.durationMs,
    createdAt: row.createdAt.toUtc(),
  );
}
