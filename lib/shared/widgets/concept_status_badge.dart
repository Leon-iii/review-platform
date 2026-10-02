import 'package:flutter/material.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';

class ConceptStatusBadge extends StatelessWidget {
  const ConceptStatusBadge({
    required this.status,
    this.compact = false,
    super.key,
  });

  final ConceptStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConceptBadge(
      label: status.label,
      compact: compact,
      outlined: status == ConceptStatus.approved,
      backgroundColor: status == ConceptStatus.approved
          ? theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow
          : null,
      foregroundColor: status == ConceptStatus.approved
          ? theme.brightness == Brightness.dark
                ? const Color(0xFFC5E1A5)
                : const Color(0xFF4E6B38)
          : theme.colorScheme.onSurfaceVariant,
    );
  }
}
