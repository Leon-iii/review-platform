import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

bool get supportsPdfDrop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Native file drops share the same validated document import as the picker.
class PdfDropZone extends StatefulWidget {
  const PdfDropZone({
    required this.child,
    required this.routePath,
    required this.onPdfDropped,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final String routePath;
  final Future<void> Function(PickedPdfDocument) onPdfDropped;
  final bool enabled;

  @override
  State<PdfDropZone> createState() => _PdfDropZoneState();
}

class _PdfDropZoneState extends State<PdfDropZone> {
  bool _hovering = false;
  bool _reading = false;

  bool get _canReceive =>
      widget.enabled &&
      !_reading &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (GoRouter.maybeOf(context)?.state.uri.path ?? widget.routePath) ==
          widget.routePath;

  bool _visibleAt(Offset position) {
    // Native plugins also notify obscured widgets. Do not import underneath
    // dialogs, popup menus, or a route on another Navigator.
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    final target = context.findRenderObject();
    return result.path.any((entry) => entry.target == target);
  }

  Future<void> _drop(DropDoneDetails details) async {
    if (!_canReceive || !_visibleAt(details.globalPosition)) return;
    setState(() {
      _hovering = false;
      _reading = true;
    });
    try {
      final document = await readDroppedPdf(details.files);
      if (!mounted ||
          !widget.enabled ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          (GoRouter.maybeOf(context)?.state.uri.path ?? widget.routePath) !=
              widget.routePath) {
        return;
      }
      await widget.onPdfDropped(document);
    } catch (error) {
      if (!mounted) return;
      showAppError(context, error, fallback: 'PDF를 가져오지 못했어요.');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!supportsPdfDrop) return widget.child;
    // Subscribe to this route's visibility and to root/shell route changes.
    ModalRoute.isCurrentOf(context);
    final router = GoRouter.maybeOf(context);
    Widget target() => DropTarget(
      enable: _canReceive,
      onDragEntered: (details) {
        if (_canReceive && _visibleAt(details.globalPosition)) {
          setState(() => _hovering = true);
        }
      },
      onDragExited: (_) {
        if (mounted && _hovering) setState(() => _hovering = false);
      },
      onDragDone: _drop,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            AbsorbPointer(absorbing: _reading, child: widget.child),
            if ((_hovering && _canReceive) || (_reading && widget.enabled))
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const Key('pdf-drop-highlight'),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface
                          .withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_reading)
                              const CircularProgressIndicator()
                            else
                              const Icon(Icons.upload_file_rounded, size: 40),
                            const SizedBox(height: 12),
                            Text(
                              _reading
                                  ? 'PDF를 가져오고 있어요.'
                                  : 'PDF 파일을 놓으면 분석을 시작합니다.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            const Text('PDF 파일 1개 · 최대 25MB'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return router == null
        ? target()
        : ListenableBuilder(
            listenable: router.routerDelegate,
            builder: (context, _) => target(),
          );
  }
}
