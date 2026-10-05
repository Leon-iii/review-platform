import 'package:flutter/material.dart';

enum _ExitAction { discard, save }

/// Protects an editor route, including back navigation and dialog dismissal.
class UnsavedChangesGuard extends StatefulWidget {
  const UnsavedChangesGuard({
    required this.hasChanges,
    required this.busy,
    required this.onSave,
    required this.child,
    this.savedResult,
    super.key,
  });

  final bool hasChanges;
  final bool busy;
  final Future<bool> Function() onSave;
  final Object? savedResult;
  final Widget child;

  @override
  State<UnsavedChangesGuard> createState() => UnsavedChangesGuardState();
}

class UnsavedChangesGuardState extends State<UnsavedChangesGuard> {
  bool _confirming = false;
  bool _allowPop = false;

  Future<void> requestExit([Object? result]) async {
    if (_confirming || _allowPop || widget.busy) return;
    _confirming = true;
    try {
      if (!widget.hasChanges) {
        await close(result);
        return;
      }
      final action = await showDialog<_ExitAction>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('unsaved-changes-dialog'),
          title: const Text('저장하지 않은 변경사항이 있어요'),
          content: const Text('변경사항을 저장하고 나갈까요?'),
          actions: [
            TextButton(
              key: const Key('unsaved-continue-button'),
              onPressed: () => Navigator.pop(context),
              child: const Text('계속 편집'),
            ),
            TextButton(
              key: const Key('unsaved-discard-button'),
              onPressed: () => Navigator.pop(context, _ExitAction.discard),
              child: const Text('저장하지 않고 나가기'),
            ),
            FilledButton(
              key: const Key('unsaved-save-button'),
              onPressed: () => Navigator.pop(context, _ExitAction.save),
              child: const Text('저장 후 나가기'),
            ),
          ],
        ),
      );
      if (!mounted || action == null) return;
      if (action == _ExitAction.save) {
        if (!await widget.onSave() || !mounted) return;
        await close(widget.savedResult);
      } else {
        await close(result);
      }
    } finally {
      _confirming = false;
    }
  }

  /// Call only after a successful explicit save (or a confirmed discard).
  Future<void> close([Object? result]) async {
    if (!mounted || _allowPop) return;
    setState(() => _allowPop = true);
    // An explicit pop is intentional here: saving/discarding was already
    // confirmed. PopScope's callback receives didPop=true and does not re-prompt.
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: _allowPop || (!widget.hasChanges && !widget.busy),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) requestExit(result);
    },
    child: widget.child,
  );
}
