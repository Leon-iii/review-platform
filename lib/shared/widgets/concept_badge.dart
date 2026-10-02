import 'package:flutter/material.dart';

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

  static const _radius = BorderRadius.all(Radius.circular(8));

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      padding: compact ? const EdgeInsets.all(4) : null,
      labelPadding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null,
      backgroundColor:
          backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        color:
            foregroundColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontSize: compact ? 12 : null,
      ),
      shape: const RoundedRectangleBorder(borderRadius: _radius),
      side: outlined
          ? BorderSide(
              // Paint outward so adding the outline does not change chip size.
              strokeAlign: BorderSide.strokeAlignOutside,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey.shade700
                  : Colors.grey.shade400,
            )
          : BorderSide.none,
      surfaceTintColor: Colors.transparent,
      // These are labels, not controls, so no extra touch-target space is needed.
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
