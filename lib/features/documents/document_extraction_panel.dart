import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/core/documents/document_job_coordinator.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/document_extraction.dart';
import 'package:review_platform/shared/widgets/app_action_group.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/features/documents/document_job_delete_button.dart';

/// Upload is durable and idle until the user explicitly starts direct extraction.
class DocumentExtractionPanel extends ConsumerStatefulWidget {
  const DocumentExtractionPanel({
    required this.jobId,
    this.initialError,
    this.onDeleted,
    super.key,
  });
  final String jobId;
  final String? initialError;
  final VoidCallback? onDeleted;
  @override
  ConsumerState<DocumentExtractionPanel> createState() =>
      _DocumentExtractionPanelState();
}

class _DocumentExtractionPanelState
    extends ConsumerState<DocumentExtractionPanel> {
  PdfExtractionOverview? _overview;
  PdfExtractionPreflight? _check;
  Object? _error;
  bool _busy = false, _acknowledged = false;
  int _revision = 0;
  final Set<int> _boundaries = {};
  DocumentJobCoordinator get _coordinator =>
      ref.read(documentJobCoordinatorProvider) ??
      (throw const NetworkFailure('PDF 처리 서버에 연결할 수 없어요.'));

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final overview = await _coordinator.extractionOverview(widget.jobId);
      if (!mounted) return;
      setState(() {
        // Refresh keeps user's in-progress choices. Persisted checks initialize
        // a newly opened screen; a refresh invalidates them if the model changed.
        if (_overview == null) {
          _boundaries.addAll(overview.boundaries);
          _check = overview.preflight;
        } else if (_overview!.model != overview.model ||
            _overview!.revision != overview.revision) {
          _check = null;
          _acknowledged = false;
        }
        _overview = overview;
        _revision = overview.revision;
        _error = widget.initialError;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, Object?> get _selection => {
    'mode': 'direct',
    'splitAfterPages': _boundaries.toList()..sort(),
    'acknowledgeWarnings': _acknowledged,
    'revision': _revision,
  };

  void _changed(VoidCallback update) => setState(() {
    update();
    _check = null;
    _acknowledged = false;
    _error = null;
  });

  Future<void> _checkInput() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await _coordinator.preflight(widget.jobId, _selection);
      if (mounted) {
        setState(() {
          _check = check;
          _revision = check.revision;
          _acknowledged = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _coordinator.startExtraction(widget.jobId, _selection);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    if (overview == null) {
      return Center(
        child: _busy
            ? const CircularProgressIndicator()
            : AppErrorNotice(
                error: _error ?? 'PDF 개요를 불러오지 못했어요.',
                onRetry: _load,
              ),
      );
    }
    final allowDirect = overview.provider == 'openai';
    final canStart =
        !_busy &&
        allowDirect &&
        _check != null &&
        _check!.canStart &&
        (_check!.status == 'ready' || _acknowledged);
    return ListView(
      key: const Key('pdf-extraction-scroll'),
      padding: AppLayout.pagePadding(context),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.readingWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'PDF 추출 설정',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          overview.fileName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${overview.pageCount}페이지 · ${(overview.fileSize / (1024 * 1024)).toStringAsFixed(2)} MB',
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '개념 추출 모델: ${overview.provider} · ${overview.model}',
                        ),
                        const Text(
                          '파일은 보관되며, 업로드만으로 개념 추출을 시작하지 않습니다. 사전 점검 시에는 토큰 계산 API를 호출합니다.',
                        ),
                        const Divider(),
                        const Text('PDF를 모델에 직접 전달해 개념을 추출합니다.'),
                        if (!allowDirect)
                          const AppErrorNotice(
                            error: '설정 > LLM에서 PDF 개념 추출에 OpenAI PDF 입력 지원 모델을 지정해 주세요.',
                          ),
                        ...[
                          const Divider(),
                          Text(
                            '분할 지점 선택',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            '개념이 이어지는 페이지는 같은 묶음으로 유지하세요. 자동으로 자르지 않으며, 선택한 각 묶음을 순서대로 요청합니다.',
                          ),
                          PdfOriginalPreview(
                            jobId: widget.jobId,
                            pageCount: overview.pageCount,
                            boundaries: _boundaries,
                            enabled: !_busy,
                            onBoundaryChanged: (page, selected) => _changed(() {
                              if (selected) {
                                _boundaries.add(page);
                              } else {
                                _boundaries.remove(page);
                              }
                            }),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            '요청 범위: ${_ranges(overview.pageCount, _boundaries)}',
                          ),
                          if (_boundaries.isNotEmpty)
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _changed(_boundaries.clear),
                              icon: const Icon(Icons.clear_all_rounded),
                              label: const Text('분할 지점 초기화'),
                            ),
                          const Divider(),
                          const Text(
                            '사전 점검은 PDF 입력 토큰 수를 계산합니다. 파일 크기·컨텍스트·출력 예산·TPM을 확인하지만, 다른 API 사용량과 실제 개념 출력 분량까지 보장하지는 않습니다.',
                          ),
                          if (_check != null) _PreflightResult(check: _check!),
                          if (_check != null &&
                              _check!.canStart &&
                              _check!.status != 'ready')
                            CheckboxListTile(
                              key: const Key('pdf-risk-acknowledgement'),
                              title: const Text('경고와 불확실성을 확인했으며 진행합니다.'),
                              value: _acknowledged,
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(
                                      () => _acknowledged = value ?? false,
                                    ),
                            ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: AppSpacing.md),
                          AppErrorNotice(error: _error!, onRetry: _load),
                        ],
                        if (_busy) ...[
                          const SizedBox(height: AppSpacing.md),
                          const LinearProgressIndicator(),
                          const Text('요청 처리 중… 화면을 나가도 업로드한 파일은 보관됩니다.'),
                        ],
                        const SizedBox(height: AppSpacing.md),
                        AppActionGroup(
                          children: [
                            OutlinedButton.icon(
                              key: const Key('pdf-preflight'),
                              onPressed: _busy || !allowDirect
                                  ? null
                                  : _checkInput,
                              icon: const Icon(Icons.fact_check_outlined),
                              label: Text(
                                _check == null ? '입력 사전 점검' : '다시 점검',
                              ),
                            ),
                            FilledButton.icon(
                              key: const Key('pdf-start-extraction'),
                              onPressed: canStart ? _start : null,
                              icon: const Icon(Icons.auto_awesome_outlined),
                              label: const Text('추출 시작'),
                            ),
                          ],
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('개요 새로고침'),
                        ),
                        if (widget.onDeleted != null)
                          DocumentJobDeleteButton(
                            jobId: widget.jobId,
                            fileName: overview.fileName,
                            enabled: !_busy,
                            onDeleted: widget.onDeleted!,
                            onBusyChanged: (busy) {
                              if (mounted) setState(() => _busy = busy);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _ranges(int pages, Set<int> boundaries) {
  var first = 1;
  return [...boundaries.toList()..sort(), pages]
      .map((last) {
        final label = first == last ? 'p.$first' : 'p.$first–$last';
        first = last + 1;
        return label;
      })
      .join(' / ');
}

class _PreflightResult extends StatelessWidget {
  const _PreflightResult({required this.check});
  final PdfExtractionPreflight check;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: AppSpacing.md),
      Text(
        '점검 결과 · ${switch (check.status) {
          'ready' => '진행 가능',
          'blocked' => '분할 필요',
          'waiting' => '한도 회복 대기',
          'unknown' => '확인 불가',
          _ => '주의 필요',
        }}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      for (final part in check.parts) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          'p.${(part['range']! as Map)['firstPage']}–${(part['range']! as Map)['lastPage']} · 입력 ${part['inputTokens'] ?? '미확인'} 토큰',
        ),
        Text(
          '출력 상한 ${part['outputBudget']} 토큰 (추론 포함) · 예상 출력 ${part['estimatedOutputTokens']} 토큰 (페이지 기반 추정)',
        ),
        for (final message in (part['messages']! as List)) Text('• $message'),
      ],
    ],
  );
}

class PdfOriginalPreview extends ConsumerStatefulWidget {
  const PdfOriginalPreview({
    required this.jobId,
    required this.pageCount,
    this.boundaries,
    this.onBoundaryChanged,
    this.enabled = true,
    super.key,
  });
  final String jobId;
  final int pageCount;
  final Set<int>? boundaries;
  final void Function(int page, bool selected)? onBoundaryChanged;
  final bool enabled;
  @override
  ConsumerState<PdfOriginalPreview> createState() => _PdfOriginalPreviewState();
}

class _PdfOriginalPreviewState extends ConsumerState<PdfOriginalPreview> {
  int _page = 1;
  late Future<Uint8List> _image;
  late final TextEditingController _pageInput;
  @override
  void initState() {
    super.initState();
    _pageInput = TextEditingController(text: '1');
    _load();
  }

  @override
  void dispose() {
    _pageInput.dispose();
    super.dispose();
  }

  void _load() {
    _image = Future.sync(
      () =>
          (ref.read(documentJobCoordinatorProvider) ??
                  (throw const NetworkFailure('원본 PDF 서버에 연결할 수 없어요.')))
              .extractionImage(widget.jobId, _page),
    );
  }

  void _go(int page) {
    setState(() {
      _page = page.clamp(1, widget.pageCount);
      _pageInput.text = '$_page';
      _load();
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: AppSpacing.md),
      SizedBox(
        height: 340,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: FutureBuilder<Uint8List>(
            future: _image,
            builder: (context, state) {
              if (state.hasError) {
                return Center(
                  child: SingleChildScrollView(
                    child: AppErrorNotice(
                      error: state.error!,
                      onRetry: () => setState(_load),
                    ),
                  ),
                );
              }
              if (!state.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return InteractiveViewer(
                child: Image.memory(
                  state.data!,
                  fit: BoxFit.contain,
                  semanticLabel: 'PDF 원본 $_page페이지',
                  errorBuilder: (context, error, stack) => AppErrorNotice(
                    error: '원본 이미지를 표시하지 못했어요.',
                    onRetry: () => setState(_load),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      TextFormField(
        controller: _pageInput,
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: '원본 페이지 (전체 ${widget.pageCount}페이지)',
          suffixIcon: IconButton(
            tooltip: '입력한 페이지로 이동',
            onPressed: widget.enabled
                ? () => _go(int.tryParse(_pageInput.text) ?? _page)
                : null,
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
        ),
        onFieldSubmitted: (value) => _go(int.tryParse(value) ?? _page),
      ),
      const SizedBox(height: AppSpacing.sm),
      AppActionGroup(
        children: [
          OutlinedButton.icon(
            onPressed: widget.enabled && _page > 1
                ? () => _go(_page - 1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
            label: const Text('이전 페이지'),
          ),
          OutlinedButton.icon(
            onPressed: widget.enabled && _page < widget.pageCount
                ? () => _go(_page + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
            label: const Text('다음 페이지'),
          ),
        ],
      ),
      if (widget.onBoundaryChanged != null)
        CheckboxListTile(
          key: const Key('pdf-split-boundary'),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('$_page페이지 뒤에서 분할'),
          subtitle: Text(
            _page == widget.pageCount
                ? '마지막 페이지 뒤에는 분할할 수 없어요.'
                : '다음 묶음은 ${_page + 1}페이지부터 시작합니다.',
          ),
          value: widget.boundaries?.contains(_page) ?? false,
          onChanged: widget.enabled && _page < widget.pageCount
              ? (value) => widget.onBoundaryChanged!(_page, value ?? false)
              : null,
        ),
    ],
  );
}
