import 'package:flutter/material.dart';
import 'package:review_platform/app/design_tokens.dart';

/// Keep chip semantics passive and expose one stable action node on Windows.
class ConceptBadgeAction extends StatelessWidget {
  const ConceptBadgeAction({
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.toggled,
    super.key,
  });
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;
  final bool? toggled;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    enabled: onTap != null,
    toggled: toggled,
    onTap: onTap,
    excludeSemantics: true,
    child: Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: AppLayout.touchTarget,
              minHeight: AppLayout.touchTarget,
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: IgnorePointer(child: child),
            ),
          ),
        ),
      ),
    ),
  );
}
