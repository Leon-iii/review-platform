import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/quiz_session.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
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
    this.orderedChoiceIds = const [],
  });

  final QuizSessionDetails details;
  final int currentIndex;
  final DateTime questionStartedAt;
  final String? selectedChoiceId;
  final String textAnswer;
  final bool isSubmitting;
  final List<String> orderedChoiceIds;

  QuizSessionItem get currentItem => details.items[currentIndex];

  QuizRuntimeState copyWith({
    QuizSessionDetails? details,
    int? currentIndex,
    DateTime? questionStartedAt,
    String? selectedChoiceId,
    bool clearSelectedChoice = false,
    String? textAnswer,
    bool? isSubmitting,
    List<String>? orderedChoiceIds,
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
      orderedChoiceIds: orderedChoiceIds ?? this.orderedChoiceIds,
    );
  }
}

class QuizSubmission {
  const QuizSubmission({
    required this.grade,
    required this.completed,
    required this.showImmediateFeedback,
    this.isUnknown = false,
    this.answerSaved = false,
  });

  final GradeResult grade;
  final bool completed;
  final bool showImmediateFeedback;
  final bool isUnknown;
  final bool answerSaved;
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

  void toggleOrderingChoice(String id) {
    final current = state.value;
    if (current == null ||
        current.isSubmitting ||
        current.currentItem.attemptId != null ||
        current.currentItem.questionSnapshot.type != QuestionType.ordering ||
        !current.currentItem.questionSnapshot.choices.any(
          (choice) => choice.id == id,
        )) {
      return;
    }
    final order = [...current.orderedChoiceIds];
    if (!order.remove(id)) order.add(id);
    state = AsyncData(
      current.copyWith(orderedChoiceIds: List.unmodifiable(order)),
    );
  }

  void clearOrderingChoices() {
    final current = state.value;
    if (current == null || current.isSubmitting) return;
    state = AsyncData(current.copyWith(orderedChoiceIds: const []));
  }

  Future<QuizSubmission> submit({
    bool isUnknown = false,
    bool? manualCorrect,
  }) async {
    final current = state.requireValue;
    if (current.details.session.finishedAt != null) {
      throw const ValidationFailure('이미 종료된 학습 세션이에요.');
    }
    if (current.isSubmitting) {
      throw const ValidationFailure('답안을 저장하고 있어요.');
    }
    final item = current.currentItem;
    if (item.attemptId != null || item.skippedForReview) {
      throw const ValidationFailure('이미 답안을 제출한 문제예요.');
    }

    final question = item.questionSnapshot;
    if (question.type == QuestionType.essay &&
        !isUnknown &&
        item.pendingEssayResponse == null) {
      if (current.textAnswer.trim().isEmpty) {
        throw const ValidationFailure('답을 입력해 주세요.');
      }
      state = AsyncData(current.copyWith(isSubmitting: true));
      try {
        await ref
            .read(quizRepositoryProvider)
            .saveEssayResponse(
              sessionId: sessionId,
              itemId: item.id,
              answer: current.textAnswer,
              durationMs: DateTime.now()
                  .toUtc()
                  .difference(current.questionStartedAt)
                  .inMilliseconds,
            );
        final refreshed = (await ref
            .read(quizRepositoryProvider)
            .getSession(sessionId))!;
        state = AsyncData(
          QuizRuntimeState(
            details: refreshed,
            currentIndex: _firstIncompleteIndex(refreshed),
            questionStartedAt: DateTime.now().toUtc(),
          ),
        );
        return const QuizSubmission(
          grade: GradeResult(score: 0, maxScore: 1),
          completed: false,
          showImmediateFeedback: false,
          answerSaved: true,
        );
      } catch (_) {
        state = AsyncData(current.copyWith(isSubmitting: false));
        rethrow;
      }
    }
    late final GradeResult grade;
    late final Map<String, Object?> response;
    if (isUnknown) {
      grade = const GradeResult(score: 0, maxScore: 1);
      // Do not retain a previously selected/typed answer as a guessed answer.
      response = {'isUnknown': true};
    } else {
      switch (question.type) {
        case QuestionType.ordering:
          grade = AnswerGrader.gradeOrdering(
            question,
            current.orderedChoiceIds,
          );
          response = {'orderedChoiceIds': current.orderedChoiceIds};
        case QuestionType.multipleChoice:
          final choiceId = current.selectedChoiceId;
          if (choiceId == null) {
            throw const ValidationFailure('답을 선택해 주세요.');
          }
          grade = AnswerGrader.gradeMultipleChoice(question, choiceId);
          response = {'selectedChoiceId': choiceId};
        case QuestionType.trueFalse:
          final choiceId = current.selectedChoiceId;
          if (choiceId == null) {
            throw const ValidationFailure('O 또는 X를 선택해 주세요.');
          }
          grade = AnswerGrader.gradeTrueFalse(question, choiceId);
          response = {'selectedChoiceId': choiceId};
        case QuestionType.shortAnswer:
          if (current.textAnswer.trim().isEmpty) {
            throw const ValidationFailure('답을 입력해 주세요.');
          }
          grade = AnswerGrader.gradeShortAnswer(question, current.textAnswer);
          response = {'textAnswer': current.textAnswer};
        case QuestionType.essay:
          if (manualCorrect == null || item.pendingEssayResponse == null) {
            throw const ValidationFailure('모범답안을 확인하고 자기 채점을 해 주세요.');
          }
          grade = GradeResult(score: manualCorrect ? 1 : 0, maxScore: 1);
          response = {
            'textAnswer': item.pendingEssayResponse!['textAnswer'],
            'selfAssessed': true,
          };
      }
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
              gradingType: question.type == QuestionType.essay && !isUnknown
                  ? GradingType.manual
                  : GradingType.local,
              durationMs:
                  item.pendingEssayResponse?['durationMs'] as int? ??
                  duration.inMilliseconds,
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
      return QuizSubmission(
        grade: grade,
        completed: completed,
        isUnknown: isUnknown,
        showImmediateFeedback:
            current.details.session.filter.feedbackTiming ==
            AnswerFeedbackTiming.immediate,
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isSubmitting: false));
      rethrow;
    }
  }

  Future<void> stop() async {
    final current = state.requireValue;
    if (current.isSubmitting) {
      throw const ValidationFailure('답안 저장이 끝난 뒤 중단해 주세요.');
    }
    if (current.details.session.finishedAt != null) return;
    state = AsyncData(current.copyWith(isSubmitting: true));
    try {
      final repository = ref.read(quizRepositoryProvider);
      await repository.finishSession(sessionId);
      final details = await repository.getSession(sessionId);
      if (details == null) {
        throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
      }
      state = AsyncData(
        current.copyWith(details: details, isSubmitting: false),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isSubmitting: false));
      rethrow;
    }
  }

  Future<bool> requestReview({required String expectedItemId}) async {
    final current = state.requireValue;
    if (current.isSubmitting ||
        current.details.session.finishedAt != null ||
        current.currentItem.id != expectedItemId ||
        current.currentItem.attemptId != null ||
        current.currentItem.skippedForReview) {
      throw const ValidationFailure('현재 문제를 재검토 요청할 수 없어요.');
    }
    state = AsyncData(current.copyWith(isSubmitting: true));
    try {
      final repository = ref.read(quizRepositoryProvider);
      await repository.skipForReview(
        sessionId: sessionId,
        itemId: expectedItemId,
      );
      final refreshed = await repository.getSession(sessionId);
      if (refreshed == null) throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
      state = AsyncData(
        QuizRuntimeState(
          details: refreshed,
          currentIndex: _firstIncompleteIndex(refreshed),
          questionStartedAt: DateTime.now().toUtc(),
        ),
      );
      return refreshed.session.finishedAt != null;
    } catch (_) {
      state = AsyncData(current.copyWith(isSubmitting: false));
      rethrow;
    }
  }

  int _firstIncompleteIndex(QuizSessionDetails details) {
    if (details.session.filter.feedbackTiming ==
        AnswerFeedbackTiming.afterCompletion) {
      final unanswered = details.items.indexWhere(
        (item) =>
            !item.skippedForReview &&
            item.attemptId == null &&
            item.pendingEssayResponse == null,
      );
      if (unanswered >= 0) return unanswered;
    }
    final index = details.items.indexWhere(
      (item) => !item.skippedForReview && item.attemptId == null,
    );
    return index < 0 ? details.items.length - 1 : index;
  }
}
