import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:review_platform/domain/models/document_ocr_review.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

class _ComparisonPage {
  const _ComparisonPage(this.page, this.image, this.imageError);
  final OcrReviewPage page;
  final Uint8List? image;
  final Object? imageError;
}

/// Lazily lays out pages on both sides of a jump anchor. The leading sliver
/// grows upward, so previous pages do not require guessed heights or offsets.
class ContinuousOcrComparison extends StatefulWidget {
  const ContinuousOcrComparison({
    required this.initialPage,
    required this.initialImage,
    required this.initialImageError,
    required this.loadPage,
    required this.loadImage,
    required this.textBuilder,
    required this.onPageChanged,
    super.key,
  });

  final OcrReviewPage initialPage;
  final Uint8List? initialImage;
  final Object? initialImageError;
  final Future<OcrReviewPage> Function(int) loadPage;
  final Future<Uint8List> Function(int) loadImage;
  final Widget Function(OcrReviewPage, bool) textBuilder;
  final ValueChanged<int> onPageChanged;

  @override
  State<ContinuousOcrComparison> createState() =>
      ContinuousOcrComparisonState();
}

class ContinuousOcrComparisonState extends State<ContinuousOcrComparison> {
  final _viewportKey = GlobalKey();
  final _centerKey = GlobalKey();
  final Map<int, GlobalKey<_ComparisonEntryState>> _pageKeys = {};
  final Map<int, _ComparisonPage> _cache = {};
  final Map<int, Future<_ComparisonPage>> _pending = {};
  late ScrollController _scroll;
  late int _anchor;
  late int _current;
  bool _visibilityScheduled = false;

  @override
  void initState() {
    super.initState();
    _anchor = _current = widget.initialPage.pageNumber;
    _cache[_anchor] = _ComparisonPage(
      widget.initialPage,
      widget.initialImage,
      widget.initialImageError,
    );
    _scroll = _newController();
  }

  ScrollController _newController() =>
      ScrollController(keepScrollOffset: false)
        ..addListener(_scheduleVisibility);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<_ComparisonPage> _load(int number) {
    final cached = _cache.remove(number);
    if (cached != null) {
      _cache[number] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(number, () async {
      try {
        final page = await widget.loadPage(number);
        Uint8List? image;
        Object? imageError;
        try {
          image = await widget.loadImage(number);
        } catch (error) {
          imageError = error;
        }
        final result = _ComparisonPage(page, image, imageError);
        if (mounted) {
          _cache[number] = result;
          while (_cache.length > 5) {
            _cache.remove(_cache.keys.first);
          }
        }
        return result;
      } finally {
        _pending.remove(number);
      }
    });
  }

  void jumpToPage(int number) {
    if (number < 1 || number > widget.initialPage.totalPages) return;
    final target = _pageKeys[number]?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignment: 0,
        duration: const Duration(milliseconds: 180),
      );
    } else {
      final previous = _scroll;
      setState(() {
        _anchor = number;
        _scroll = _newController();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    _scheduleVisibility();
  }

  void reloadCurrentPage() {
    _cache.remove(_current);
    // Retain the old page's layout while refreshing, avoiding scroll jumps.
    _pageKeys[_current]?.currentState?._retry();
  }

  void _scheduleVisibility() {
    if (!mounted || _visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final top = viewport.localToGlobal(Offset.zero).dy + 1;
      int? visible;
      for (final entry in _pageKeys.entries) {
        final box = entry.value.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final pageTop = box.localToGlobal(Offset.zero).dy;
        if (pageTop <= top && pageTop + box.size.height > top) {
          visible = entry.key;
          break;
        }
      }
      if (visible != null && visible != _current) {
        setState(() => _current = visible!);
        widget.onPageChanged(visible);
      }
    });
  }

  Widget _entry(int number, double placeholderHeight) {
    final key = _pageKeys.putIfAbsent(
      number,
      () => GlobalKey<_ComparisonEntryState>(),
    );
    return _ComparisonEntry(
      key: key,
      number: number,
      current: number == _current,
      placeholderHeight: placeholderHeight,
      load: () => _load(number),
      retry: () {
        _cache.remove(number);
        return _load(number);
      },
      textBuilder: widget.textBuilder,
      onLayout: _scheduleVisibility,
    );
  }

  @override
  Widget build(BuildContext context) {
    _scheduleVisibility();
    return SizedBox.expand(
      key: _viewportKey,
      child: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          key: const Key('ocr-desktop-comparison-scrollbar'),
          controller: _scroll,
          thumbVisibility: true,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              _scheduleVisibility();
              return false;
            },
            child: CustomScrollView(
              key: ValueKey('ocr-continuous-scroll-$_anchor'),
              controller: _scroll,
              center: _centerKey,
              scrollCacheExtent: ScrollCacheExtent.pixels(
                constraints.maxHeight,
              ),
              slivers: [
                SliverList.builder(
                  itemCount: _anchor - 1,
                  addAutomaticKeepAlives: false,
                  itemBuilder: (context, index) =>
                      _entry(_anchor - index - 1, constraints.maxHeight),
                ),
                SliverList.builder(
                  key: _centerKey,
                  itemCount: widget.initialPage.totalPages - _anchor + 1,
                  addAutomaticKeepAlives: false,
                  itemBuilder: (context, index) =>
                      _entry(_anchor + index, constraints.maxHeight),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComparisonEntry extends StatefulWidget {
  const _ComparisonEntry({
    required this.number,
    required this.current,
    required this.placeholderHeight,
    required this.load,
    required this.retry,
    required this.textBuilder,
    required this.onLayout,
    super.key,
  });
  final int number;
  final bool current;
  final double placeholderHeight;
  final Future<_ComparisonPage> Function() load;
  final Future<_ComparisonPage> Function() retry;
  final Widget Function(OcrReviewPage, bool) textBuilder;
  final VoidCallback onLayout;
  @override
  State<_ComparisonEntry> createState() => _ComparisonEntryState();
}

class _ComparisonEntryState extends State<_ComparisonEntry> {
  late Future<_ComparisonPage> _future;
  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _retry() {
    final future = widget.retry();
    setState(() {
      _future = future;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_ComparisonPage>(
    future: _future,
    builder: (context, snapshot) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onLayout();
      });
      final data = snapshot.data;
      return ConstrainedBox(
        key: Key('ocr-comparison-page-${widget.number}'),
        constraints: BoxConstraints(minHeight: widget.placeholderHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 16),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'p.${widget.number}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (snapshot.hasError)
              SizedBox(
                height: widget.placeholderHeight,
                child: Center(
                  child: AppErrorNotice(
                    error: snapshot.error!,
                    fallback: 'OCR 페이지를 불러오지 못했어요.',
                    onRetry: _retry,
                  ),
                ),
              )
            else if (data == null)
              SizedBox(
                height: widget.placeholderHeight,
                child: const Center(child: CircularProgressIndicator()),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: data.image == null
                          ? AppErrorNotice(
                              error:
                                  data.imageError ?? 'PDF 페이지 이미지를 불러오지 못했어요.',
                              onRetry: _retry,
                            )
                          : InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 5,
                              scaleFactor: double.infinity,
                              child: Image.memory(
                                data.image!,
                                key: widget.current
                                    ? const Key('ocr-page-image')
                                    : Key('ocr-page-image-${widget.number}'),
                                fit: BoxFit.fitWidth,
                                width: double.infinity,
                                errorBuilder: (_, error, stack) =>
                                    const AppErrorNotice(
                                      error: 'PDF 페이지 이미지를 표시하지 못했어요.',
                                    ),
                              ),
                            ),
                    ),
                  ),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                      child: widget.textBuilder(data.page, widget.current),
                    ),
                  ),
                ],
              ),
          ],
        ),
      );
    },
  );
}
