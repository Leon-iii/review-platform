import 'package:review_platform/shared/widgets/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

/// Pending PDF job actions, including obsolete analysis jobs.
class DocumentJobDeleteButton extends ConsumerStatefulWidget {
  const DocumentJobDeleteButton({
    required this.jobId,
    required this.fileName,
    this.menu = false,
    this.enabled = true,
    this.deleteEnabled = true,
    this.onMove,
    this.onDeleted,
    this.onBusyChanged,
    super.key,
  });

  final String jobId;
  final String fileName;
  final bool menu;
  final bool enabled;
  final bool deleteEnabled;
  final Future<void> Function()? onMove;
  final VoidCallback? onDeleted;
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<DocumentJobDeleteButton> createState() =>
      _DocumentJobDeleteButtonState();
}

class _DocumentJobDeleteButtonState
    extends ConsumerState<DocumentJobDeleteButton> {
  bool _busy = false;
  bool _moving = false;

  Future<void> _move() async {
    if (_busy || _moving || widget.onMove == null) return;
    // The folder picker is interactive; disable duplicate menu actions without
    // showing a perpetual loading animation while awaiting the user's choice.
    setState(() => _moving = true);
    try {
      await widget.onMove!();
    } catch (error) {
      if (mounted) showAppError(context, error, fallback: 'PDF 작업을 이동하지 못했어요.');
    } finally {
      if (mounted) {
        setState(() => _moving = false);
      }
    }
  }

  Future<void> _delete() async {
    if (_busy || _moving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: const Text('PDF 작업 삭제'),
        content: Text(
          '“${widget.fileName}” 작업을 삭제할까요?\n'
          '진행 중인 분석을 중단하고 서버의 원본 PDF와 이 작업의 OCR·검토 내용을 삭제합니다. '
          '이 작업은 되돌릴 수 없으며, 다시 분석하려면 PDF를 새로 업로드해야 합니다.',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-delete-pdf-job'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('confirm-delete-pdf-job'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    widget.onBusyChanged?.call(true);
    try {
      final coordinator = ref.read(documentJobCoordinatorProvider);
      if (coordinator == null) {
        throw const NetworkFailure('PDF 작업 서버에 연결할 수 없어요.');
      }
      await coordinator.delete(widget.jobId);
      if (mounted) widget.onDeleted?.call();
    } catch (error) {
      if (mounted) {
        showAppError(context, error, fallback: 'PDF 작업을 삭제하지 못했어요.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (widget.menu) {
      return PopupMenuButton<String>(
        key: Key('pdf-job-menu-${widget.jobId}'),
        tooltip: 'PDF 작업 메뉴',
        enabled: widget.enabled && !_moving,
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (action) => action == 'move' ? _move() : _delete(),
        itemBuilder: (_) => [
          if (widget.onMove != null)
            const PopupMenuItem(value: 'move', child: Text('이동')),
          PopupMenuItem(
            value: 'delete',
            enabled: widget.deleteEnabled,
            child: const Text('삭제'),
          ),
        ],
      );
    }
    return OutlinedButton.icon(
      key: const Key('delete-pdf-job'),
      onPressed: widget.enabled ? _delete : null,
      icon: const Icon(Icons.delete_outline_rounded),
      label: const Text('PDF 작업 삭제'),
    );
  }
}
