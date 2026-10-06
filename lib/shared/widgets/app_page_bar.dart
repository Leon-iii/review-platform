import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/design_tokens.dart';

/// Back always means the previous route. The fallback is a contextual parent
/// for direct/deep-link entry, never an unlabeled replacement home action.
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    this.onPressed,
    this.fallback = '/library',
    this.enabled = true,
    this.buttonKey,
    super.key,
  });
  final VoidCallback? onPressed;
  final String fallback;
  final bool enabled;
  final Key? buttonKey;

  static Future<void> navigate(BuildContext context, String fallback) async {
    final handled = await Navigator.of(context).maybePop();
    if (!handled && context.mounted) context.go(fallback);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: buttonKey,
    tooltip: '뒤로가기',
    constraints: const BoxConstraints(
      minWidth: AppLayout.touchTarget,
      minHeight: AppLayout.touchTarget,
    ),
    icon: const Icon(Icons.arrow_back_rounded),
    onPressed: !enabled ? null : onPressed ?? () => navigate(context, fallback),
  );
}

class AppPageBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageBar({
    required this.title,
    this.showBack = true,
    this.fallback = '/library',
    this.onBack,
    this.backEnabled = true,
    this.handleSystemBack = true,
    this.backKey,
    this.actions,
    super.key,
  });
  final Widget title;
  final bool showBack;
  final String fallback;
  final VoidCallback? onBack;
  final bool backEnabled;

  /// Editors with their own exit guard handle both forms of back themselves.
  final bool handleSystemBack;
  final Key? backKey;
  final List<Widget>? actions;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) {
    final bar = AppBar(
      automaticallyImplyLeading: false,
      leading: showBack
          ? AppBackButton(
              buttonKey: backKey,
              fallback: fallback,
              onPressed: onBack,
              enabled: backEnabled,
            )
          : null,
      title: title,
      actions: actions,
    );
    if (!showBack || !handleSystemBack) return bar;
    final hasPrevious = Navigator.of(context).canPop();
    return PopScope<Object?>(
      canPop: hasPrevious,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !hasPrevious && backEnabled) {
          if (onBack != null) {
            onBack!();
          } else {
            context.go(fallback);
          }
        }
      },
      child: bar,
    );
  }
}
