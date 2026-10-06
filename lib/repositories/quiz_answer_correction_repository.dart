import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/services/answer_grader.dart';
import 'package:uuid/uuid.dart';

/// Versioned regrading metadata. Original responses and timestamps stay intact.
const gradingCorrectionUpdatedAtKey = 'gradingCorrectionUpdatedAt';

DateTime attemptUpdatedAt(AttemptRow row) {
  final response = jsonDecode(row.responseJson) as Map;
  return DateTime.tryParse(
        response[gradingCorrectionUpdatedAtKey] as String? ?? '',
      )?.toUtc() ??
      row.createdAt.toUtc();
}

/// Sync allows only adding/removing this submitted answer, not other answers.
bool isValidAttemptCorrection(
  AttemptRow original,
  Map<String, Object?> payload,
) {
  final response = Map<String, Object?>.from(payload['response'] as Map)
    ..remove(gradingCorrectionUpdatedAtKey);
  final originalResponse = Map<String, Object?>.from(
    jsonDecode(original.responseJson) as Map,
  )..remove(gradingCorrectionUpdatedAtKey);
  final submitted = (originalResponse['textAnswer'] as String?)?.trim();
  final incoming = QuestionSnapshot.fromJson(
    Map<String, Object?>.from(payload['questionSnapshot'] as Map),
  );
  final before = QuestionSnapshot.fromJson(
    Map<String, Object?>.from(jsonDecode(original.questionSnapshotJson) as Map),
  );
  final score = (payload['score'] as num).toDouble();
  String orderedResponse(Map<String, Object?> value) => jsonEncode({
    for (final key in value.keys.toList()..sort()) key: value[key],
  });
  if (incoming.type != QuestionType.shortAnswer ||
      before.type != QuestionType.shortAnswer ||
      originalResponse['isUnknown'] == true ||
      submitted == null ||
      submitted.isEmpty ||
      original.maxScore <= 0 ||
      (score != 0 && score != original.maxScore) ||
      payload['questionId'] != original.questionId ||
      payload['sessionId'] != original.sessionId ||
      payload['maxScore'] != original.maxScore ||
      orderedResponse(response) != orderedResponse(originalResponse)) {
    return false;
  }
  final oldAnswers = before.acceptableAnswers;
  final newAnswers = incoming.acceptableAnswers;
  final unchanged = jsonEncode(oldAnswers) == jsonEncode(newAnswers);
  final appended =
      jsonEncode([...oldAnswers, submitted]) == jsonEncode(newAnswers);
  final removed =
      jsonEncode([...newAnswers, submitted]) == jsonEncode(oldAnswers);
  if (!unchanged && !appended && !removed) return false;
  if (score == original.maxScore &&
      !AnswerGrader.gradeShortAnswer(incoming, submitted).isCorrect) {
    return false;
  }
  return jsonEncode(incoming.toJson()..remove('acceptableAnswers')) ==
      jsonEncode(before.toJson()..remove('acceptableAnswers'));
}

class QuizAnswerCorrection {
  QuizAnswerCorrection._({
    required this.before,
    required this.after,
    required this.addedAnswerId,
    required this.questionFingerprint,
  });

  final AttemptRow before;
  final AttemptRow after;
  final String? addedAnswerId;
  bool get changedQuestion => addedAnswerId != null;
  final String questionFingerprint;
}

/// A single transaction updates accepted answers, score and sync outbox.
class QuizAnswerCorrectionRepository {
  QuizAnswerCorrectionRepository(this._database);
  final AppDatabase _database;

  Future<QuizAnswerCorrection> acceptSubmittedAnswer(String attemptId) =>
      _guard(
        () => _database.transaction(() async {
          final attempt = await _database.attemptDao.getAttempt(attemptId);
          if (attempt == null) {
            throw const ValidationFailure('풀이 기록을 찾을 수 없어요.');
          }
          final response = jsonDecode(attempt.responseJson) as Map;
          final snapshot = QuestionSnapshot.fromJson(
            Map<String, Object?>.from(
              jsonDecode(attempt.questionSnapshotJson) as Map,
            ),
          );
          final submitted = (response['textAnswer'] as String?)?.trim();
          final session = await _database.quizDao.getActiveSession(
            attempt.sessionId,
          );
          if (snapshot.type != QuestionType.shortAnswer ||
              response['isUnknown'] == true ||
              submitted == null ||
              submitted.isEmpty ||
              attempt.score >= attempt.maxScore ||
              attempt.maxScore <= 0 ||
              session?.finishedAt == null) {
            throw const ValidationFailure('종료된 퀴즈의 단답형 오답만 정답으로 등록할 수 있어요.');
          }
          final question = await _database.questionDao.getActiveQuestion(
            attempt.questionId,
          );
          // Never apply an old result to a deleted/replaced question or changed grading rules.
          if (question == null ||
              question.type != QuestionType.shortAnswer.name ||
              question.prompt != snapshot.prompt ||
              question.caseSensitive != snapshot.caseSensitive ||
              question.whitespaceSensitive != snapshot.whitespaceSensitive) {
            throw const ValidationFailure(
              '문제가 삭제되거나 수정되었어요. 현재 문제의 정답을 직접 확인해 주세요.',
            );
          }
          final answers = await _database.questionDao.getAcceptableAnswers(
            attempt.questionId,
          );
          String normalize(String value) => AnswerGrader.normalize(
            value,
            caseSensitive: question.caseSensitive,
            whitespaceSensitive: question.whitespaceSensitive,
          );
          final alreadyAccepted = answers.any(
            (answer) => normalize(answer.answerText) == normalize(submitted),
          );
          final now = _nextVersion(
            attempt,
            questionUpdatedAt: question.updatedAt,
          );
          String? addedAnswerId;
          if (!alreadyAccepted) {
            addedAnswerId = const Uuid().v4();
            await _database
                .into(_database.acceptableAnswers)
                .insert(
                  AcceptableAnswersCompanion.insert(
                    id: addedAnswerId,
                    questionId: attempt.questionId,
                    answerText: submitted,
                  ),
                );
            await _database.questionDao.updateQuestion(
              attempt.questionId,
              QuestionsCompanion(updatedAt: Value(now)),
            );
          }
          final updatedSnapshot = Map<String, Object?>.from(
            jsonDecode(attempt.questionSnapshotJson) as Map,
          );
          if (!AnswerGrader.gradeShortAnswer(snapshot, submitted).isCorrect) {
            updatedSnapshot['acceptableAnswers'] = [
              ...snapshot.acceptableAnswers,
              submitted,
            ];
          }
          await (_database.update(
            _database.attempts,
          )..where((row) => row.id.equals(attemptId))).write(
            AttemptsCompanion(
              score: Value(attempt.maxScore),
              questionSnapshotJson: Value(jsonEncode(updatedSnapshot)),
              responseJson: Value(
                jsonEncode({
                  ...response,
                  gradingCorrectionUpdatedAtKey: now.toIso8601String(),
                }),
              ),
            ),
          );
          await _enqueue(attempt, now, changedQuestion: addedAnswerId != null);
          return QuizAnswerCorrection._(
            before: attempt,
            after: (await _database.attemptDao.getAttempt(attemptId))!,
            addedAnswerId: addedAnswerId,
            questionFingerprint: await _questionFingerprint(attempt.questionId),
          );
        }),
        '제출한 답안을 정답으로 등록하지 못했어요.',
      );

  Future<void> undo(QuizAnswerCorrection correction) => _guard(
    () => _database.transaction(() async {
      final before = correction.before;
      final current = await _database.attemptDao.getAttempt(before.id);
      if (current == null ||
          current.score != correction.after.score ||
          current.questionSnapshotJson !=
              correction.after.questionSnapshotJson ||
          current.responseJson != correction.after.responseJson ||
          await _questionFingerprint(before.questionId) !=
              correction.questionFingerprint) {
        throw const ValidationFailure('그 후 문제나 풀이 기록이 변경되어 실행취소할 수 없어요.');
      }
      final question = (await _database.questionDao.getQuestion(
        before.questionId,
      ))!;
      final now = _nextVersion(current, questionUpdatedAt: question.updatedAt);
      if (correction.addedAnswerId case final answerId?) {
        await (_database.delete(_database.acceptableAnswers)..where(
              (row) =>
                  row.id.equals(answerId) &
                  row.questionId.equals(before.questionId),
            ))
            .go();
        await _database.questionDao.updateQuestion(
          before.questionId,
          QuestionsCompanion(updatedAt: Value(now)),
        );
      }
      await (_database.update(
        _database.attempts,
      )..where((row) => row.id.equals(before.id))).write(
        AttemptsCompanion(
          score: Value(before.score),
          questionSnapshotJson: Value(before.questionSnapshotJson),
          responseJson: Value(
            jsonEncode({
              ...jsonDecode(before.responseJson) as Map,
              gradingCorrectionUpdatedAtKey: now.toIso8601String(),
            }),
          ),
        ),
      );
      await _enqueue(before, now, changedQuestion: correction.changedQuestion);
    }),
    '정답 등록을 실행취소하지 못했어요.',
  );

  DateTime _nextVersion(
    AttemptRow attempt, {
    required DateTime questionUpdatedAt,
  }) {
    var now = DateTime.now().toUtc();
    // Drift stores question timestamps to the second. Register/undo within one
    // second must still have distinct LWW versions on another device.
    final nextQuestionVersion = questionUpdatedAt.toUtc().add(
      const Duration(seconds: 1),
    );
    if (now.isBefore(nextQuestionVersion)) now = nextQuestionVersion;
    final previous = attemptUpdatedAt(attempt);
    return now.isAfter(previous)
        ? now
        : previous.add(const Duration(microseconds: 1));
  }

  Future<String> _questionFingerprint(String id) async => jsonEncode([
    (await _database.questionDao.getQuestion(id))?.toJson(),
    [
      for (final answer in await _database.questionDao.getAcceptableAnswers(id))
        answer.toJson(),
    ],
    [
      for (final choice in await _database.questionDao.getChoices(id))
        choice.toJson(),
    ],
  ]);

  Future<void> _enqueue(
    AttemptRow attempt,
    DateTime now, {
    required bool changedQuestion,
  }) async {
    for (final entry in [
      ('attempt', attempt.id),
      if (changedQuestion) ('question', attempt.questionId),
    ]) {
      await _database.syncDao.enqueue(
        entityType: entry.$1,
        entityId: entry.$2,
        operation: 'upsert',
        createdAt: now,
      );
    }
  }

  Future<T> _guard<T>(Future<T> Function() action, String message) async {
    try {
      return await action();
    } on AppFailure {
      rethrow;
    } catch (error, stack) {
      Error.throwWithStackTrace(DatabaseFailure(message, cause: error), stack);
    }
  }
}
