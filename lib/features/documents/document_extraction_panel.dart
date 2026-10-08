import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
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
  final _splitPageInput = TextEditingController(text: '1');
  String? _splitError;
  DocumentJobCoordinator get _coordinator =>
      ref.read(documentJobCoordinatorProvider) ??
      (throw const NetworkFailure('PDF 처리 서버에 연결할 수 없어요.'));

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
    _load();
  }

  @override
  void dispose() {
    _splitPageInput.dispose();
    super.dispose();
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

  void _changed(VoidCallback update) {
    if (_busy) return;
    setState(() {
      update();
      _check = null;
      _acknowledged = false;
      _error = null;
      _splitError = null;
    });
    if (_overview?.provider == 'openai') unawaited(_checkInput());
  }

  void _addBoundary() {
    if (_busy) return;
    final page = int.tryParse(_splitPageInput.text.trim());
    if (page == null || page < 1 || page >= _overview!.pageCount) {
      setState(
        () => _splitError = '1–${_overview!.pageCount - 1}페이지를 입력해 주세요.',
      );
      return;
    }
    if (_boundaries.contains(page)) {
      setState(() => _splitError = '이미 추가한 분할 지점이에요.');
      return;
    }
    _changed(() => _boundaries.add(page));
  }

  Future<void> _checkInput() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _check = null;
      _acknowledged = false;
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
                        if (!allowDirect)
                          const AppErrorNotice(
                            error: '설정 > LLM에서 PDF 개념 추출에 OpenAI PDF 입력 지원 모델을 지정해 주세요.',
                          ),
                        ...[
                          const Divider(),
                          Text(
                            '분할 지점',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            '개념이 이어지는 페이지는 같은 묶음으로 유지하세요. 자동으로 자르지 않으며, 선택한 각 묶음을 순서대로 요청합니다.',
                          ),
                          PdfOriginalPreview(
                            jobId: widget.jobId,
                            pageCount: overview.pageCount,
                            onPageChanged: (page) {
                              if (!_busy) _splitPageInput.text = '$page';
                            },
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          if (overview.pageCount > 1)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    key: const Key('pdf-split-page-input'),
                                    controller: _splitPageInput,
                                    enabled: !_busy,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: '분할할 페이지 뒤',
                                      errorText: _splitError,
                                    ),
                                    onFieldSubmitted: (_) => _addBoundary(),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                IconButton(
                                  key: const Key('pdf-add-split'),
                                  tooltip: '분할 지점 추가',
                                  onPressed: _busy ? null : _addBoundary,
                                  icon: const Icon(Icons.add_rounded),
                                ),
                              ],
                            ),
                          if (_boundaries.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: AppSpacing.sm,
                              ),
                              child: Text('분할 지점 없음 · 전체 PDF를 한 번에 요청합니다.'),
                            ),
                          for (final page in _boundaries.toList()..sort())
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('$page페이지 뒤에서 분할'),
                              trailing: IconButton(
                                key: Key('pdf-remove-split-$page'),
                                tooltip: '$page페이지 분할 지점 삭제',
                                onPressed: _busy
                                    ? null
                                    : () => _changed(
                                        () => _boundaries.remove(page),
                                      ),
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                            ),
                          Text(
                            '요청 범위: ${_ranges(overview.pageCount, _boundaries)}',
                          ),
                          const Divider(),
                          const Text(
                            '사전 점검은 입력 토큰과 기술적 한도를 확인합니다. 출력 분량은 과거 실측으로 추정하며, 분할 권장 기준은 강제 종료 한도가 아닙니다. 다른 API 사용량과 실제 출력 분량은 보장하지 않습니다.',
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
                          AppErrorNotice(error: _error!, onRetry: _checkInput),
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
        _PdfTokenSummary(part: part),
        for (final message in (part['messages']! as List)) Text('• $message'),
      ],
    ],
  );
}

class _PdfTokenSummary extends StatelessWidget {
  const _PdfTokenSummary({required this.part});
  final Map<String, Object?> part;

  String _tokens(Object? value) => (value! as num)
      .toInt()
      .toString()
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

  @override
  Widget build(BuildContext context) {
    final estimate = part['outputEstimate'] as Map?;
    final tokens = estimate?['tokens'] ?? part['estimatedOutputTokens'];
    final samples = estimate?['sampleCount'] ?? 0;
    final confidence = estimate?['confidence'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tokens == null
              ? '예상 출력: 예측 자료 부족 · 정상 완료 표본 $samples/5개'
              : '예상 출력: 약 ${_tokens(tokens)}토큰 · ${confidence == 'low'
                    ? '신뢰도 낮음'
                    : estimate == null
                    ? '이전 페이지 기반 추정'
                    : '실측 기반'}',
        ),
        if (estimate?['lowerTokens'] != null &&
            estimate?['upperTokens'] != null)
          Text(
            '실측 환산 범위: ${_tokens(estimate!['lowerTokens'])}–${_tokens(estimate['upperTokens'])}토큰 · 표본 $samples개 · 보장 범위 아님',
          ),
        Text(
          '분할 권장 기준: ${_tokens(part['outputSafetyThresholdTokens'] ?? 64000)}토큰 · 강제 종료하지 않음',
        ),
        Text(
          part['outputBudget'] == null
              ? 'API 출력 한도: 미등록 · 지원 정보가 등록된 모델을 선택해 주세요.'
              : 'API 출력 한도: ${_tokens(part['outputBudget'])}토큰 · 추론 포함',
        ),
      ],
    );
  }
}

class PdfOriginalPreview extends ConsumerStatefulWidget {
  const PdfOriginalPreview({
    required this.jobId,
    required this.pageCount,
    this.onPageChanged,
    this.enabled = true,
    super.key,
  });
  final String jobId;
  final int pageCount;
  final ValueChanged<int>? onPageChanged;
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
    if (!widget.enabled) return;
    final target = page.clamp(1, widget.pageCount);
    if (target == _page) {
      _pageInput.text = '$_page';
      return;
    }
    setState(() {
      _page = target;
      _pageInput.text = '$_page';
      _load();
    });
    widget.onPageChanged?.call(_page);
  }

  void _scrollPage(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    // Claim the wheel event so the surrounding settings do not scroll too.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _go(_page + (event.scrollDelta.dy > 0 ? 1 : -1));
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: AppSpacing.md),
      SizedBox(
        height: 340,
        child: Listener(
          key: const Key('pdf-preview-wheel'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _scrollPage,
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
                if (state.connectionState != ConnectionState.done ||
                    !state.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Image.memory(
                  key: ValueKey('pdf-preview-page-$_page'),
                  state.data!,
                  fit: BoxFit.contain,
                  semanticLabel: 'PDF 원본 $_page페이지',
                  errorBuilder: (context, error, stack) => AppErrorNotice(
                    error: '원본 이미지를 표시하지 못했어요.',
                    onRetry: () => setState(_load),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      Row(
        children: [
          IconButton(
            key: const Key('pdf-previous-page'),
            tooltip: '이전 페이지',
            onPressed: widget.enabled && _page > 1
                ? () => _go(_page - 1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          IconButton(
            key: const Key('pdf-next-page'),
            tooltip: '다음 페이지',
            onPressed: widget.enabled && _page < widget.pageCount
                ? () => _go(_page + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextFormField(
              key: const Key('pdf-page-input'),
              controller: _pageInput,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '페이지로 이동',
                helperText: '전체 ${widget.pageCount}페이지',
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
          ),
        ],
      ),
    ],
  );
}
