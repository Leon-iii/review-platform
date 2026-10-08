import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/ordering_sequence.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/features/study/result/quiz_result_view_model.dart';
import 'package:review_platform/repositories/quiz_answer_correction_repository.dart';

class QuizResultView extends ConsumerStatefulWidget {
  const QuizResultView({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<QuizResultView> createState() => _QuizResultViewState();
}

class _QuizResultViewState extends ConsumerState<QuizResultView> {
  int _pendingUpdates = 0;
  bool get _isUpdating => _pendingUpdates > 0;
  String? _updatingAttemptId;

  Future<void> _accept(Attempt attempt) async {
    if (_isUpdating) return;
    setState(() {
      _pendingUpdates++;
      _updatingAttemptId = attempt.id;
    });
    final repository = ref.read(quizAnswerCorrectionRepositoryProvider);
    try {
      final correction = await repository.acceptSubmittedAnswer(attempt.id);
      if (!mounted) return;
      ref.invalidate(quizResultProvider(widget.sessionId));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('제출한 답안을 정답으로 등록했어요.'),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: '실행취소',
              // Snackbars have an inverse surface: use an accessible blue on it.
              textColor: Theme.of(context).brightness == Brightness.dark
                  ? Colors.blue.shade800
                  : Colors.blue.shade200,
              onPressed: () => _undo(repository, correction),
            ),
          ),
        );
    } catch (error) {
      if (mounted) showAppError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _pendingUpdates--;
          _updatingAttemptId = null;
        });
      }
    }
  }

  Future<void> _undo(
    QuizAnswerCorrectionRepository repository,
    QuizAnswerCorrection correction,
  ) async {
    if (mounted) setState(() => _pendingUpdates++);
    try {
      await repository.undo(correction);
      if (mounted) ref.invalidate(quizResultProvider(widget.sessionId));
    } catch (error) {
      if (mounted) showAppError(context, error);
    } finally {
      if (mounted) setState(() => _pendingUpdates--);
    }
  }

  Widget _answerCard(Attempt attempt) => _AnswerResultCard(
    key: ValueKey(attempt.id),
    attempt: attempt,
    onAccept: _isUpdating ? null : () => _accept(attempt),
    isUpdating: _updatingAttemptId == attempt.id,
  );

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(quizResultProvider(widget.sessionId));

    return Scaffold(
      key: const Key('quiz-result-view'),
      appBar: AppPageBar(
        fallback: AppRoutes.studySetup,
        title: const Text('퀴즈 결과'),
      ),
      body: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: AppErrorNotice(error: error, fallback: '결과를 불러오지 못했어요.'),
        ),
        data: (summary) => Center(
          child: SingleChildScrollView(
            padding: AppLayout.pagePadding(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.readingWidth,
              ),
              child: Column(
                children: [
                  Icon(
                    summary.stopped
                        ? Icons.stop_circle_outlined
                        : Icons.emoji_events_rounded,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    summary.stopped ? '학습 중단' : '학습 완료',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (summary.stopped) ...[
                    const SizedBox(height: 8),
                    Text(
                      '전체 ${summary.session.totalQuestions}문항 중 ${summary.attempts.length}문항 채점 완료',
                    ),
                    const Text('채점하지 않은 문항은 점수와 정답률에서 제외됩니다.'),
                  ],
                  if (summary.skippedQuestions > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '재검토 요청 ${summary.skippedQuestions}문항은 점수와 정답률에서 제외됩니다.',
                    ),
                  ],
                  const SizedBox(height: 28),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Expanded(
                            child: _ResultValue(
                              label: '총점',
                              value:
                                  '${summary.totalScore.toStringAsFixed(0)}/${summary.maxScore.toStringAsFixed(0)}',
                            ),
                          ),
                          Expanded(
                            child: _ResultValue(
                              label: '정답',
                              value:
                                  '${summary.correctCount}/${summary.attempts.length}',
                            ),
                          ),
                          Expanded(
                            child: _ResultValue(
                              label: '정답률',
                              value: '${summary.accuracyPercent}%',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      summary.session.filter.feedbackTiming ==
                              AnswerFeedbackTiming.afterCompletion
                          ? '문제별 결과'
                          : '오답 문제',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (summary.attempts.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('채점한 문항이 없어요.'),
                      ),
                    )
                  else if (summary.session.filter.feedbackTiming ==
                      AnswerFeedbackTiming.afterCompletion)
                    for (final attempt in summary.attempts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _answerCard(attempt),
                      )
                  else if (summary.wrongAttempts.isEmpty)
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_outline_rounded),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                summary.stopped || summary.skippedQuestions > 0
                                    ? '채점한 문항은 모두 맞혔어요.'
                                    : '모든 문제를 맞혔어요.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final attempt in summary.wrongAttempts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _answerCard(attempt),
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
                    child: TextButton.icon(
                      onPressed: () => context.go(AppRoutes.home),
                      icon: const Icon(Icons.home_outlined),
                      label: const Text('홈으로'),
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

class _AnswerResultCard extends StatelessWidget {
  const _AnswerResultCard({
    required this.attempt,
    required this.onAccept,
    required this.isUpdating,
    super.key,
  });

  final Attempt attempt;
  final VoidCallback? onAccept;
  final bool isUpdating;

  @override
  Widget build(BuildContext context) {
    final question = attempt.questionSnapshot;
    final isCorrect = attempt.score == attempt.maxScore;
    final submittedAnswer = attempt.isUnknown
        ? '모름'
        : switch (question.type) {
            QuestionType.multipleChoice || QuestionType.trueFalse =>
              question.choices
                      .where(
                        (choice) =>
                            choice.id == attempt.response['selectedChoiceId'],
                      )
                      .map((choice) => choice.text)
                      .firstOrNull ??
                  '선택 없음',
            QuestionType.shortAnswer || QuestionType.essay =>
              attempt.response['textAnswer'] as String? ?? '',
            QuestionType.ordering => '',
          };
    final correctAnswer = switch (question.type) {
      QuestionType.multipleChoice || QuestionType.trueFalse =>
        question.choices
            .where((choice) => choice.isCorrect)
            .map((choice) => choice.text)
            .join(', '),
      QuestionType.shortAnswer ||
      QuestionType.essay => question.acceptableAnswers.join('\n'),
      QuestionType.ordering => '',
    };

    return Card(
      child: ExpansionTile(
        key: Key('quiz-answer-result-${attempt.questionId}'),
        leading: Icon(
          attempt.isUnknown
              ? Icons.help_outline_rounded
              : isCorrect
              ? Icons.check_circle_outline_rounded
              : Icons.cancel_outlined,
          color: attempt.isUnknown
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : isCorrect
              ? Colors.green
              : Theme.of(context).colorScheme.error,
        ),
        title: StudyText(question.prompt),
        subtitle: Text(
          attempt.isUnknown
              ? '모름'
              : isCorrect
              ? '정답'
              : '오답',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (question.type == QuestionType.ordering) ...[
            const Text('내 답'),
            const SizedBox(height: 8),
            if (attempt.isUnknown)
              const Text('모름')
            else
              OrderingSequence(
                steps: [
                  for (final id
                      in (attempt.response['orderedChoiceIds'] as List? ??
                              const [])
                          .cast<String>())
                    (
                      label:
                          '${question.choices.indexWhere((c) => c.id == id) + 1}',
                      text:
                          question.choices
                              .where((c) => c.id == id)
                              .firstOrNull
                              ?.text ??
                          '알 수 없는 단계',
                    ),
                ],
              ),
            const Divider(height: 24),
            const Text('정답'),
            const SizedBox(height: 8),
            OrderingSequence(
              steps: [
                for (final id in question.correctChoiceIds)
                  (
                    label:
                        '${question.choices.indexWhere((c) => c.id == id) + 1}',
                    text:
                        question.choices
                            .where((c) => c.id == id)
                            .firstOrNull
                            ?.text ??
                        '알 수 없는 단계',
                  ),
              ],
            ),
          ] else ...[
            StudyText('내 답: $submittedAnswer'),
            const SizedBox(height: 6),
            StudyText('정답: $correctAnswer'),
          ],
          if (question.explanation case final explanation?) ...[
            const SizedBox(height: 10),
            StudyText('해설: $explanation'),
          ],
          if (question.type == QuestionType.shortAnswer &&
              !isCorrect &&
              !attempt.isUnknown &&
              (attempt.response['textAnswer'] as String? ?? '')
                  .trim()
                  .isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              key: Key('accept-submitted-answer-${attempt.id}'),
              onPressed: onAccept,
              icon: isUpdating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.playlist_add_check_rounded),
              label: Text(isUpdating ? '정답 등록 중…' : '이 답안을 정답에 추가'),
            ),
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
