import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show kDefaultMouseScrollToScaleFactor;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/documents/document_job_coordinator.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/document_ocr_review.dart';
import 'package:review_platform/features/documents/continuous_ocr_comparison.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

class DocumentOcrReviewView extends ConsumerStatefulWidget {
  const DocumentOcrReviewView({
    required this.jobId,
    required this.fileName,
    this.readOnly = false,
    super.key,
  });
  final String jobId;
  final String fileName;
  final bool readOnly;
  @override
  ConsumerState<DocumentOcrReviewView> createState() =>
      _DocumentOcrReviewViewState();
}

class _EditableBlock {
  _EditableBlock(OcrReviewBlock block)
    : controller = TextEditingController(text: block.text),
      independent = block.independent,
      excluded = block.excluded,
      visual = block.visualRegion,
      kind = block.kind;
  final TextEditingController controller;
  bool independent;
  bool excluded;
  final bool visual;
  OcrContentKind kind;
  OcrReviewBlock get value => OcrReviewBlock(
    text: controller.text,
    independent: independent,
    excluded: excluded,
    visualRegion: visual,
    kind: kind,
  );
}

class _DocumentOcrReviewViewState extends ConsumerState<DocumentOcrReviewView> {
  OcrReviewPage? _page;
  Uint8List? _image;
  Object? _error;
  Object? _imageError;
  bool _busy = false;
  bool _loading = true;
  bool _dirty = false;
  bool _allowPop = false;
  bool _showOriginal = true;
  final Map<int, Uint8List> _previewCache = {};
  final List<_EditableBlock> _blocks = [];
  final ScrollController _comparisonScroll = ScrollController();
  final _continuousKey = GlobalKey<ContinuousOcrComparisonState>();
  int? _archivePageNumber;

  bool get _continuousArchive =>
      defaultTargetPlatform == TargetPlatform.windows && _readOnly;
  int get _currentPageNumber => _continuousArchive
      ? _archivePageNumber ?? _page!.pageNumber
      : _page!.pageNumber;

  Future<void> _navigate(int number) async {
    if (_continuousArchive && _continuousKey.currentState != null) {
      _continuousKey.currentState!.jumpToPage(number);
    } else {
      await _load(number);
    }
  }

  bool get _isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  bool get _readOnly => widget.readOnly || (_page?.readOnly ?? false);

  DocumentJobCoordinator get _coordinator =>
      ref.read(documentJobCoordinatorProvider) ??
      (throw const NetworkFailure('PDF 작업 서버에 연결할 수 없어요.'));
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(1);
    });
  }

  @override
  void dispose() {
    _comparisonScroll.dispose();
    for (final block in _blocks) {
      block.controller.dispose();
    }
    super.dispose();
  }

  void _replaceBlocks(List<OcrReviewBlock> blocks) {
    for (final block in _blocks) {
      block.controller.dispose();
    }
    _blocks.clear();
    _blocks.addAll(blocks.map(_EditableBlock.new));
  }

  void _report(Object error) {
    if (!mounted) return;
    setState(() => _error = error);
    showAppError(context, error, fallback: 'OCR 검토 요청을 처리하지 못했어요.');
  }

  Future<void> _save() async {
    if (_readOnly || !_dirty || _page == null) return;
    final saved = await _coordinator.saveReviewPage(
      widget.jobId,
      _page!.pageNumber,
      _page!.revision,
      [for (final block in _blocks) block.value],
    );
    if (mounted) {
      setState(() {
        _page = saved;
        _dirty = false;
        _error = null;
      });
    }
  }

  Future<void> _load(int number, {bool saveCurrent = true}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _loading = true;
      _error = null;
    });
    try {
      if (saveCurrent) await _save();
      final page = await _coordinator.reviewPage(widget.jobId, number);
      if (!mounted) return;
      Uint8List? image;
      Object? imageError;
      try {
        image =
            _previewCache.remove(number) ??
            await _coordinator.reviewImage(widget.jobId, number);
        _previewCache[number] = image;
        if (_previewCache.length > 3) {
          _previewCache.remove(_previewCache.keys.first);
        }
      } catch (error) {
        imageError = error;
      }
      if (!mounted) return;
      setState(() {
        _page = page;
        _replaceBlocks(page.blocks);
        _dirty = false;
        _image = image;
        _imageError = imageError;
      });
      if (_comparisonScroll.hasClients) {
        _comparisonScroll.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _comparisonScroll.hasClients) {
          _comparisonScroll.jumpTo(0);
        }
      });
      if (imageError != null) {
        showAppError(context, imageError, fallback: 'PDF 페이지 이미지를 불러오지 못했어요.');
      }
    } catch (error) {
      _report(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveButton() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save();
    } catch (error) {
      _report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _ask(
    String title,
    String message, {
    String accept = '확인',
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(accept),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _reload() async {
    if (_busy) return;
    if (_continuousArchive && _continuousKey.currentState != null) {
      _continuousKey.currentState!.reloadCurrentPage();
      return;
    }
    if (_dirty && !await _ask('새로고침', '저장하지 않은 이 페이지의 수정을 버리고 서버 내용을 불러올까요?')) {
      return;
    }
    if (mounted) await _load(_page?.pageNumber ?? 1, saveCurrent: false);
  }

  Future<void> _reset() async {
    if (_readOnly || _page == null || _busy) return;
    if (!await _ask(
      '이 페이지 원문 복원',
      '이 페이지의 편집 내용을 원래 추출된 영역으로 되돌릴까요? 저장하면 서버 수정본에도 반영됩니다.',
    )) {
      return;
    }
    if (mounted) {
      setState(() {
        _replaceBlocks(_page!.originalBlocks);
        _dirty = true;
      });
    }
  }

  Future<void> _exit() async {
    if (_busy) return;
    if (_dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장하지 않은 수정이 있어요'),
          content: const Text('검토 대기 상태는 유지됩니다. 이 페이지의 수정 내용을 저장할까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('계속 편집'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('저장하지 않고 나가기'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('저장 후 나가기'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'save') {
        await _saveButton();
        if (!mounted || _dirty) return;
      }
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _confirm() async {
    if (_readOnly || _busy || _page == null) return;
    if (!await _ask(
      '개념 추출 시작',
      '현재 페이지의 수정도 저장합니다. 수정하지 않은 페이지는 추출 원문을 사용합니다. 확정하면 영역 편집을 종료하고 개념 추출을 시작합니다.',
      accept: '개념 추출 시작',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await _save();
      await _coordinator.confirmReview(widget.jobId, _page!.revision);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _busy = false;
        _allowPop = true;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _jump() async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => _OcrPageJumpDialog(
        current: _currentPageNumber,
        total: _page!.totalPages,
      ),
    );
    if (value != null && mounted) await _navigate(value);
  }

  void _split(int index) {
    if (_readOnly) return;
    final block = _blocks[index];
    final selection = block.controller.selection;
    if (!selection.isValid || selection.isCollapsed) {
      showAppError(
        context,
        const ValidationFailure('본문에서 별도 영역으로 분리할 텍스트를 먼저 선택해 주세요.'),
      );
      return;
    }
    final text = block.controller.text;
    final selected = text.substring(selection.start, selection.end).trim();
    if (selected.isEmpty) return;
    final values = [
      if (text.substring(0, selection.start).trim().isNotEmpty)
        OcrReviewBlock(
          text: text.substring(0, selection.start),
          independent: block.independent,
          visualRegion: block.visual,
          kind: block.kind,
        ),
      OcrReviewBlock(
        text: selected,
        independent: true,
        visualRegion: block.visual,
        kind: block.kind,
      ),
      if (text.substring(selection.end).trim().isNotEmpty)
        OcrReviewBlock(
          text: text.substring(selection.end),
          independent: block.independent,
          visualRegion: block.visual,
          kind: block.kind,
        ),
    ];
    if (_blocks.length - 1 + values.length > 200) {
      showAppError(context, const ValidationFailure('페이지당 영역은 최대 200개예요.'));
      return;
    }
    setState(() {
      _blocks.removeAt(index);
      block.controller.dispose();
      _blocks.insertAll(index, values.map(_EditableBlock.new));
      _dirty = true;
    });
  }

  void _merge(int index) {
    if (_readOnly) return;
    final first = _blocks[index];
    final second = _blocks[index + 1];
    if (first.excluded != second.excluded) {
      showAppError(
        context,
        const ValidationFailure('제외 상태가 다른 영역은 합칠 수 없어요. 제외 여부를 먼저 맞춰 주세요.'),
      );
      return;
    }
    final merged = OcrReviewBlock(
      text: '${first.controller.text}\n\n${second.controller.text}',
      independent: first.independent || second.independent,
      excluded: first.excluded,
      visualRegion: first.visual || second.visual,
      kind: first.kind == second.kind ? first.kind : OcrContentKind.uncertain,
    );
    setState(() {
      _blocks.removeRange(index, index + 2);
      first.controller.dispose();
      second.controller.dispose();
      _blocks.insert(index, _EditableBlock(merged));
      _dirty = true;
    });
    if (first.kind != second.kind) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('종류가 다른 영역을 합쳐 불명확으로 표시했어요. 원본을 확인하고 영역 종류를 선택해 주세요.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || (!_dirty && !_busy),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _exit();
    },
    child: Scaffold(
      key: const Key('ocr-review-view'),
      appBar: AppBar(
        leading: BackButton(
          key: const Key('ocr-close-review'),
          onPressed: _exit,
        ),
        title: Text(
          '${widget.fileName} · ${_readOnly ? 'OCR 원문 대조' : 'OCR 검토'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_page != null) ...[
                  IconButton(
                    key: const Key('ocr-previous-page'),
                    tooltip: '이전 페이지',
                    onPressed: _busy || _currentPageNumber == 1
                        ? null
                        : () => _navigate(_currentPageNumber - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    'p.$_currentPageNumber / ${_page!.totalPages}',
                    key: const Key('ocr-page-number'),
                  ),
                  IconButton(
                    key: const Key('ocr-next-page'),
                    tooltip: '다음 페이지',
                    onPressed: _busy || _currentPageNumber == _page!.totalPages
                        ? null
                        : () => _navigate(_currentPageNumber + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _jump,
                    child: const Text('페이지 이동'),
                  ),
                ],
                if (!_readOnly) ...[
                  OutlinedButton(
                    key: const Key('ocr-save-page'),
                    onPressed: _busy || !_dirty ? null : _saveButton,
                    child: const Text('수정 저장'),
                  ),
                  Text(_dirty ? '저장하지 않은 수정' : '서버에 보관됨'),
                ] else
                  const Text('읽기 전용 · 기존 개념은 변경되지 않습니다.'),
                TextButton(
                  onPressed: _busy ? null : _reload,
                  child: const Text('새로고침'),
                ),
                if (!_readOnly)
                  FilledButton(
                    key: const Key('ocr-confirm-review'),
                    onPressed: _busy || _page == null ? null : _confirm,
                    child: const Text('검토 확정 · 개념 추출 시작'),
                  ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AppErrorNotice(error: _error!),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _page == null
                ? Center(
                    child: OutlinedButton(
                      onPressed: _reload,
                      child: const Text('검토 내용 다시 불러오기'),
                    ),
                  )
                : _continuousArchive
                ? _continuousComparison()
                : LayoutBuilder(
                    builder: (context, constraints) =>
                        _isDesktop && constraints.maxWidth >= 900
                        ? _desktopComparison()
                        : constraints.maxWidth >= 900
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: _preview()),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: _readOnly ? _archive() : _editor(),
                              ),
                            ],
                          )
                        : DefaultTabController(
                            length: 2,
                            child: Column(
                              children: [
                                TabBar(
                                  tabs: [
                                    const Tab(text: '원본 페이지'),
                                    Tab(
                                      text: _readOnly ? '추출 텍스트' : '추출 내용 편집',
                                    ),
                                  ],
                                ),
                                Expanded(
                                  child: TabBarView(
                                    children: [
                                      _preview(),
                                      _readOnly ? _archive() : _editor(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
          ),
        ],
      ),
    ),
  );
  Widget _continuousComparison() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<bool>(
            key: const Key('ocr-archive-text-mode'),
            segments: const [
              ButtonSegment(value: true, label: Text('OCR 원문')),
              ButtonSegment(value: false, label: Text('최종 추출 입력')),
            ],
            selected: {_showOriginal},
            onSelectionChanged: (values) =>
                setState(() => _showOriginal = values.single),
          ),
        ),
        Expanded(
          child: KeyedSubtree(
            key: const Key('ocr-desktop-comparison-scroll'),
            child: ContinuousOcrComparison(
              key: _continuousKey,
              initialPage: _page!,
              initialImage: _image,
              initialImageError: _imageError,
              // Report a missing connection in the page, not as a build error.
              loadPage: (number) async =>
                  _coordinator.reviewPage(widget.jobId, number),
              loadImage: (number) async =>
                  _coordinator.reviewImage(widget.jobId, number),
              onPageChanged: (number) =>
                  setState(() => _archivePageNumber = number),
              textBuilder: (page, current) => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_archiveDescription(page)),
                  ),
                  _archiveText(
                    desktopScroll: true,
                    page: page,
                    keySuffix: current ? '' : '-${page.pageNumber}',
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _archiveDescription(OcrReviewPage page) => _showOriginal
      ? '텍스트 레이어와 OCR로 읽은 원래 내용을 그대로 표시합니다.'
      : page.edited
      ? '검토 후 확정한 입력입니다. 제외한 영역은 보관되지만 AI에는 전달되지 않았습니다.'
      : '이 페이지는 사용자 수정 없이 추출 내용으로 개념을 생성했습니다.';

  Widget _desktopComparison() => Scrollbar(
    key: const Key('ocr-desktop-comparison-scrollbar'),
    controller: _comparisonScroll,
    thumbVisibility: true,
    child: SingleChildScrollView(
      key: const Key('ocr-desktop-comparison-scroll'),
      controller: _comparisonScroll,
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _preview(desktopScroll: true)),
          const SizedBox(width: 1),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: _readOnly
                  ? _archive(desktopScroll: true)
                  : _editor(desktopScroll: true),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _preview({bool desktopScroll = false}) => _image == null
      ? Center(
          child: AppErrorNotice(
            error: _imageError ?? '페이지 이미지를 불러오지 못했어요.',
            onRetry: _reload,
          ),
        )
      : Padding(
          padding: const EdgeInsets.all(12),
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            // Wheel input scrolls the comparison instead of zooming the image.
            // Pinch zoom and drag remain available in InteractiveViewer.
            scaleFactor: desktopScroll
                ? double.infinity
                : kDefaultMouseScrollToScaleFactor,
            child: desktopScroll
                ? _pageImage(fit: BoxFit.fitWidth, width: double.infinity)
                : Center(child: _pageImage()),
          ),
        );

  Widget _pageImage({BoxFit fit = BoxFit.contain, double? width}) =>
      Image.memory(
        _image!,
        key: const Key('ocr-page-image'),
        fit: fit,
        width: width,
        errorBuilder: (_, error, stack) =>
            const AppErrorNotice(error: 'PDF 페이지 이미지를 표시하지 못했어요.'),
      );

  Widget _archive({bool desktopScroll = false}) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              key: const Key('ocr-archive-text-mode'),
              segments: const [
                ButtonSegment(value: true, label: Text('OCR 원문')),
                ButtonSegment(value: false, label: Text('최종 추출 입력')),
              ],
              selected: {_showOriginal},
              onSelectionChanged: (values) =>
                  setState(() => _showOriginal = values.single),
            ),
            const SizedBox(height: 8),
            Text(_archiveDescription(_page!)),
          ],
        ),
      ),
      if (desktopScroll)
        _archiveText(desktopScroll: true)
      else
        Expanded(child: _archiveText()),
    ],
  );

  Widget _archiveText({
    bool desktopScroll = false,
    OcrReviewPage? page,
    String keySuffix = '',
  }) {
    final displayedPage = page ?? _page!;
    return ListView(
      key: const Key('ocr-archive-text-list'),
      shrinkWrap: desktopScroll,
      primary: desktopScroll ? false : null,
      physics: desktopScroll ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: _showOriginal
          ? [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        [
                          for (final (index, block)
                              in displayedPage.originalBlocks.indexed)
                            '영역 ${index + 1}: ${block.kind.label}',
                        ].join(' · '),
                        key: Key('ocr-archive-original-kinds$keySuffix'),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        displayedPage.originalText,
                        key: Key('ocr-archive-original-text$keySuffix'),
                      ),
                    ],
                  ),
                ),
              ),
            ]
          : [
              for (final (index, block) in displayedPage.blocks.indexed)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '영역 ${index + 1} · ${block.kind.label}${block.independent ? ' · 독립 영역' : ''}${block.visualRegion ? ' · 자동 감지 박스' : ''}${block.excluded ? ' · 추출에서 제외됨' : ''}',
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          block.text,
                          key: Key('ocr-archive-final-text-$index$keySuffix'),
                          style: block.excluded
                              ? TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  decoration: TextDecoration.lineThrough,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
    );
  }

  Widget _editor({bool desktopScroll = false}) => ListView(
    key: const Key('ocr-block-list'),
    shrinkWrap: desktopScroll,
    primary: desktopScroll ? false : null,
    physics: desktopScroll ? const NeverScrollableScrollPhysics() : null,
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        '페이지 이동 시 현재 수정을 저장합니다. 영역 종류는 읽는 방식을, 독립 영역은 주변과 분리할지를 정합니다. 두 설정 모두 중요도와는 무관합니다. 불명확한 영역은 원본에서 확인해 주세요. 제외한 내용은 AI에 보내지 않습니다.',
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: _busy ? null : _reset,
            child: const Text('이 페이지 원문 복원'),
          ),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('원래 추출 결과'),
                content: SizedBox(
                  width: 700,
                  child: SingleChildScrollView(
                    child: SelectableText(_page!.originalText),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'),
                  ),
                ],
              ),
            ),
            child: const Text('원본 추출 텍스트 보기'),
          ),
        ],
      ),
      for (final (index, block) in _blocks.indexed)
        Card(
          key: ObjectKey(block),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '영역 ${index + 1}${block.visual ? ' · 자동 감지 박스' : ''}${block.excluded ? ' · 제외됨' : ''}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<OcrContentKind>(
                  key: Key('ocr-block-kind-$index'),
                  initialValue: block.kind,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '영역 종류',
                    helperText: block.kind == OcrContentKind.uncertain
                        ? '원본에서 종류와 읽기 어려운 내용을 확인해 주세요. AI는 누락된 관계를 추측하지 않습니다.'
                        : null,
                    helperMaxLines: 3,
                  ),
                  items: [
                    for (final kind in OcrContentKind.values)
                      DropdownMenuItem(value: kind, child: Text(kind.label)),
                  ],
                  onChanged: _busy || block.excluded
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() {
                              block.kind = value;
                              _dirty = true;
                            });
                          }
                        },
                ),
                const SizedBox(height: 8),
                TextField(
                  key: Key('ocr-block-text-$index'),
                  controller: block.controller,
                  enabled: !_busy && !block.excluded,
                  minLines: 3,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: '추출 내용'),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
                SwitchListTile(
                  key: Key('ocr-block-independent-$index'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('독립 영역'),
                  value: block.independent,
                  onChanged: _busy || block.excluded
                      ? null
                      : (value) => setState(() {
                          block.independent = value;
                          _dirty = true;
                        }),
                ),
                CheckboxListTile(
                  key: Key('ocr-block-excluded-$index'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('개념 추출에서 제외'),
                  value: block.excluded,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          block.excluded = value ?? false;
                          _dirty = true;
                        }),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton(
                      key: Key('ocr-split-block-$index'),
                      onPressed: _busy || block.excluded
                          ? null
                          : () => _split(index),
                      child: const Text('선택 영역 분리'),
                    ),
                    if (index + 1 < _blocks.length)
                      OutlinedButton(
                        key: Key('ocr-merge-block-$index'),
                        onPressed: _busy ? null : () => _merge(index),
                        child: const Text('다음 영역과 합치기'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      OutlinedButton(
        key: const Key('ocr-add-block'),
        onPressed: _busy || _blocks.length >= 200
            ? null
            : () => setState(() {
                _blocks.add(_EditableBlock(const OcrReviewBlock(text: '')));
                _dirty = true;
              }),
        child: const Text('영역 추가'),
      ),
    ],
  );
}

class _OcrPageJumpDialog extends StatefulWidget {
  const _OcrPageJumpDialog({required this.current, required this.total});
  final int current;
  final int total;
  @override
  State<_OcrPageJumpDialog> createState() => _OcrPageJumpDialogState();
}

class _OcrPageJumpDialogState extends State<_OcrPageJumpDialog> {
  late final controller = TextEditingController(text: '${widget.current}');
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('페이지 이동'),
    content: TextField(
      key: const Key('ocr-jump-page-field'),
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: '1 ~ ${widget.total}',
        errorText: error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () {
          final number = int.tryParse(controller.text);
          if (number == null || number < 1 || number > widget.total) {
            setState(() => error = '1 ~ ${widget.total} 사이의 페이지를 입력해 주세요.');
            return;
          }
          Navigator.pop(context, number);
        },
        child: const Text('이동'),
      ),
    ],
  );
}
