import 'package:flutter/material.dart';
import 'package:review_platform/app/design_tokens.dart';

/// One non-interactive chip shape for concept status, importance and provenance.
class ConceptBadge extends StatelessWidget {
  const ConceptBadge({
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
    this.outlined = false,
    this.compact = false,
    super.key,
  });

  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool outlined;
  final bool compact;

  static const _radius = BorderRadius.all(Radius.circular(AppRadius.control));

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label, softWrap: true),
      padding: const EdgeInsets.all(4),
      labelPadding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8),
      backgroundColor:
          backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      labelStyle:
          (compact
                  ? Theme.of(context).textTheme.labelMedium
                  : Theme.of(context).textTheme.labelLarge)
              ?.copyWith(
                color:
                    foregroundColor ??
                    Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
      shape: const RoundedRectangleBorder(borderRadius: _radius),
      side: outlined
          ? BorderSide(
              // Paint outward so adding the outline does not change chip size.
              strokeAlign: BorderSide.strokeAlignOutside,
              color: Theme.of(context).colorScheme.outlineVariant,
            )
          : BorderSide.none,
      surfaceTintColor: Colors.transparent,
      // These are labels, not controls, so no extra touch-target space is needed.
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
