import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';

/// Review/approval shares one visual meaning across concepts and questions.
/// Domain-specific labels do not change the size, surface or completed color.
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({
    required this.reviewed,
    required this.label,
    this.compact = false,
    super.key,
  });
  final bool reviewed;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConceptBadge(
      label: label,
      compact: compact,
      outlined: reviewed,
      backgroundColor: reviewed
          ? theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow
          : null,
      foregroundColor: reviewed
          ? theme.brightness == Brightness.dark
                ? const Color(0xFFC5E1A5)
                : const Color(0xFF4E6B38)
          : theme.colorScheme.onSurfaceVariant,
    );
  }
}
