import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:review_platform/shared/widgets/concept_importance_badge.dart';
import 'package:review_platform/shared/widgets/concept_status_badge.dart';

void main() {
  const pastels = [
    Color(0xFFB2D9ED),
    Color(0xFFACD5CD),
    Color(0xFFE0CDA0),
    Color(0xFFDDB898),
    Color(0xFFDEA7AF),
  ];
  const muted = [
    Color(0xFF3D6075),
    Color(0xFF3E6962),
    Color(0xFF6E5E39),
    Color(0xFF7C573E),
    Color(0xFF89545C),
  ];
  for (final brightness in Brightness.values) {
    testWidgets(
      '검토 완료와 중요도는 버튼의 카드 배경, 검토 필요와 출처는 기존 배경을 유지한다 ($brightness)',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 800)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final theme = brightness == Brightness.light
            ? AppTheme.light
            : AppTheme.dark;
        final grayBorder = BorderSide(
          strokeAlign: BorderSide.strokeAlignOutside,
          color: brightness == Brightness.dark
              ? Colors.grey.shade700
              : Colors.grey.shade400,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Wrap(
                children: [
                  for (final importance in ConceptImportance.values)
                    ConceptImportanceBadge(
                      key: ValueKey(importance),
                      importance: importance,
                    ),
                  for (final status in ConceptStatus.values)
                    ConceptStatusBadge(key: ValueKey(status), status: status),
                  const ConceptBadge(key: Key('source-badge'), label: 'p.1, 2'),
                ],
              ),
            ),
          ),
        );
        for (var index = 0; index < ConceptImportance.values.length; index++) {
          final importance = ConceptImportance.values[index];
          final badge = find.byKey(ValueKey(importance));
          final chip = tester.widget<Chip>(
            find.descendant(of: badge, matching: find.byType(Chip)),
          );
          expect(find.text('중요도 ${importance.label}'), findsOneWidget);
          expect(chip.backgroundColor, theme.cardTheme.color);
          expect(
            chip.labelStyle!.color,
            brightness == Brightness.dark ? pastels[index] : muted[index],
          );
          expect(chip.side, grayBorder);
          final background = chip.backgroundColor!.computeLuminance();
          final foreground = chip.labelStyle!.color!.computeLuminance();
          final contrast =
              (math.max(background, foreground) + 0.05) /
              (math.min(background, foreground) + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '${importance.label} 글자 대비',
          );
        }
        for (final status in ConceptStatus.values) {
          final chip = tester.widget<Chip>(
            find.descendant(
              of: find.byKey(ValueKey(status)),
              matching: find.byType(Chip),
            ),
          );
          expect(
            chip.backgroundColor,
            status == ConceptStatus.approved
                ? theme.cardTheme.color
                : theme.colorScheme.surfaceContainerHighest,
          );
          final foreground = status == ConceptStatus.approved
              ? brightness == Brightness.dark
                    ? const Color(0xFFC5E1A5)
                    : const Color(0xFF4E6B38)
              : theme.colorScheme.onSurfaceVariant;
          expect(
            chip.side,
            status == ConceptStatus.approved ? grayBorder : BorderSide.none,
          );
          expect(chip.labelStyle!.color, foreground);
          final a = chip.backgroundColor!.computeLuminance();
          final b = foreground.computeLuminance();
          expect(
            (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05),
            greaterThanOrEqualTo(4.5),
          );
        }
        final sourceChip = tester.widget<Chip>(
          find.descendant(
            of: find.byKey(const Key('source-badge')),
            matching: find.byType(Chip),
          ),
        );
        expect(
          sourceChip.backgroundColor,
          theme.colorScheme.surfaceContainerHighest,
        );
        expect(
          sourceChip.labelStyle!.color,
          theme.colorScheme.onSurfaceVariant,
        );
        expect(sourceChip.side, BorderSide.none);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }
}
