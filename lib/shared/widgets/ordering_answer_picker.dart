import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/shared/widgets/study_text.dart';

class OrderingAnswerPicker extends StatelessWidget {
  const OrderingAnswerPicker({
    required this.choices,
    required this.selectedIds,
    required this.enabled,
    required this.onToggle,
    required this.onClear,
    super.key,
  });
  final List<SnapshotChoice> choices;
  final List<String> selectedIds;
  final bool enabled;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var index = 0; index < choices.length; index++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            selected: selectedIds.contains(choices[index].id),
            child: OutlinedButton(
              key: Key('ordering-choice-${choices[index].id}'),
              onPressed: enabled ? () => onToggle(choices[index].id) : null,
              style: selectedIds.contains(choices[index].id)
                  ? OutlinedButton.styleFrom(
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      foregroundColor: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                    )
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _OrderingRankBadge(
                      choiceId: choices[index].id,
                      rank: selectedIds.indexOf(choices[index].id) + 1,
                      enabled: enabled,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: StudyText(choices[index].text)),
                  ],
                ),
              ),
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: const Key('ordering-answer-clear'),
          onPressed: enabled && selectedIds.isNotEmpty ? onClear : null,
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('선택 초기화'),
        ),
      ),
    ],
  );
}

/// A non-interactive indicator: the entire choice remains the touch target.
class _OrderingRankBadge extends StatelessWidget {
  const _OrderingRankBadge({
    required this.choiceId,
    required this.rank,
    required this.enabled,
  });

  final String choiceId;
  final int rank;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = rank > 0;
    final style = theme.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w700,
      color: selected && enabled ? colors.onPrimary : colors.onSurfaceVariant,
    );
    // Reduce the current badge by another 10%, keeping both states square.
    // At unusually large text sizes, preserve the full number line.
    final textHeight =
        MediaQuery.textScalerOf(context).scale(style.fontSize!) *
        (style.height ?? 1.25);
    final previousExtent = math.max(
      math.max(AppSpacing.section, textHeight + AppSpacing.lg) * 0.8,
      textHeight + AppSpacing.xs,
    );
    final extent = math.max(previousExtent * 0.9, textHeight);
    return SizedBox.square(
      dimension: extent,
      child: DecoratedBox(
        key: Key('ordering-choice-rank-badge-$choiceId'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.control),
          color: selected
              ? enabled
                    ? colors.primary
                    : colors.surfaceContainerHighest
              : colors.surface,
          border: Border.all(
            color: selected && enabled
                ? colors.primary
                : enabled
                ? colors.outline
                : colors.outlineVariant,
          ),
        ),
        child: Center(
          child: Text(
            key: Key('ordering-choice-rank-$choiceId'),
            selected ? '$rank' : '',
            style: style,
            semanticsLabel: selected
                ? '답안 순서 $rank번째${enabled ? ', 다시 눌러 선택 취소' : ''}'
                : '미선택',
          ),
        ),
      ),
    );
  }
}
