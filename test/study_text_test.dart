import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/shared/widgets/study_text.dart';

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });

  Future<void> open(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );

  testWidgets('일반 텍스트 및 PC 선택 영역을 유지한다', (tester) async {
    await open(
      tester,
      const SelectionArea(child: StudyText('한국어 (English term)')),
    );
    expect(find.text('한국어 (English term)'), findsOneWidget);
    expect(find.byType(Math), findsNothing);
    await open(tester, const StudyText('편집 전 원문', selectable: true));
    expect(find.byType(SelectableText), findsOneWidget);
  }, variant: platforms);

  testWidgets('수식 첨자를 렌더링하고 좁은 화면·200%·테마에서 넘치지 않는다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const source =
        r'성능 (Performance) \(\mathrm{Performance}_{X}\)의 정의이다. '
        r'\[a_{i,j}^{(k)} = \frac{b^{2}}{\sqrt{c_{n}}} + 123456789012345678901234567890\]';
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        await open(
          tester,
          const Padding(
            padding: EdgeInsets.all(16),
            child: SelectionArea(child: StudyText(source)),
          ),
          scale: scale,
          brightness: brightness,
        );
        await tester.pumpAndSettle();
        final maths = tester.widgetList<Math>(find.byType(Math)).toList();
        expect(maths, hasLength(2));
        expect(
          maths.every((math) => math.ast != null && math.parseError == null),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        final horizontal = find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        );
        expect(horizontal, findsNWidgets(2));
        await tester.drag(horizontal.last, const Offset(-120, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  }, variant: platforms);

  testWidgets('잘못된 LaTeX는 버리지 않고 원문으로 표시한다', (tester) async {
    const source = r'앞 \(\unknownCommand{X}\) 뒤';
    await open(tester, const StudyText(source));
    await tester.pumpAndSettle();
    expect(find.text(r'\(\unknownCommand{X}\)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('수식을 길게 눌러 JSON 전송 전과 같은 LaTeX를 복사한다', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const source = r'\(\mathrm{Performance}_{X}\)';
    await open(tester, const StudyText(source));
    await tester.longPress(find.byType(Math));
    await tester.pumpAndSettle();
    expect(find.text('수식 원문'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.text('LaTeX 복사'));
    await tester.pumpAndSettle();
    expect(copied, source);
  }, variant: platforms);

  testWidgets('텍스트 변경 시 캐시된 수식도 갱신한다', (tester) async {
    await open(tester, const StudyText(r'\(x_{i}\)'));
    final first = tester.widget<Math>(find.byType(Math)).ast;
    await open(tester, const StudyText(r'\(x^{i}\)'));
    expect(tester.widget<Math>(find.byType(Math)).ast, isNot(same(first)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('수식은 키보드와 접근성 동작으로 원문을 확인할 수 있다', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await open(tester, const StudyText(r'\(a_{i,j}^{(k)}\)'));
      expect(find.bySemanticsLabel(r'수식: a_{i,j}^{(k)}'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('수식 원문'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });
}
