import 'package:flutter/material.dart';
import 'package:review_platform/app/design_tokens.dart';

/// The same labeled choices in every form, with a wrapping variant when a
/// segmented control cannot accommodate labels at the user's text scale.
class AppOptionSelector<T> extends StatelessWidget {
  const AppOptionSelector({
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.segmentKeys = const {},
    super.key,
  });
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;
  final Map<T, Key> segmentKeys;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (!multiSelectionEnabled &&
          constraints.maxWidth >= segments.length * 112 * scale) {
        return SegmentedButton<T>(
          segments: segments,
          selected: selected,
          onSelectionChanged: onSelectionChanged,
          multiSelectionEnabled: multiSelectionEnabled,
          emptySelectionAllowed: emptySelectionAllowed,
        );
      }
      return Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final segment in segments)
            FilterChip(
              key: segmentKeys[segment.value],
              label: segment.label ?? const SizedBox.shrink(),
              avatar: segment.icon,
              tooltip: segment.tooltip,
              selected: selected.contains(segment.value),
              onSelected: onSelectionChanged == null || !segment.enabled
                  ? null
                  : (active) {
                      final next = multiSelectionEnabled
                          ? Set<T>.of(selected)
                          : <T>{};
                      if (active) {
                        next.add(segment.value);
                      } else {
                        next.remove(segment.value);
                      }
                      if (next.isNotEmpty || emptySelectionAllowed) {
                        onSelectionChanged!(next);
                      }
                    },
            ),
        ],
      );
    },
  );
}
