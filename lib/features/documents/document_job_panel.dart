import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/features/documents/document_ocr_review_view.dart';
import 'package:review_platform/features/documents/document_job_delete_button.dart';

class DocumentJobPanel extends ConsumerStatefulWidget {
  const DocumentJobPanel({
    required this.jobId,
    required this.onReady,
    required this.onUploadAgain,
    required this.onDeleted,
    super.key,
  });
  final String jobId;
  final ValueChanged<String> onReady;
  final VoidCallback onUploadAgain;
  final VoidCallback onDeleted;
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
        showAppError(context, error, fallback: '작업 요청을 전송하지 못했어요.');
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
      error: (error, _) => Center(
        child: AppErrorNotice(
          error: error,
          fallback: 'PDF 작업 상태를 불러오지 못했어요.',
          onRetry: () => ref.invalidate(documentJobProvider(widget.jobId)),
        ),
      ),
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
                        Text(
                          job.isAwaitingReview
                              ? 'OCR 검토를 기다리고 있어요. 검토 내용을 확정하기 전에는 개념 추출을 시작하지 않습니다. 화면을 나가거나 서버를 재시작해도 검토 내용은 보관됩니다.'
                              : '화면을 나가도 서버에서 분석을 계속합니다. 서버가 다시 켜지면 완료한 지점부터 이어갑니다.',
                        ),
                        if (job.data['visionModel'] is String) ...[
                          const SizedBox(height: 8),
                          Text(
                            'OCR: ${job.data['visionModel']} · 개념 추출: ${job.data['conceptModel']}',
                          ),
                        ],
                        if (job.error != null) ...[
                          const SizedBox(height: 12),
                          AppErrorNotice(error: job.error!),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            if (job.isAwaitingReview)
                              FilledButton.icon(
                                key: const Key('open-ocr-review'),
                                onPressed: _busy
                                    ? null
                                    : () => Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => DocumentOcrReviewView(
                                            jobId: job.id,
                                            fileName: job.fileName,
                                          ),
                                        ),
                                      ),
                                icon: const Icon(Icons.fact_check_outlined),
                                label: const Text('OCR 내용 검토'),
                              ),
                            if (job.isActive || job.isAwaitingReview)
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
                            if (!row.applied)
                              DocumentJobDeleteButton(
                                jobId: job.id,
                                fileName: job.fileName,
                                enabled: !_busy && job.status != 'uploading',
                                onDeleted: widget.onDeleted,
                                onBusyChanged: (busy) {
                                  if (mounted) setState(() => _busy = busy);
                                },
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
