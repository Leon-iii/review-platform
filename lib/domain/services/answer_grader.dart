import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';

class GradeResult {
  const GradeResult({required this.score, required this.maxScore});

  final double score;
  final double maxScore;

  bool get isCorrect => score == maxScore;
}

abstract final class AnswerGrader {
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
    final normalizedAnswer = normalize(answer);
    final isCorrect = question.acceptableAnswers.any(
      (candidate) => normalize(candidate) == normalizedAnswer,
    );
    return GradeResult(score: isCorrect ? 1 : 0, maxScore: 1);
  }

  static String normalize(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
