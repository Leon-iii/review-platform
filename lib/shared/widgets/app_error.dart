import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/errors/app_error_reporter.dart';

void showAppError(BuildContext context, Object error, {String? fallback}) {
  final scope = context.getInheritedWidgetOfExactType<_AppErrorScope>();
  if (scope != null) {
    scope.report(error, fallback);
  } else {
    unawaited(
      _showErrorDialog(
        context,
        AppErrorEvent(
          appErrorMessage(error, fallback: fallback ?? '요청을 처리하지 못했어요.'),
          '오류가 발생했어요',
        ),
      ),
    );
  }
}

Future<void> _showErrorDialog(BuildContext context, AppErrorEvent event) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const Key('app-error-dialog'),
          icon: Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(event.title),
          content: SingleChildScrollView(child: SelectableText(event.message)),
          actions: [
            TextButton.icon(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: '${event.title}\n${event.message}'),
              ),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('오류 복사'),
            ),
            FilledButton(
              key: const Key('acknowledge-app-error'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인'),
            ),
          ],
        ),
      ),
    );

class AppErrorHost extends ConsumerStatefulWidget {
  const AppErrorHost({
    required this.navigatorKey,
    required this.child,
    super.key,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<AppErrorHost> createState() => _AppErrorHostState();
}

class _AppErrorHostState extends ConsumerState<AppErrorHost> {
  bool _showing = false;

  void _schedule() {
    if (_showing) return;
    _showing = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final events = ref.read(appErrorReporterProvider);
      final context = widget.navigatorKey.currentContext;
      if (events.isEmpty || context == null) {
        _showing = false;
        return;
      }
      final event = events.first;
      await _showErrorDialog(context, event);
      if (!mounted) return;
      ref.read(appErrorReporterProvider.notifier).acknowledge(event);
      _showing = false;
      if (ref.read(appErrorReporterProvider).isNotEmpty) _schedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appErrorReporterProvider, (_, events) {
      if (events.isNotEmpty) _schedule();
    });
    if (ref.read(appErrorReporterProvider).isNotEmpty) _schedule();
    return _AppErrorScope(
      report: (error, fallback) => ref
          .read(appErrorReporterProvider.notifier)
          .report(error, fallback: fallback),
      child: widget.child,
    );
  }
}

class _AppErrorScope extends InheritedWidget {
  const _AppErrorScope({required this.report, required super.child});
  final void Function(Object error, String? fallback) report;
  @override
  bool updateShouldNotify(_AppErrorScope oldWidget) => false;
}

/// Persistent counterpart to the common error dialog, used on failed screens.
class AppErrorNotice extends StatelessWidget {
  const AppErrorNotice({
    required this.error,
    this.fallback,
    this.onRetry,
    super.key,
  });
  final Object error;
  final String? fallback;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Card(
        color: colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    color: colors.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '오류가 발생했어요',
                      style: TextStyle(
                        color: colors.onErrorContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                appErrorMessage(error, fallback: fallback ?? '요청을 처리하지 못했어요.'),
                style: TextStyle(color: colors.onErrorContainer),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: onRetry,
                    child: const Text('다시 시도'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
