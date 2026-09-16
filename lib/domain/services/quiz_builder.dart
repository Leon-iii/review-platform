import 'dart:math';

import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';

class QuizBuildResult {
  const QuizBuildResult({required this.sessionId, required this.questionCount});

  final String sessionId;
  final int questionCount;
}

class QuizBuilder {
  QuizBuilder(
    this._folderRepository,
    this._questionRepository,
    this._quizRepository,
    this._attemptRepository, {
    Random? random,
  }) : _random = random ?? Random();

  final FolderRepository _folderRepository;
  final QuestionRepository _questionRepository;
  final QuizRepository _quizRepository;
  final AttemptRepository _attemptRepository;
  final Random _random;

  Future<QuizBuildResult> build(QuizFilter filter) async {
    if (filter.questionCount <= 0) {
      throw const ValidationFailure('문제 수는 1개 이상이어야 해요.');
    }
    if (filter.enabledQuestionTypes.isEmpty) {
      throw const ValidationFailure('문제 유형을 하나 이상 선택해 주세요.');
    }
    if (filter.maxCorrectRate case final rate?) {
      if (rate < 0 || rate > 1) {
        throw const ValidationFailure('정답률 기준은 0에서 1 사이여야 해요.');
      }
    }

    final folderIds = <String>{
      filter.rootFolderId,
      ...await _folderRepository.getDescendantIds(filter.rootFolderId),
    };
    for (final excludedId in filter.excludedFolderIds) {
      folderIds.remove(excludedId);
      folderIds.removeAll(await _folderRepository.getDescendantIds(excludedId));
    }

    final eligible = [
      ...await _questionRepository.getEligibleQuestions(
        folderIds: folderIds.toList(growable: false),
        types: filter.enabledQuestionTypes,
      ),
    ];
    if (filter.onlyWrongQuestions || filter.maxCorrectRate != null) {
      final attempts = await _attemptRepository.getAllAttempts();
      final attemptsByQuestion = <String, List<Attempt>>{};
      for (final attempt in attempts) {
        attemptsByQuestion
            .putIfAbsent(attempt.questionId, () => [])
            .add(attempt);
      }
      eligible.removeWhere((question) {
        final questionAttempts = attemptsByQuestion[question.id] ?? const [];
        if (filter.onlyWrongQuestions &&
            (questionAttempts.isEmpty ||
                questionAttempts.first.score >=
                    questionAttempts.first.maxScore)) {
          return true;
        }
        if (filter.maxCorrectRate case final maxRate?) {
          final maxScore = questionAttempts.fold<double>(
            0,
            (sum, attempt) => sum + attempt.maxScore,
          );
          final score = questionAttempts.fold<double>(
            0,
            (sum, attempt) => sum + attempt.score,
          );
          final correctRate = maxScore == 0 ? 0 : score / maxScore;
          return correctRate > maxRate;
        }
        return false;
      });
    }
    if (eligible.isEmpty) {
      throw const ValidationFailure('선택한 조건에 맞는 문제가 없어요.');
    }
    if (filter.shuffle) eligible.shuffle(_random);
    final selected = eligible
        .take(filter.questionCount)
        .toList(growable: false);
    final sessionId = await _quizRepository.createSession(
      filter: filter,
      questions: selected,
    );
    return QuizBuildResult(
      sessionId: sessionId,
      questionCount: selected.length,
    );
  }
}
