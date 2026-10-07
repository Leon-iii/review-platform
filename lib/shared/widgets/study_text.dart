import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:review_platform/domain/formatters/study_notation.dart';
import 'package:review_platform/shared/widgets/app_dialog.dart';

const studyNotationInputHint =
    r'수식은 \(x_{i}^{2}\), 독립 수식은 \[...\]로 입력합니다. 편집 시 LaTeX 원문을 유지합니다.';

/// Prose and LaTeX share one renderer. Stored/edited/copied values stay lossless.
/// Ordinary text keeps Flutter's normal Text layout and selection behaviour.
class StudyText extends StatefulWidget {
  const StudyText(
    this.data, {
    this.style,
    this.maxLines,
    this.overflow,
    this.selectable = false,
    super.key,
  });

  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool selectable;

  @override
  State<StudyText> createState() => _StudyTextState();
}

class _StudyTextState extends State<StudyText> {
  late List<StudyNotationPart> _parts;

  @override
  void initState() {
    super.initState();
    _parts = splitStudyNotation(widget.data);
  }

  @override
  void didUpdateWidget(StudyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _parts = splitStudyNotation(widget.data);
  }

  @override
  Widget build(BuildContext context) {
    if (!_parts.any((part) => part.isMath)) {
      return widget.selectable
          ? SelectableText(widget.data, style: widget.style)
          : Text(
              widget.data,
              style: widget.style,
              maxLines: widget.maxLines,
              overflow: widget.overflow,
            );
    }
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final spans = <InlineSpan>[];
    for (var i = 0; i < _parts.length; i++) {
      final part = _parts[i];
      if (!part.isMath) {
        spans.add(TextSpan(text: part.source));
        continue;
      }
      final block = part.display && widget.maxLines == null;
      if (block && i > 0 && !_parts[i - 1].source.endsWith('\n')) {
        spans.add(const TextSpan(text: '\n'));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MathFragment(
            key: ValueKey('$i:${part.source}'),
            part: part,
            style: style,
          ),
        ),
      );
      if (block &&
          i < _parts.length - 1 &&
          !_parts[i + 1].source.startsWith('\n')) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
    final text = Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
    return widget.selectable ? SelectionArea(child: text) : text;
  }
}

class _MathFragment extends StatefulWidget {
  const _MathFragment({required this.part, required this.style, super.key});
  final StudyNotationPart part;
  final TextStyle style;

  @override
  State<_MathFragment> createState() => _MathFragmentState();
}

class _MathFragmentState extends State<_MathFragment> {
  // Cache the parsed tree; card expansion, hover and theme changes do not reparse.
  late Math _parsed;
  bool _sourceOpen = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _parsed = Math.tex(widget.part.expression!);
  }

  @override
  void didUpdateWidget(_MathFragment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.part.expression != widget.part.expression) {
      _parsed = Math.tex(widget.part.expression!);
    }
  }

  Future<void> _showSource() async {
    if (_sourceOpen) return;
    _sourceOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: const Text('수식 원문'),
          content: SingleChildScrollView(
            child: SelectableText(widget.part.source),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: widget.part.source),
                );
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('LaTeX 복사'),
            ),
          ],
        ),
      );
    } finally {
      _sourceOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '수식: ${widget.part.expression}',
      onLongPress: _showSource,
      child: Tooltip(
        message: '수식 원문 · 오른쪽 클릭 또는 길게 눌러 확인·복사',
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.f10, shift: true):
                _ShowNotationSource(),
          },
          actions: {
            _ShowNotationSource: CallbackAction<_ShowNotationSource>(
              onInvoke: (_) {
                _showSource();
                return null;
              },
            ),
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: _focused
                  ? Border.all(color: Theme.of(context).colorScheme.primary)
                  : null,
            ),
            child: GestureDetector(
              onSecondaryTap: _showSource,
              onLongPress: _showSource,
              child: ExcludeSemantics(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  primary: false,
                  child: Math(
                    ast: _parsed.ast,
                    parseError: _parsed.parseError,
                    mathStyle: widget.part.display
                        ? MathStyle.display
                        : MathStyle.text,
                    textStyle: widget.style,
                    // WidgetSpan already scales its child with the surrounding text.
                    textScaleFactor: 1,
                    onErrorFallback: (_) => Tooltip(
                      message: '수식을 표시하지 못해 원문으로 표시합니다.',
                      child: Text(widget.part.source, style: widget.style),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShowNotationSource extends Intent {
  const _ShowNotationSource();
}
