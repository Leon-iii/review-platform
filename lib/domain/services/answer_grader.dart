import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/services/question_ordering.dart';

class GradeResult {
  const GradeResult({required this.score, required this.maxScore});

  final double score;
  final double maxScore;

  bool get isCorrect => score == maxScore;
}

abstract final class AnswerGrader {
  static GradeResult gradeOrdering(
    QuestionSnapshot question,
    List<String> selectedIds,
  ) {
    if (question.type != QuestionType.ordering ||
        !QuestionOrdering.isPermutation(
          question.correctChoiceIds,
          question.choices.map((c) => c.id),
        )) {
      throw const ValidationFailure(
        '순서 배열형의 정답 정보가 올바르지 않아요. 문제 재검토를 요청해 주세요.',
      );
    }
    if (!QuestionOrdering.isPermutation(
      selectedIds,
      question.choices.map((c) => c.id),
    )) {
      throw const ValidationFailure('모든 단계를 한 번씩 배치해 주세요.');
    }
    return GradeResult(
      score:
          List.generate(
            selectedIds.length,
            (i) => selectedIds[i] == question.correctChoiceIds[i],
          ).every((same) => same)
          ? 1
          : 0,
      maxScore: 1,
    );
  }

  static GradeResult gradeMultipleChoice(
    QuestionSnapshot question,
    String selectedChoiceId,
  ) {
    if (question.type != QuestionType.multipleChoice) {
      throw const ValidationFailure('객관식 문제가 아닙니다.');
    }
    final isCorrect = question.choices.any(
      (choice) => choice.id == selectedChoiceId && choice.isCorrect,
    );
    return GradeResult(score: isCorrect ? 1 : 0, maxScore: 1);
  }

  static GradeResult gradeTrueFalse(
    QuestionSnapshot question,
    String selectedChoiceId,
  ) {
    if (question.type != QuestionType.trueFalse) {
      throw const ValidationFailure('O/X 문제가 아닙니다.');
    }
    final isCorrect = question.choices.any(
      (choice) => choice.id == selectedChoiceId && choice.isCorrect,
    );
    return GradeResult(score: isCorrect ? 1 : 0, maxScore: 1);
  }

  static GradeResult gradeShortAnswer(
    QuestionSnapshot question,
    String answer,
  ) {
    if (question.type != QuestionType.shortAnswer) {
      throw const ValidationFailure('단답형 문제가 아닙니다.');
    }
    String normalizeAnswer(String value) => normalize(
      value,
      caseSensitive: question.caseSensitive,
      whitespaceSensitive: question.whitespaceSensitive,
    );
    final normalizedAnswer = normalizeAnswer(answer);
    final isCorrect = question.acceptableAnswers.any(
      (candidate) => normalizeAnswer(candidate) == normalizedAnswer,
    );
    return GradeResult(score: isCorrect ? 1 : 0, maxScore: 1);
  }

  static String normalize(
    String value, {
    bool caseSensitive = false,
    bool whitespaceSensitive = false,
  }) {
    var normalized = value.trim();
    if (!whitespaceSensitive) {
      normalized = normalized.replaceAll(RegExp(r'\s+'), '');
    }
    return caseSensitive ? normalized : normalized.toLowerCase();
  }
}
