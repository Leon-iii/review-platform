import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/features/documents/concept_importance_dialog.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<void> Function(ConceptImportance) save,
  ) async {
    await tester.binding.setSurfaceSize(
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1100, 900)
          : const Size(390, 800),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ConceptImportanceDialog(
                  title: '중요도 편집 테스트',
                  initialImportance: ConceptImportance.medium,
                  onSave: save,
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    tester
        .widget<Slider>(find.byKey(const Key('concept-importance-field')))
        .onChanged!(4);
    await tester.pumpAndSettle();
  }

  testWidgets(
    '중요도 저장 실패는 선택 값을 보존하고 재시도로 복구한다',
    (tester) async {
      var fail = true;
      var calls = 0;
      ConceptImportance? stored;
      await open(tester, (value) async {
        calls++;
        if (fail) throw const ValidationFailure('중요도 저장 테스트 오류');
        stored = value;
      });
      await tester.tap(find.byKey(const Key('save-concept-importance-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
      expect(stored, null);
      await tester.tap(find.byKey(const Key('acknowledge-app-error')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('concept-importance-field')))
            .value,
        4,
      );
      fail = false;
      await tester.tap(find.byKey(const Key('save-concept-importance-button')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(stored, ConceptImportance.veryHigh);
      expect(find.byKey(const Key('concept-importance-dialog')), findsNothing);
      expect(tester.takeException(), null);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    '중요도 저장 중 중복 전송과 취소·닫기를 막는다',
    (tester) async {
      final gate = Completer<void>();
      var calls = 0;
      await open(tester, (value) async {
        calls++;
        await gate.future;
      });
      final button = find.byKey(const Key('save-concept-importance-button'));
      final submit = tester.widget<FilledButton>(button).onPressed!;
      submit();
      submit();
      await tester.pump();
      expect(calls, 1);
      expect(tester.widget<FilledButton>(button).onPressed, null);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('cancel-concept-importance-button')),
            )
            .onPressed,
        null,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('concept-importance-field')))
            .onChanged,
        null,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const Key('concept-importance-dialog')),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('concept-importance-dialog')), findsNothing);
      expect(tester.takeException(), null);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
