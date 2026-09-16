import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/features/study/result/quiz_result_view_model.dart';

class QuizResultView extends ConsumerWidget {
  const QuizResultView({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(quizResultProvider(sessionId));

    return Scaffold(
      appBar: AppBar(title: const Text('퀴즈 결과')),
      body: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Text(error is AppFailure ? error.message : '결과를 불러오지 못했어요.'),
        ),
        data: (summary) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                children: [
                  Icon(
                    Icons.emoji_events_rounded,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '학습 완료',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 28),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _ResultValue(
                            label: '총점',
                            value:
                                '${summary.totalScore.toStringAsFixed(0)}/${summary.maxScore.toStringAsFixed(0)}',
                          ),
                          _ResultValue(
                            label: '정답',
                            value:
                                '${summary.correctCount}/${summary.attempts.length}',
                          ),
                          _ResultValue(
                            label: '정답률',
                            value: '${summary.accuracyPercent}%',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '오답 문제',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (summary.wrongAttempts.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_outline_rounded),
                            SizedBox(width: 12),
                            Expanded(child: Text('모든 문제를 맞혔어요.')),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final attempt in summary.wrongAttempts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _WrongAnswerCard(attempt: attempt),
                      ),
                  if (summary.wrongAttempts.isNotEmpty &&
                      summary.session.sourceFolderId != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => context.go(
                          AppRoutes.studySetupForWrong(
                            summary.session.sourceFolderId!,
                          ),
                        ),
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('최근 오답 다시 풀기'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => context.go(AppRoutes.studySetup),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('새 학습 시작'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => context.go(AppRoutes.home),
                      child: const Text('홈으로'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WrongAnswerCard extends StatelessWidget {
  const _WrongAnswerCard({required this.attempt});

  final Attempt attempt;

  @override
  Widget build(BuildContext context) {
    final question = attempt.questionSnapshot;
    final submittedAnswer = switch (question.type) {
      QuestionType.multipleChoice =>
        question.choices
                .where(
                  (choice) => choice.id == attempt.response['selectedChoiceId'],
                )
                .map((choice) => choice.text)
                .firstOrNull ??
            '선택 없음',
      QuestionType.shortAnswer =>
        attempt.response['textAnswer'] as String? ?? '',
      QuestionType.essay => '서술형 답안',
    };
    final correctAnswer = switch (question.type) {
      QuestionType.multipleChoice =>
        question.choices
            .where((choice) => choice.isCorrect)
            .map((choice) => choice.text)
            .join(', '),
      QuestionType.shortAnswer => question.acceptableAnswers.join(', '),
      QuestionType.essay => '수동 채점',
    };

    return Card(
      child: ExpansionTile(
        leading: Icon(
          Icons.cancel_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(question.prompt),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('내 답: $submittedAnswer'),
          const SizedBox(height: 6),
          Text('정답: $correctAnswer'),
          if (question.explanation case final explanation?) ...[
            const SizedBox(height: 10),
            Text('해설: $explanation'),
          ],
        ],
      ),
    );
  }
}

class _ResultValue extends StatelessWidget {
  const _ResultValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
