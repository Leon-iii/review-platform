import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/domain/models/statistics_summary.dart';
import 'package:review_platform/features/statistics/statistics_view_model.dart';

class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final statistics = ref.watch(statisticsProvider);

    return CustomScrollView(
      key: const Key('home-view'),
      slivers: [
        const SliverAppBar.large(title: Text('복습 노트')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '오늘도 하나씩,',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '내 페이스로 복습을 시작해 보세요.',
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 32),
                    _SummaryCard(
                      colorScheme: colorScheme,
                      statistics: statistics,
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          key: const Key('start-study-button'),
                          onPressed: () => context.push(AppRoutes.studySetup),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('문제 풀기'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('recent-wrong-button'),
                          onPressed: () => context.go(AppRoutes.statistics),
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('최근 오답'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Text(
                      '최근 학습',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Row(
                          children: [
                            Icon(
                              Icons.history_rounded,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: statistics.when(
                                loading: () => const LinearProgressIndicator(),
                                error: (error, stackTrace) =>
                                    const Text('학습 기록을 불러오지 못했어요.'),
                                data: (summary) => Text(
                                  summary.lastAnsweredAt == null
                                      ? '아직 학습 기록이 없어요.'
                                      : '지금까지 ${summary.totalAttemptCount}문제를 풀었어요.',
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.colorScheme, required this.statistics});

  final ColorScheme colorScheme;
  final AsyncValue<StatisticsSummary> statistics;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Expanded(
              child: _SummaryValue(
                label: '오늘 푼 문제',
                value: statistics.value == null
                    ? '0'
                    : '${statistics.value!.todayAttemptCount}',
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 56, child: VerticalDivider()),
            Expanded(
              child: _SummaryValue(
                label: '최근 정답률',
                value:
                    statistics.value == null ||
                        statistics.value!.last7Days.maxScore == 0
                    ? '-'
                    : '${statistics.value!.last7Days.accuracyPercent}%',
                color: colorScheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(color: color, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }
}
