import 'package:review_platform/shared/widgets/app_dialog.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:review_platform/shared/widgets/ordering_answer_picker.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/features/study/quiz/quiz_view_model.dart';

class QuizView extends ConsumerStatefulWidget {
  const QuizView({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<QuizView> createState() => _QuizViewState();
}

class _QuizViewState extends ConsumerState<QuizView> {
  bool _confirmingStop = false;
  bool _confirmingReview = false;
  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    final quiz = ref.watch(quizViewModelProvider(sessionId));

    return PopScope(
      canPop: !quiz.hasValue || quiz.value!.details.session.finishedAt != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmStop();
      },
      child: Scaffold(
        key: const Key('quiz-view'),
        appBar: AppPageBar(
          title: const Text('문제 풀기'),
          fallback: AppRoutes.studySetup,
          handleSystemBack:
              !quiz.hasValue || quiz.value!.details.session.finishedAt != null,
          backKey:
              quiz.hasValue && quiz.value!.details.session.finishedAt == null
              ? const Key('stop-quiz-button')
              : null,
          backEnabled:
              !_confirmingStop &&
              !_confirmingReview &&
              !(quiz.value?.isSubmitting ?? false),
          onBack:
              quiz.hasValue && quiz.value!.details.session.finishedAt == null
              ? _confirmStop
              : null,
        ),
        body: quiz.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppErrorNotice(error: error, fallback: '학습 세션을 불러오지 못했어요.'),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () =>
                        ref.invalidate(quizViewModelProvider(sessionId)),
                    child: const Text('다시 시도'),
                  ),
                ],
              ),
            ),
          ),
          data: (state) {
            final session = state.details.session;
            if (session.finishedAt != null) {
              return _CompletedSession(sessionId: sessionId);
            }
            final item = state.currentItem;
            final question = item.questionSnapshot;
            final selfGrading =
                question.type == QuestionType.essay &&
                item.pendingEssayResponse != null;
            final currentNumber = state.currentIndex + 1;

            return ListView(
              key: ValueKey(item.id),
              padding: AppLayout.pagePadding(context),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppLayout.readingWidth,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value:
                                    state.details.processedQuestions /
                                    session.totalQuestions,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text('$currentNumber / ${session.totalQuestions}'),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  _questionTypeLabel(question.type),
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                ),
                                const SizedBox(height: 12),
                                StudyText(
                                  question.prompt,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall,
                                ),
                                const SizedBox(height: 28),
                                if (question.type == QuestionType.essay &&
                                    !selfGrading) ...[
                                  Text(
                                    session.filter.feedbackTiming ==
                                            AnswerFeedbackTiming.afterCompletion
                                        ? '모든 답안을 제출한 후 모범 답안과 비교해 자기 채점합니다.'
                                        : '답안을 제출한 후 모범 답안과 비교해 자기 채점합니다.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                if (question.type == QuestionType.trueFalse)
                                  _TrueFalseAnswerButtons(
                                    choices: question.choices,
                                    isSubmitting: state.isSubmitting,
                                    onAnswer: (choiceId) => _submit(
                                      context,
                                      ref,
                                      choiceId: choiceId,
                                      expectedItemId: item.id,
                                    ),
                                  )
                                else if (question.type == QuestionType.ordering)
                                  OrderingAnswerPicker(
                                    choices: question.choices,
                                    selectedIds: state.orderedChoiceIds,
                                    enabled: !state.isSubmitting,
                                    onToggle: ref
                                        .read(
                                          quizViewModelProvider(sessionId)
                                              .notifier,
                                        )
                                        .toggleOrderingChoice,
                                    onClear: ref
                                        .read(
                                          quizViewModelProvider(sessionId)
                                              .notifier,
                                        )
                                        .clearOrderingChoices,
                                  )
                                else if (question.type ==
                                    QuestionType.multipleChoice)
                                  RadioGroup<String>(
                                    groupValue: state.selectedChoiceId,
                                    onChanged: (value) {
                                      if (value != null) {
                                        ref
                                            .read(
                                              quizViewModelProvider(sessionId)
                                                  .notifier,
                                            )
                                            .selectChoice(value);
                                      }
                                    },
                                    child: Column(
                                      children: [
                                        for (final choice in question.choices)
                                          RadioListTile<String>(
                                            key: Key('choice-${choice.id}'),
                                            value: choice.id,
                                            title: StudyText(choice.text),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                      ],
                                    ),
                                  )
                                else if (selfGrading)
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const Text('자기 채점'),
                                      const SizedBox(height: 8),
                                      const Text('내 답안'),
                                      StudyText(
                                        item.pendingEssayResponse!['textAnswer']
                                                as String? ??
                                            '',
                                      ),
                                      const Divider(height: 24),
                                      const Text('모범 답안'),
                                      StudyText(
                                        question.acceptableAnswers.join('\n\n'),
                                      ),
                                      if (question.explanation?.isNotEmpty ==
                                          true) ...[
                                        const Divider(height: 24),
                                        const Text('해설'),
                                        StudyText(question.explanation!),
                                      ],
                                    ],
                                  )
                                else
                                  TextFormField(
                                    key: Key('answer-${item.id}'),
                                    initialValue: state.textAnswer,
                                    enabled: !state.isSubmitting,
                                    autofocus: true,
                                    minLines:
                                        question.type == QuestionType.essay
                                        ? 4
                                        : 1,
                                    maxLines:
                                        question.type == QuestionType.essay
                                        ? 8
                                        : 1,
                                    textInputAction:
                                        question.type == QuestionType.essay
                                        ? TextInputAction.newline
                                        : TextInputAction.done,
                                    onChanged: ref
                                        .read(
                                          quizViewModelProvider(sessionId)
                                              .notifier,
                                        )
                                        .updateTextAnswer,
                                    onFieldSubmitted:
                                        question.type == QuestionType.essay
                                        ? null
                                        : (_) => _submit(
                                            context,
                                            ref,
                                            expectedItemId: item.id,
                                          ),
                                    decoration: const InputDecoration(
                                      labelText: '답',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (selfGrading) ...[
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            key: const Key('essay-grade-correct'),
                            onPressed: state.isSubmitting
                                ? null
                                : () => _submit(
                                    context,
                                    ref,
                                    expectedItemId: item.id,
                                    manualCorrect: true,
                                  ),
                            icon: const Icon(Icons.check_rounded),
                            label: const Text('정답으로 기록'),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const Key('essay-grade-incorrect'),
                            onPressed: state.isSubmitting
                                ? null
                                : () => _submit(
                                    context,
                                    ref,
                                    expectedItemId: item.id,
                                    manualCorrect: false,
                                  ),
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('오답으로 기록'),
                          ),
                        ] else if (question.type != QuestionType.trueFalse) ...[
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            key: const Key('submit-answer-button'),
                            onPressed:
                                state.isSubmitting ||
                                    (question.type == QuestionType.ordering &&
                                        state.orderedChoiceIds.length !=
                                            question.choices.length)
                                ? null
                                : () => _submit(
                                    context,
                                    ref,
                                    expectedItemId: item.id,
                                  ),
                            icon: state.isSubmitting
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check_rounded),
                            label: Text(
                              state.isSubmitting
                                  ? '저장 중...'
                                  : question.type == QuestionType.essay ||
                                        question.type == QuestionType.ordering
                                  ? '답안 제출'
                                  : '정답 제출',
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (!selfGrading)
                          OutlinedButton.icon(
                            key: const Key('unknown-answer-button'),
                            onPressed: state.isSubmitting
                                ? null
                                : () => _submit(
                                    context,
                                    ref,
                                    isUnknown: true,
                                    expectedItemId: item.id,
                                  ),
                            icon: const Icon(Icons.help_outline_rounded),
                            label: const Text('모름'),
                          ),
                        const Divider(
                          key: Key('quiz-review-divider'),
                          height: 32,
                        ),
                        OutlinedButton.icon(
                          key: const Key('request-question-review-button'),
                          onPressed:
                              state.isSubmitting ||
                                  _confirmingStop ||
                                  _confirmingReview
                              ? null
                              : () => _confirmReview(item.id),
                          icon: const Icon(Icons.rate_review_outlined),
                          label: const Text('문제 재검토'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _questionTypeLabel(QuestionType type) => switch (type) {
    QuestionType.ordering => '순서 배열형',
    QuestionType.multipleChoice => '객관식',
    QuestionType.trueFalse => 'O/X',
    QuestionType.shortAnswer => '단답형',
    QuestionType.essay => '서술형',
  };

  Future<void> _confirmStop() async {
    if (!mounted) return;
    final current = ref.read(quizViewModelProvider(sessionId)).value;
    if (_confirmingStop ||
        _confirmingReview ||
        current == null ||
        current.isSubmitting ||
        current.details.session.finishedAt != null) {
      return;
    }
    setState(() => _confirmingStop = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AppDialog(
          key: const Key('stop-quiz-confirm-dialog'),
          title: const Text('문제 풀이를 중단할까요?'),
          content: const Text(
            '현재 세션을 종료하고 결과를 확인합니다.\n'
            '이미 채점한 답안은 유지됩니다. 현재 입력 중인 미제출 답안은 저장되지 않으며, '
            '자기 채점 대기 답안은 점수에 포함되지 않습니다.',
          ),
          actions: [
            TextButton(
              key: const Key('continue-quiz-button'),
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('계속 풀기'),
            ),
            FilledButton(
              key: const Key('confirm-stop-quiz-button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('중단하기'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await ref.read(quizViewModelProvider(sessionId).notifier).stop();
      if (mounted) context.go(AppRoutes.studyResult(sessionId));
    } catch (error) {
      if (mounted) showAppError(context, error, fallback: '문제 풀이를 중단하지 못했어요.');
    } finally {
      if (mounted) setState(() => _confirmingStop = false);
    }
  }

  Future<void> _confirmReview(String expectedItemId) async {
    if (!mounted || _confirmingStop || _confirmingReview) return;
    final current = ref.read(quizViewModelProvider(sessionId)).value;
    if (current == null ||
        current.isSubmitting ||
        current.details.session.finishedAt != null ||
        current.currentItem.id != expectedItemId ||
        current.currentItem.attemptId != null ||
        current.currentItem.skippedForReview) {
      return;
    }
    setState(() => _confirmingReview = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AppDialog(
          key: const Key('question-review-confirm-dialog'),
          title: const Text('문제 재검토를 요청할까요?'),
          content: const Text(
            '이 문제를 건너뛰고 점수와 정답률에서 제외합니다.\n'
            '문제의 기존 검수 상태를 검수 필요로 되돌립니다. 검수 완료 전까지 새 퀴즈에 출제되지 않습니다.',
          ),
          actions: [
            TextButton(
              key: const Key('cancel-question-review-button'),
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('계속 풀기'),
            ),
            FilledButton(
              key: const Key('confirm-question-review-button'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('재검토 요청'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final completed = await ref
          .read(quizViewModelProvider(sessionId).notifier)
          .requestReview(expectedItemId: expectedItemId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('검수 필요로 변경하고 문제를 건너뛰었어요.')),
        );
      if (completed) context.go(AppRoutes.studyResult(sessionId));
    } catch (error) {
      if (mounted) {
        showAppError(context, error, fallback: '문제 재검토 요청을 저장하지 못했어요.');
      }
    } finally {
      if (mounted) setState(() => _confirmingReview = false);
    }
  }

  Future<void> _submit(
    BuildContext context,
    WidgetRef ref, {
    String? choiceId,
    String? expectedItemId,
    bool isUnknown = false,
    bool? manualCorrect,
  }) async {
    if (!context.mounted || _confirmingStop || _confirmingReview) return;
    if (expectedItemId != null) {
      // Guard live state too: rapid taps may arrive before disabled buttons
      // rebuild, or from the previous question after submission has finished.
      final current = ref.read(quizViewModelProvider(sessionId)).value;
      if (current == null ||
          current.isSubmitting ||
          current.details.session.finishedAt != null ||
          current.currentItem.attemptId != null ||
          current.currentItem.skippedForReview ||
          current.currentItem.id != expectedItemId) {
        return;
      }
      if (manualCorrect == null &&
          !isUnknown &&
          current.currentItem.pendingEssayResponse != null) {
        return;
      }
    }
    if (choiceId != null) {
      ref
          .read(quizViewModelProvider(sessionId).notifier)
          .selectChoice(choiceId);
    }
    try {
      final result = await ref
          .read(quizViewModelProvider(sessionId).notifier)
          .submit(isUnknown: isUnknown, manualCorrect: manualCorrect);
      if (!context.mounted) return;
      if (result.showImmediateFeedback) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                result.isUnknown
                    ? '모름으로 기록했어요.'
                    : result.grade.isCorrect
                    ? '정답이에요.'
                    : '오답이에요.',
              ),
            ),
          );
      }
      if (result.completed) {
        context.go(AppRoutes.studyResult(sessionId));
      }
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '답안을 저장하지 못했어요.';
      showAppError(context, message);
    }
  }
}

class _TrueFalseAnswerButtons extends StatelessWidget {
  const _TrueFalseAnswerButtons({
    required this.choices,
    required this.isSubmitting,
    required this.onAnswer,
  });

  final List<SnapshotChoice> choices;
  final bool isSubmitting;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        textDirection: TextDirection.ltr,
        children: [
          Expanded(child: _button('O')),
          const SizedBox(width: 16),
          Expanded(child: _button('X')),
        ],
      ),
      if (isSubmitting) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(key: Key('true-false-submit-progress')),
        const SizedBox(height: 8),
        const Text('답안 저장 중...', textAlign: TextAlign.center),
      ],
    ],
  );

  Widget _button(String symbol) {
    final choice = choices
        .where((choice) => choice.text.trim().toUpperCase() == symbol)
        .firstOrNull;
    return FilledButton.tonal(
      key: Key('true-false-${symbol.toLowerCase()}-button'),
      onPressed: isSubmitting || choice == null
          ? null
          : () => onAnswer(choice.id),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 160),
        visualDensity: VisualDensity.standard,
        textStyle: const TextStyle(fontSize: 72, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(symbol, semanticsLabel: '$symbol 선택 후 즉시 제출'),
      ),
    );
  }
}

class _CompletedSession extends StatelessWidget {
  const _CompletedSession({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.icon(
        onPressed: () => context.go(AppRoutes.studyResult(sessionId)),
        icon: const Icon(Icons.bar_chart_rounded),
        label: const Text('결과 보기'),
      ),
    );
  }
}
