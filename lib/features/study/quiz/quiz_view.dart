import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/features/study/quiz/quiz_view_model.dart';

class QuizView extends ConsumerWidget {
  const QuizView({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = ref.watch(quizViewModelProvider(sessionId));

    return Scaffold(
      key: const Key('quiz-view'),
      appBar: AppBar(title: const Text('문제 풀기')),
      body: quiz.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
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
          final currentNumber = state.currentIndex + 1;

          return ListView(
            key: ValueKey(item.id),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value:
                                  session.completedQuestions /
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
                          padding: const EdgeInsets.all(24),
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
                              Text(
                                question.prompt,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              const SizedBox(height: 28),
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
                                          title: Text(choice.text),
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                    ],
                                  ),
                                )
                              else
                                TextFormField(
                                  key: Key('answer-${item.id}'),
                                  initialValue: state.textAnswer,
                                  enabled: !state.isSubmitting,
                                  autofocus: true,
                                  textInputAction: TextInputAction.done,
                                  onChanged: ref
                                      .read(
                                        quizViewModelProvider(sessionId)
                                            .notifier,
                                      )
                                      .updateTextAnswer,
                                  onFieldSubmitted: (_) => _submit(
                                    context,
                                    ref,
                                    expectedItemId: item.id,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: '답',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (question.type != QuestionType.trueFalse) ...[
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const Key('submit-answer-button'),
                          onPressed: state.isSubmitting
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
                          label: Text(state.isSubmitting ? '저장 중...' : '정답 제출'),
                        ),
                      ],
                      const SizedBox(height: 12),
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
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _questionTypeLabel(QuestionType type) => switch (type) {
    QuestionType.multipleChoice => '객관식',
    QuestionType.trueFalse => 'O/X',
    QuestionType.shortAnswer => '단답형',
    QuestionType.essay => '서술형',
  };

  Future<void> _submit(
    BuildContext context,
    WidgetRef ref, {
    String? choiceId,
    String? expectedItemId,
    bool isUnknown = false,
  }) async {
    if (!context.mounted) return;
    if (expectedItemId != null) {
      // Guard live state too: rapid taps may arrive before disabled buttons
      // rebuild, or from the previous question after submission has finished.
      final current = ref.read(quizViewModelProvider(sessionId)).value;
      if (current == null ||
          current.isSubmitting ||
          current.details.session.finishedAt != null ||
          current.currentItem.attemptId != null ||
          current.currentItem.id != expectedItemId) {
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
          .submit(isUnknown: isUnknown);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
