import 'package:flutter/material.dart';
import 'package:review_platform/app/design_tokens.dart';

/// Related actions share width/height, but grow and stack instead of clipping
/// long labels or suppressing the user's font scale.
class AppActionGroup extends StatelessWidget {
  const AppActionGroup({
    required this.children,
    this.minimumButtonWidth = 160,
    this.availableWidth,
    super.key,
  });
  final List<Widget> children;
  final double minimumButtonWidth;

  /// Intrinsic-size parents (Material dialogs) supply their finite width.
  final double? availableWidth;
  @override
  Widget build(BuildContext context) => availableWidth != null
      ? _layout(context, availableWidth!)
      : LayoutBuilder(
          builder: (context, constraints) =>
              _layout(context, constraints.maxWidth),
        );

  Widget _layout(BuildContext context, double width) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final horizontal =
        width >=
        children.length * minimumButtonWidth * scale +
            (children.length - 1) * AppSpacing.sm;
    if (!horizontal) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            children[i],
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }
}
