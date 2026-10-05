import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/quiz_session.dart';
import 'package:uuid/uuid.dart';

abstract interface class QuizRepository {
  Future<String> createSession({
    required QuizFilter filter,
    required List<Question> questions,
  });

  Future<QuizSessionDetails?> getSession(String id);

  Future<QuizSessionDetails?> resumeSession(String id);

  Future<void> linkAttempt({
    required String sessionId,
    required String itemId,
    required String attemptId,
  });

  Future<void> finishSession(String id);
  Future<void> skipForReview({
    required String sessionId,
    required String itemId,
  });
  Future<void> saveEssayResponse({
    required String sessionId,
    required String itemId,
    required String answer,
    required int durationMs,
  });
}

class DriftQuizRepository implements QuizRepository {
  DriftQuizRepository(this._database);

  final AppDatabase _database;
  final Uuid _uuid = const Uuid();

  @override
  Future<String> createSession({
    required QuizFilter filter,
    required List<Question> questions,
  }) {
    return _guard(() async {
      if (questions.isEmpty) {
        throw const ValidationFailure('출제할 문제가 없어요.');
      }

      final sessionId = _uuid.v4();
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database.quizDao.insertSession(
          QuizSessionsCompanion.insert(
            id: sessionId,
            startedAt: now,
            sourceFolderId: Value(filter.rootFolderId),
            totalQuestions: questions.length,
            completedQuestions: 0,
            filterJson: jsonEncode(filter.toJson()),
            createdAt: now,
            updatedAt: now,
          ),
        );
        await _database.quizDao.insertItems([
          for (var index = 0; index < questions.length; index++)
            QuizSessionItemsCompanion.insert(
              id: _uuid.v4(),
              sessionId: sessionId,
              questionId: questions[index].id,
              position: index,
              questionSnapshotJson: jsonEncode(
                QuestionSnapshot.fromQuestion(questions[index]).toJson(),
              ),
            ),
        ]);
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.quizSession.name,
          entityId: sessionId,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });

      return sessionId;
    }, '학습 세션을 생성하지 못했어요.');
  }

  @override
  Future<QuizSessionDetails?> getSession(String id) {
    return _guard(() async {
      final session = await _database.quizDao.getActiveSession(id);
      if (session == null) return null;
      final items = await _database.quizDao.getSessionItems(id);
      return _mapDetails(session, items);
    }, '학습 세션을 불러오지 못했어요.');
  }

  @override
  Future<QuizSessionDetails?> resumeSession(String id) => getSession(id);

  @override
  Future<void> saveEssayResponse({
    required String sessionId,
    required String itemId,
    required String answer,
    required int durationMs,
  }) => _guard(
    () => _database.transaction(() async {
      final session = await _database.quizDao.getActiveSession(sessionId);
      final items = await _database.quizDao.getSessionItems(sessionId);
      final item = items.where((item) => item.id == itemId).firstOrNull;
      if (session == null ||
          session.finishedAt != null ||
          item == null ||
          item.skippedForReview ||
          item.attemptId != null ||
          item.pendingEssayResponseJson != null) {
        throw const ValidationFailure('이미 제출했거나 찾을 수 없는 서술형 문항이에요.');
      }
      if (answer.trim().isEmpty ||
          durationMs < 0 ||
          (jsonDecode(item.questionSnapshotJson) as Map)['type'] != 'essay') {
        throw const ValidationFailure('서술형 답안이 올바르지 않아요.');
      }
      await (_database.update(
        _database.quizSessionItems,
      )..where((row) => row.id.equals(itemId))).write(
        QuizSessionItemsCompanion(
          pendingEssayResponseJson: Value(
            jsonEncode({'textAnswer': answer, 'durationMs': durationMs}),
          ),
        ),
      );
      final now = DateTime.now().toUtc();
      await (_database.update(_database.quizSessions)
            ..where((row) => row.id.equals(sessionId)))
          .write(QuizSessionsCompanion(updatedAt: Value(now)));
      await _database.syncDao.enqueue(
        entityType: 'quizSession',
        entityId: sessionId,
        operation: 'upsert',
        createdAt: now,
      );
    }),
    '서술형 답안을 저장하지 못했어요.',
  );

  @override
  Future<void> linkAttempt({
    required String sessionId,
    required String itemId,
    required String attemptId,
  }) {
    return _guard(() async {
      await _database.transaction(() async {
        final session = await _database.quizDao.getActiveSession(sessionId);
        if (session == null) {
          throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
        }
        if (session.finishedAt != null) {
          throw const ValidationFailure('이미 종료된 학습 세션이에요.');
        }
        final items = await _database.quizDao.getSessionItems(sessionId);
        final item = items
            .where((candidate) => candidate.id == itemId)
            .firstOrNull;
        if (item == null) {
          throw const ValidationFailure('학습 문항을 찾을 수 없어요.');
        }
        if (item.attemptId != null || item.skippedForReview) {
          throw const ValidationFailure('이미 답안을 제출한 문제예요.');
        }

        await _database.quizDao.linkAttempt(
          itemId: itemId,
          attemptId: attemptId,
        );
        final completedQuestions =
            items.where((candidate) => candidate.attemptId != null).length + 1;
        final now = DateTime.now().toUtc();
        await _database.quizDao.updateProgress(
          sessionId: sessionId,
          completedQuestions: completedQuestions,
          updatedAt: now,
        );
        if (completedQuestions +
                items.where((item) => item.skippedForReview).length >=
            session.totalQuestions) {
          await _database.quizDao.finishSession(
            sessionId: sessionId,
            finishedAt: now,
          );
        }
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.quizSession.name,
          entityId: sessionId,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '학습 진행 상태를 저장하지 못했어요.');
  }

  @override
  Future<void> skipForReview({
    required String sessionId,
    required String itemId,
  }) => _guard(
    () => _database.transaction(() async {
      final session = await _database.quizDao.getActiveSession(sessionId);
      final items = await _database.quizDao.getSessionItems(sessionId);
      final item = items.where((item) => item.id == itemId).firstOrNull;
      if (session == null ||
          session.finishedAt != null ||
          item == null ||
          item.attemptId != null ||
          item.skippedForReview) {
        throw const ValidationFailure('이미 처리했거나 찾을 수 없는 학습 문항이에요.');
      }
      final question = await _database.questionDao.getActiveQuestion(
        item.questionId,
      );
      if (question == null || question.status == QuestionStatus.archived.name) {
        throw const ValidationFailure('삭제되거나 보관된 문제는 재검토 요청할 수 없어요.');
      }
      final now = DateTime.now().toUtc();
      await (_database.update(
        _database.quizSessionItems,
      )..where((row) => row.id.equals(itemId))).write(
        const QuizSessionItemsCompanion(
          skippedForReview: Value(true),
          pendingEssayResponseJson: Value(null),
        ),
      );
      // Reuse the existing unapproved state; do not introduce another status.
      await _database.questionDao.updateQuestion(
        item.questionId,
        QuestionsCompanion(
          status: Value(QuestionStatus.draft.name),
          updatedAt: Value(now),
        ),
      );
      final graded = items.where((item) => item.attemptId != null).length;
      await _database.quizDao.updateProgress(
        sessionId: sessionId,
        completedQuestions: graded,
        updatedAt: now,
      );
      if (graded + items.where((item) => item.skippedForReview).length + 1 >=
          session.totalQuestions) {
        await _database.quizDao.finishSession(
          sessionId: sessionId,
          finishedAt: now,
        );
      }
      for (final entry in [
        (SyncEntityType.question, item.questionId),
        (SyncEntityType.quizSession, sessionId),
      ]) {
        await _database.syncDao.enqueue(
          entityType: entry.$1.name,
          entityId: entry.$2,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      }
    }),
    '문제 재검토 요청을 저장하지 못했어요.',
  );

  @override
  Future<void> finishSession(String id) {
    return _guard(() async {
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        final session = await _database.quizDao.getActiveSession(id);
        if (session == null) {
          throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
        }
        if (session.finishedAt != null) return;
        await _database.quizDao.finishSession(sessionId: id, finishedAt: now);
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.quizSession.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '학습 세션을 완료하지 못했어요.');
  }

  QuizSessionDetails _mapDetails(
    QuizSessionRow session,
    List<QuizSessionItemRow> items,
  ) {
    return QuizSessionDetails(
      session: QuizSession(
        id: session.id,
        startedAt: session.startedAt.toUtc(),
        finishedAt: session.finishedAt?.toUtc(),
        sourceFolderId: session.sourceFolderId,
        totalQuestions: session.totalQuestions,
        completedQuestions: session.completedQuestions,
        filter: QuizFilter.fromJson(
          Map<String, Object?>.from(jsonDecode(session.filterJson) as Map),
        ),
        createdAt: session.createdAt.toUtc(),
        updatedAt: session.updatedAt.toUtc(),
        deletedAt: session.deletedAt?.toUtc(),
      ),
      items: [
        for (final item in items)
          QuizSessionItem(
            id: item.id,
            sessionId: item.sessionId,
            questionId: item.questionId,
            position: item.position,
            questionSnapshot: QuestionSnapshot.fromJson(
              Map<String, Object?>.from(
                jsonDecode(item.questionSnapshotJson) as Map,
              ),
            ),
            attemptId: item.attemptId,
            skippedForReview: item.skippedForReview,
            pendingEssayResponse: item.pendingEssayResponseJson == null
                ? null
                : Map<String, Object?>.from(
                    jsonDecode(item.pendingEssayResponseJson!) as Map,
                  ),
          ),
      ],
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
