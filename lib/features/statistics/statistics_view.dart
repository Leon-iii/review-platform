import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/statistics_summary.dart';
import 'package:review_platform/features/statistics/statistics_view_model.dart';

class StatisticsView extends ConsumerWidget {
  const StatisticsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statistics = ref.watch(statisticsProvider);

    return Scaffold(
      key: const Key('statistics-view'),
      appBar: AppBar(title: const Text('통계')),
      body: statistics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error is AppFailure ? error.message : '통계를 불러오지 못했어요.'),
          ),
        ),
        data: (summary) => _StatisticsContent(summary: summary),
      ),
    );
  }
}

class _StatisticsContent extends StatelessWidget {
  const _StatisticsContent({required this.summary});

  final StatisticsSummary summary;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Overview(summary: summary),
                const SizedBox(height: 28),
                Text('기간별 정답률', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                _AccuracyRow(label: '최근 7일', metric: summary.last7Days),
                const SizedBox(height: 12),
                _AccuracyRow(label: '최근 30일', metric: summary.last30Days),
                const SizedBox(height: 28),
                Text('폴더별 정답률', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (summary.folderStatistics.isEmpty)
                  const _EmptyCard(message: '아직 폴더별 학습 기록이 없어요.')
                else
                  for (final folder in summary.folderStatistics)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _FolderAccuracy(folder: folder),
                    ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '최근 오답',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (summary.recentWrongQuestions.isNotEmpty)
                      Text('${summary.recentWrongQuestions.length}문제'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '각 문제의 가장 최근 풀이가 오답인 경우만 표시합니다.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (summary.recentWrongQuestions.isEmpty)
                  const _EmptyCard(message: '현재 다시 풀 오답이 없어요.')
                else
                  for (final wrong in summary.recentWrongQuestions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _RecentWrongCard(wrong: wrong),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.summary});

  final StatisticsSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        child: Row(
          children: [
            Expanded(
              child: _OverviewValue(
                label: '전체 문제',
                value: '${summary.totalQuestionCount}',
              ),
            ),
            const SizedBox(height: 56, child: VerticalDivider()),
            Expanded(
              child: _OverviewValue(
                label: '전체 풀이',
                value: '${summary.totalAttemptCount}',
              ),
            ),
            const SizedBox(height: 56, child: VerticalDivider()),
            Expanded(
              child: _OverviewValue(
                label: '전체 정답률',
                value: summary.total.maxScore == 0
                    ? '-'
                    : '${summary.total.accuracyPercent}%',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewValue extends StatelessWidget {
  const _OverviewValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }
}

class _AccuracyRow extends StatelessWidget {
  const _AccuracyRow({required this.label, required this.metric});

  final String label;
  final AccuracyMetric metric;

  @override
  Widget build(BuildContext context) {
    final hasAttempts = metric.maxScore > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            SizedBox(width: 76, child: Text(label)),
            Expanded(
              child: LinearProgressIndicator(
                value: hasAttempts ? metric.score / metric.maxScore : 0,
                minHeight: 10,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 44,
              child: Text(
                hasAttempts ? '${metric.accuracyPercent}%' : '-',
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderAccuracy extends StatelessWidget {
  const _FolderAccuracy({required this.folder});

  final FolderStatistics folder;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 10),
                Expanded(child: Text(folder.folderName)),
                Text('${folder.accuracyPercent}% · ${folder.attemptCount}회'),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: folder.maxScore == 0 ? 0 : folder.score / folder.maxScore,
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentWrongCard extends StatelessWidget {
  const _RecentWrongCard({required this.wrong});

  final RecentWrongQuestion wrong;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.cancel_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(wrong.attempt.questionSnapshot.prompt),
        subtitle: Text(
          '${wrong.folderName} · ${_formatDate(wrong.attempt.answeredAt)}',
        ),
        trailing: IconButton(
          tooltip: '이 폴더의 최근 오답 풀기',
          onPressed: wrong.folderId.isEmpty
              ? null
              : () =>
                    context.push(AppRoutes.studySetupForWrong(wrong.folderId)),
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      ),
    );
  }

  String _formatDate(DateTime value) {
    final date = value.toLocal();
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
