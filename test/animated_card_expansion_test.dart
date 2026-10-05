import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/shared/widgets/animated_card_expansion.dart';

void main() {
  testWidgets('본문 높이와 투명도가 중간 프레임을 거쳐 펼쳐지고 접힌다', (tester) async {
    var expanded = false;
    late StateSetter update;
    const key = Key('body');
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: AnimatedCardBody(
                  key: key,
                  expanded: expanded,
                  child: const SizedBox(height: 200, child: Text('본문')),
                ),
              ),
            );
          },
        ),
      ),
    );
    final body = find.byKey(key);
    expect(tester.getSize(body).height, 0);
    expect(find.text('본문'), findsNothing);
    update(() => expanded = true);
    await tester.pump();
    expect(tester.getSize(body).height, 0);
    await tester.pump(const Duration(milliseconds: 80));
    final height = tester.getSize(body).height;
    expect(height, greaterThan(0));
    expect(height, lessThan(200));
    final fade = tester.widget<FadeTransition>(
      find.descendant(of: body, matching: find.byType(FadeTransition)),
    );
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, 200);
    update(() => expanded = false);
    await tester.pump();
    expect(find.text('본문'), findsOneWidget);
    expect(tester.getSize(body).height, 200);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(body).height, greaterThan(0));
    expect(tester.getSize(body).height, lessThan(200));
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, 0);
    expect(find.text('본문'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('연속 반전과 데이터 갱신은 현재 높이와 본문 상태를 유지한다', (tester) async {
    var expanded = true;
    var text = '기존';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: AnimatedCardBody(
                  key: const Key('body'),
                  expanded: expanded,
                  child: _StatefulDetails(text: text),
                ),
              ),
            );
          },
        ),
      ),
    );
    final body = find.byKey(const Key('body'));
    final details = tester.state(find.byType(_StatefulDetails));
    expect(tester.getSize(body).height, 200);
    update(() => expanded = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final before = tester.getSize(body).height;
    update(() {
      expanded = true;
      text = '수정';
    });
    await tester.pump();
    expect(tester.getSize(body).height, closeTo(before, 0.01));
    expect(tester.state(find.byType(_StatefulDetails)), same(details));
    expect(find.text('수정'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 25));
    expect(tester.getSize(body).height, greaterThan(before));
    update(() => expanded = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    final reversing = tester.getSize(body).height;
    update(() => expanded = true);
    await tester.pump();
    expect(tester.getSize(body).height, closeTo(reversing, 0.01));
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, 200);
    expect(tester.state(find.byType(_StatefulDetails)), same(details));
    expect(tester.takeException(), isNull);
  });

  testWidgets('접히는 본문의 조작과 접근성을 즉시 비활성화한다', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      var expanded = true;
      var taps = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return AnimatedCardBody(
                  expanded: expanded,
                  child: SizedBox(
                    height: 200,
                    child: TextButton(
                      key: const Key('action'),
                      onPressed: () => taps++,
                      child: const Text('본문 동작'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(_semanticsContains(tester, '본문 동작'), true);
      update(() => expanded = false);
      await tester.pump();
      expect(find.byKey(const Key('action')), findsOneWidget);
      expect(_semanticsContains(tester, '본문 동작'), false);
      await tester.tap(find.byKey(const Key('action')), warnIfMissed: false);
      expect(taps, 0);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('action')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('애니메이션 줄이기 설정을 켜면 즉시 전환한다', (tester) async {
    var expanded = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Align(
                alignment: Alignment.topLeft,
                child: AnimatedCardBody(
                  key: const Key('body'),
                  expanded: expanded,
                  child: const SizedBox(height: 200),
                ),
              );
            },
          ),
        ),
      ),
    );
    update(() => expanded = true);
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('body'))).height, 200);
    update(() => expanded = false);
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('body'))).height, 0);
    expect(tester.binding.hasScheduledFrame, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('헤더 높이도 부드럽게 변화한다', (tester) async {
    var height = 40.0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: AnimatedCardHeader(
                key: const Key('header'),
                child: SizedBox(height: height, width: 300),
              ),
            );
          },
        ),
      ),
    );
    update(() => height = 100);
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('header'))).height, 40);
    await tester.pump(const Duration(milliseconds: 80));
    final middle = tester.getSize(find.byKey(const Key('header'))).height;
    expect(middle, greaterThan(40));
    expect(middle, lessThan(100));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('header'))).height, 100);
  });
}

bool _semanticsContains(WidgetTester tester, String label) {
  bool contains(SemanticsNode node) {
    if (node.getSemanticsData().label == label) return true;
    var found = false;
    node.visitChildren((child) {
      found = contains(child);
      return !found;
    });
    return found;
  }

  final root = tester
      .binding
      .renderViews
      .single
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  return contains(root);
}

class _StatefulDetails extends StatefulWidget {
  const _StatefulDetails({required this.text});
  final String text;
  @override
  State<_StatefulDetails> createState() => _StatefulDetailsState();
}

class _StatefulDetailsState extends State<_StatefulDetails> {
  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 200, child: Text(widget.text));
}
