import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';

class DocumentJobPanel extends ConsumerStatefulWidget {
  const DocumentJobPanel({
    required this.jobId,
    required this.onReady,
    required this.onUploadAgain,
    super.key,
  });
  final String jobId;
  final ValueChanged<String> onReady;
  final VoidCallback onUploadAgain;
  @override
  ConsumerState<DocumentJobPanel> createState() => _DocumentJobPanelState();
}

class _DocumentJobPanelState extends ConsumerState<DocumentJobPanel> {
  bool _busy = false;
  bool _opened = false;
  Future<void> _change(String action) async {
    setState(() => _busy = true);
    try {
      final coordinator = ref.read(documentJobCoordinatorProvider);
      if (coordinator == null) {
        throw const NetworkFailure('PDF 작업 서버에 연결할 수 없어요.');
      }
      await coordinator.change(widget.jobId, action);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is AppFailure ? error.message : '작업 요청을 전송하지 못했어요.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(documentJobProvider(widget.jobId));
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('PDF 작업 상태를 불러오지 못했어요.')),
      data: (row) {
        if (row == null) {
          return const Center(child: Text('PDF 분석 작업을 찾을 수 없어요.'));
        }
        if (row.applied && !_opened) {
          _opened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onReady(row.id);
          });
        }
        final job = row.job;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          job.fileName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(job.statusLabel),
                        const SizedBox(height: 12),
                        if (job.isActive ||
                            job.status == 'uploading' ||
                            job.status == 'completed')
                          LinearProgressIndicator(
                            key: const Key('pdf-import-progress'),
                            value: job.status == 'completed' ? 1 : job.progress,
                          ),
                        if (job.totalPages > 0) ...[
                          const SizedBox(height: 8),
                          Text(job.progressLabel),
                        ],
                        const SizedBox(height: 12),
                        const Text(
                          '화면을 나가도 서버에서 분석을 계속합니다. 서버가 다시 켜지면 완료한 지점부터 이어갑니다.',
                        ),
                        if (job.data['visionModel'] is String) ...[
                          const SizedBox(height: 8),
                          Text(
                            'OCR: ${job.data['visionModel']} · 개념 추출: ${job.data['conceptModel']}',
                          ),
                        ],
                        if (job.error != null) ...[
                          const SizedBox(height: 12),
                          Text(job.error!),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            if (job.isActive)
                              OutlinedButton(
                                key: const Key('cancel-pdf-job'),
                                onPressed: _busy
                                    ? null
                                    : () => _change('cancel'),
                                child: const Text('분석 취소'),
                              ),
                            if (job.canRetry)
                              FilledButton(
                                key: const Key('retry-pdf-job'),
                                onPressed: _busy
                                    ? null
                                    : () => _change('retry'),
                                child: const Text('완료한 지점부터 재시도'),
                              ),
                            if (job.status == 'uploadFailed')
                              FilledButton(
                                onPressed: _busy ? null : widget.onUploadAgain,
                                child: const Text('PDF 다시 선택'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
