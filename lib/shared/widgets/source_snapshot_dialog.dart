import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/core/documents/source_snapshot_service.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

Future<void> showSourceSnapshots(
  BuildContext context, {
  required String sourceId,
  required List<int> pages,
}) {
  final ordered = pages.where((page) => page > 0).toSet().toList()..sort();
  if (ordered.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (_) => _SourceSnapshotDialog(sourceId: sourceId, pages: ordered),
  );
}

class _SourceSnapshotDialog extends ConsumerStatefulWidget {
  const _SourceSnapshotDialog({required this.sourceId, required this.pages});
  final String sourceId;
  final List<int> pages;
  @override
  ConsumerState<_SourceSnapshotDialog> createState() =>
      _SourceSnapshotDialogState();
}

class _SourceSnapshotDialogState extends ConsumerState<_SourceSnapshotDialog> {
  late Future<StudySource> _source;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _source = ref
        .read(sourceRepositoryProvider)
        .getSourceWithConcepts(widget.sourceId)
        .then((value) => value.source);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 600;
    final content = SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: FutureBuilder<StudySource>(
          future: _source,
          builder: (context, state) => Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Tooltip(
                      message: state.data?.fileName ?? '원본 슬라이드',
                      child: Text(
                        state.data?.fileName ?? '원본 슬라이드',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('source-snapshot-close'),
                    tooltip: '원본 보기 닫기',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: state.hasError
                    ? Center(
                        child: SingleChildScrollView(
                          child: AppErrorNotice(
                            error: state.error!,
                            onRetry: () => setState(_load),
                          ),
                        ),
                      )
                    : state.connectionState != ConnectionState.done ||
                          !state.hasData
                    ? const Center(child: CircularProgressIndicator())
                    : _SourcePagesViewer(
                        source: state.data!,
                        pages: widget.pages,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    return compact
        ? Dialog.fullscreen(
            key: const Key('source-snapshot-dialog'),
            child: content,
          )
        : Dialog(
            key: const Key('source-snapshot-dialog'),
            child: SizedBox(
              width: AppLayout.managementWidth,
              height: size.height * 0.85,
              child: content,
            ),
          );
  }
}

class _SourcePagesViewer extends ConsumerStatefulWidget {
  const _SourcePagesViewer({required this.source, required this.pages});
  final StudySource source;
  final List<int> pages;
  @override
  ConsumerState<_SourcePagesViewer> createState() => _SourcePagesViewerState();
}

class _SourcePagesViewerState extends ConsumerState<_SourcePagesViewer> {
  int _index = 0;
  double _scale = 1;
  double _gestureStartScale = 1;
  Offset _offset = Offset.zero;
  late Future<Uint8List> _image;
  late final TransformationController _transform;

  int get _page => widget.pages[_index];
  @override
  void initState() {
    super.initState();
    _transform = TransformationController();
    _load();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _load({bool refresh = false}) {
    _image = ref
        .read(sourceSnapshotServiceProvider)
        .page(widget.source, _page, refresh: refresh);
  }

  void _retry() => setState(() {
    _load(refresh: true);
  });

  void _go(int index) {
    if (index < 0 || index >= widget.pages.length || index == _index) return;
    setState(() {
      _index = index;
      _resetZoom();
      _load();
    });
  }

  void _resetZoom() {
    _scale = 1;
    _gestureStartScale = 1;
    _offset = Offset.zero;
    _transform.value = Matrix4.identity();
  }

  void _zoom(double factor) => setState(() {
    _scale = (_scale * factor).clamp(1, 4);
    _transform.value = Matrix4.identity()
      ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
      ..scaleByDouble(_scale, _scale, 1, 1);
  });
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _go(_index + (event.scrollDelta.dy > 0 ? 1 : -1));
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: Listener(
          key: const Key('source-snapshot-wheel'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _wheel,
          child: ClipRect(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: FutureBuilder<Uint8List>(
                future: _image,
                builder: (context, state) {
                  if (state.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state.hasError) {
                    return Center(
                      child: SingleChildScrollView(
                        child: AppErrorNotice(
                          error: state.error!,
                          onRetry: _retry,
                        ),
                      ),
                    );
                  }
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Wheel navigation and zoom are separate. Pinch/drag are
                    // touch gestures; icon actions also make zoom usable on PC.
                    onScaleStart: (_) {
                      _gestureStartScale = _scale;
                      _offset = Offset(
                        _transform.value.storage[12],
                        _transform.value.storage[13],
                      );
                    },
                    onScaleUpdate: (details) {
                      _offset += details.focalPointDelta;
                      _scale = (_gestureStartScale * details.scale).clamp(1, 4);
                      _transform.value = Matrix4.identity()
                        ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                        ..scaleByDouble(_scale, _scale, 1, 1);
                    },
                    onScaleEnd: (_) => setState(() {}),
                    child: AnimatedBuilder(
                      animation: _transform,
                      builder: (context, child) => Transform(
                        transform: _transform.value,
                        alignment: Alignment.center,
                        child: child,
                      ),
                      child: Center(
                        child: Image.memory(
                          state.data!,
                          fit: BoxFit.contain,
                          semanticLabel: 'PDF 원본 $_page페이지',
                          errorBuilder: (_, _, _) => AppErrorNotice(
                            error: '원본 이미지를 표시하지 못했어요.',
                            onRetry: _retry,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        spacing: AppSpacing.sm,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('source-snapshot-previous'),
                tooltip: '이전 출처 페이지',
                onPressed: _index > 0 ? () => _go(_index - 1) : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton(
                key: const Key('source-snapshot-next'),
                tooltip: '다음 출처 페이지',
                onPressed: _index < widget.pages.length - 1
                    ? () => _go(_index + 1)
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          Text(
            'p.$_page · 출처 ${_index + 1}/${widget.pages.length}',
            key: const Key('source-snapshot-page'),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '축소',
                onPressed: _scale > 1 ? () => _zoom(1 / 1.25) : null,
                icon: const Icon(Icons.zoom_out_rounded),
              ),
              IconButton(
                tooltip: '확대',
                onPressed: _scale < 4 ? () => _zoom(1.25) : null,
                icon: const Icon(Icons.zoom_in_rounded),
              ),
              IconButton(
                tooltip: '원래 크기로',
                onPressed: () => setState(_resetZoom),
                icon: const Icon(Icons.fit_screen_rounded),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
