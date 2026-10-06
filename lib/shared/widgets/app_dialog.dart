import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_action_group.dart';

/// Confirm, save and cancel actions use the same sizing and responsive rule.
/// Material AlertDialog still owns semantics, focus and keyboard insets.
class AppDialog extends StatelessWidget {
  const AppDialog({
    this.title,
    this.content,
    this.icon,
    this.actions = const [],
    this.scrollable = false,
    super.key,
  });
  final Widget? title;
  final Widget? content;
  final Widget? icon;
  final List<Widget> actions;
  final bool scrollable;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: title,
    content: content,
    icon: icon,
    scrollable: scrollable,
    actions: actions.isEmpty
        ? null
        : [
            SizedBox(
              // AlertDialog measures intrinsic width before layout. Give its
              // responsive actions a finite width rather than asking a
              // LayoutBuilder to provide unsupported intrinsic dimensions.
              width: (MediaQuery.sizeOf(context).width - 128).clamp(0, 560),
              child: AppActionGroup(
                minimumButtonWidth: 140,
                availableWidth: (MediaQuery.sizeOf(context).width - 128).clamp(
                  0,
                  560,
                ),
                children: actions,
              ),
            ),
          ],
  );
}
