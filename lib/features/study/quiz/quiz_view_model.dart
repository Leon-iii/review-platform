import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/quiz_session.dart';
import 'package:review_platform/domain/services/answer_grader.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'quiz_view_model.g.dart';

class QuizRuntimeState {
  const QuizRuntimeState({
    required this.details,
    required this.currentIndex,
    required this.questionStartedAt,
    this.selectedChoiceId,
    this.textAnswer = '',
    this.isSubmitting = false,
  });

  final QuizSessionDetails details;
  final int currentIndex;
  final DateTime questionStartedAt;
  final String? selectedChoiceId;
  final String textAnswer;
  final bool isSubmitting;

  QuizSessionItem get currentItem => details.items[currentIndex];

  QuizRuntimeState copyWith({
    QuizSessionDetails? details,
    int? currentIndex,
    DateTime? questionStartedAt,
    String? selectedChoiceId,
    bool clearSelectedChoice = false,
    String? textAnswer,
    bool? isSubmitting,
  }) {
    return QuizRuntimeState(
      details: details ?? this.details,
      currentIndex: currentIndex ?? this.currentIndex,
      questionStartedAt: questionStartedAt ?? this.questionStartedAt,
      selectedChoiceId: clearSelectedChoice
          ? null
          : selectedChoiceId ?? this.selectedChoiceId,
      textAnswer: textAnswer ?? this.textAnswer,
      isSubmitting: isSubmitting ?? this.isSubmitting,
    );
  }
}

class QuizSubmission {
  const QuizSubmission({required this.grade, required this.completed});

  final GradeResult grade;
  final bool completed;
}

@riverpod
class QuizViewModel extends _$QuizViewModel {
  @override
  Future<QuizRuntimeState> build(String sessionId) async {
    final details = await ref
        .watch(quizRepositoryProvider)
        .resumeSession(sessionId);
    if (details == null) {
      throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
    }
    if (details.items.isEmpty) {
      throw const ValidationFailure('학습 세션에 문제가 없어요.');
    }

    return QuizRuntimeState(
      details: details,
      currentIndex: _firstIncompleteIndex(details),
      questionStartedAt: DateTime.now().toUtc(),
    );
  }

  void selectChoice(String choiceId) {
    final current = state.value;
    if (current == null || current.isSubmitting) return;
    state = AsyncData(current.copyWith(selectedChoiceId: choiceId));
  }

  void updateTextAnswer(String value) {
    final current = state.value;
    if (current == null || current.isSubmitting) return;
    state = AsyncData(current.copyWith(textAnswer: value));
  }

  Future<QuizSubmission> submit() async {
    final current = state.requireValue;
    if (current.isSubmitting) {
      throw const ValidationFailure('답안을 저장하고 있어요.');
    }
    final item = current.currentItem;
    if (item.attemptId != null) {
      throw const ValidationFailure('이미 답안을 제출한 문제예요.');
    }

    final question = item.questionSnapshot;
    late final GradeResult grade;
    late final Map<String, Object?> response;
    switch (question.type) {
      case QuestionType.multipleChoice:
        final choiceId = current.selectedChoiceId;
        if (choiceId == null) {
          throw const ValidationFailure('답을 선택해 주세요.');
        }
        grade = AnswerGrader.gradeMultipleChoice(question, choiceId);
        response = {'selectedChoiceId': choiceId};
      case QuestionType.shortAnswer:
        if (current.textAnswer.trim().isEmpty) {
          throw const ValidationFailure('답을 입력해 주세요.');
        }
        grade = AnswerGrader.gradeShortAnswer(question, current.textAnswer);
        response = {'textAnswer': current.textAnswer};
      case QuestionType.essay:
        throw const ValidationFailure('서술형 문제는 아직 지원하지 않아요.');
    }

    state = AsyncData(current.copyWith(isSubmitting: true));
    try {
      final duration = DateTime.now().toUtc().difference(
        current.questionStartedAt,
      );
      final attemptId = await ref
          .read(attemptRepositoryProvider)
          .recordAttempt(
            AttemptDraft(
              questionId: item.questionId,
              sessionId: sessionId,
              response: response,
              questionSnapshot: question,
              score: grade.score,
              maxScore: grade.maxScore,
              gradingType: GradingType.local,
              durationMs: duration.inMilliseconds,
            ),
          );
      await ref
          .read(quizRepositoryProvider)
          .linkAttempt(
            sessionId: sessionId,
            itemId: item.id,
            attemptId: attemptId,
          );

      final refreshed = await ref
          .read(quizRepositoryProvider)
          .getSession(sessionId);
      if (refreshed == null) {
        throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
      }
      final completed = refreshed.session.finishedAt != null;
      state = AsyncData(
        QuizRuntimeState(
          details: refreshed,
          currentIndex: _firstIncompleteIndex(refreshed),
          questionStartedAt: DateTime.now().toUtc(),
        ),
      );
      return QuizSubmission(grade: grade, completed: completed);
    } catch (_) {
      state = AsyncData(current.copyWith(isSubmitting: false));
      rethrow;
    }
  }

  int _firstIncompleteIndex(QuizSessionDetails details) {
    final index = details.items.indexWhere((item) => item.attemptId == null);
    return index < 0 ? details.items.length - 1 : index;
  }
}
