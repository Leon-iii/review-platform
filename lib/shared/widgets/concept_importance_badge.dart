import 'package:flutter/material.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';

class ConceptImportanceBadge extends StatelessWidget {
  const ConceptImportanceBadge({
    required this.importance,
    this.compact = false,
    this.showPrefix,
    super.key,
  });

  final ConceptImportance importance;
  final bool compact;

  /// Overrides the default: compact concept badges omit the prefix, while
  /// normal badges include it. Question cards always include it at either size.
  final bool? showPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Soft pastels on dark surfaces; muted shades of the same hues on light
    // surfaces keep small text readable without using vivid fills.
    final (pastel, muted) = switch (importance) {
      ConceptImportance.veryLow => (
        const Color(0xFFB2D9ED),
        const Color(0xFF3D6075),
      ),
      ConceptImportance.low => (
        const Color(0xFFACD5CD),
        const Color(0xFF3E6962),
      ),
      ConceptImportance.medium => (
        const Color(0xFFE0CDA0),
        const Color(0xFF6E5E39),
      ),
      ConceptImportance.high => (
        const Color(0xFFDDB898),
        const Color(0xFF7C573E),
      ),
      ConceptImportance.veryHigh => (
        const Color(0xFFDEA7AF),
        const Color(0xFF89545C),
      ),
    };
    return Semantics(
      label: '중요도 ${importance.label}',
      child: ExcludeSemantics(
        child: ConceptBadge(
          label: (showPrefix ?? !compact)
              ? '중요도 ${importance.label}'
              : importance.label,
          compact: compact,
          outlined: true,
          backgroundColor:
              theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
          foregroundColor: dark ? pastel : muted,
        ),
      ),
    );
  }
}
