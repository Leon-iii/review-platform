import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/features/study/quiz/quiz_view_model.dart';

class QuizView extends ConsumerWidget {
  const QuizView({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = ref.watch(quizViewModelProvider(sessionId));

    return Scaffold(
      appBar: AppBar(title: const Text('문제 풀기')),
      body: quiz.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error is AppFailure ? error.message : '학습 세션을 불러오지 못했어요.'),
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
                              if (question.type ==
                                      QuestionType.multipleChoice ||
                                  question.type == QuestionType.trueFalse)
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
                                  onFieldSubmitted: (_) =>
                                      _submit(context, ref),
                                  decoration: const InputDecoration(
                                    labelText: '답',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        key: const Key('submit-answer-button'),
                        onPressed: state.isSubmitting
                            ? null
                            : () => _submit(context, ref),
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

  Future<void> _submit(BuildContext context, WidgetRef ref) async {
    try {
      final result = await ref
          .read(quizViewModelProvider(sessionId).notifier)
          .submit();
      if (!context.mounted) return;
      if (result.completed) {
        context.go(AppRoutes.studyResult(sessionId));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.grade.isCorrect ? '정답이에요.' : '오답이에요.')),
        );
      }
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '답안을 저장하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
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
