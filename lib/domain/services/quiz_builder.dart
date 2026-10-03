import 'dart:math';

import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/question.dart';
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
    if (filter.enabledDifficulties.isEmpty) {
      throw const ValidationFailure('난이도를 하나 이상 선택해 주세요.');
    }
    if (filter.enabledDifficulties.any((level) => level < 1 || level > 5)) {
      throw const ValidationFailure('난이도는 1부터 5 사이여야 해요.');
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
    eligible.removeWhere(
      (question) => !filter.enabledDifficulties.contains(question.difficulty),
    );
    final attemptsByQuestion = <String, List<Attempt>>{};
    if (filter.onlyWrongQuestions ||
        filter.maxCorrectRate != null ||
        filter.prioritizeImportantConcepts) {
      final attempts = await _attemptRepository.getAllAttempts();
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
    final selected = filter.prioritizeImportantConcepts
        ? _selectByConcept(eligible, filter.questionCount, attemptsByQuestion)
        : (filter.shuffle ? (eligible..shuffle(_random)) : eligible)
              .take(filter.questionCount)
              .toList(growable: false);
    if (filter.prioritizeImportantConcepts) {
      if (filter.shuffle) {
        selected.shuffle(_random);
      } else {
        final positions = {
          for (var i = 0; i < eligible.length; i++) eligible[i].id: i,
        };
        selected.sort((a, b) => positions[a.id]!.compareTo(positions[b.id]!));
      }
    }
    final sessionId = await _quizRepository.createSession(
      filter: filter,
      questions: selected,
    );
    return QuizBuildResult(
      sessionId: sessionId,
      questionCount: selected.length,
    );
  }

  List<Question> _selectByConcept(
    List<Question> eligible,
    int count,
    Map<String, List<Attempt>> attempts,
  ) {
    final groups = <String, List<Question>>{};
    for (final question in eligible) {
      final key = question.primaryConceptId == null
          ? 'question:${question.id}'
          : 'concept:${question.primaryConceptId}';
      groups.putIfAbsent(key, () => []).add(question);
    }
    double weakness(Question question) {
      final latest = attempts[question.id]?.firstOrNull;
      if (latest == null || latest.score >= latest.maxScore) return 1;
      return latest.isUnknown ? 1.75 : 1.5;
    }

    final selected = <Question>[];
    while (groups.isNotEmpty && selected.length < count) {
      final entries = groups.entries.toList();
      // Each concept has one weight, regardless of how many questions it owns.
      final weights = entries
          .map(
            (entry) =>
                entry.value.first.importance.weight *
                entry.value.map(weakness).reduce((a, b) => a + b) /
                entry.value.length,
          )
          .toList();
      var draw = _random.nextDouble() * weights.reduce((a, b) => a + b);
      var groupIndex = weights.length - 1;
      for (var i = 0; i < weights.length; i++) {
        draw -= weights[i];
        if (draw < 0) {
          groupIndex = i;
          break;
        }
      }
      final group = entries[groupIndex];
      final questionWeights = group.value.map(weakness).toList();
      draw = _random.nextDouble() * questionWeights.reduce((a, b) => a + b);
      var questionIndex = questionWeights.length - 1;
      for (var i = 0; i < questionWeights.length; i++) {
        draw -= questionWeights[i];
        if (draw < 0) {
          questionIndex = i;
          break;
        }
      }
      selected.add(group.value.removeAt(questionIndex));
      if (group.value.isEmpty) groups.remove(group.key);
    }
    return selected;
  }
}
