import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/main.dart';

void main() {
  testWidgets('홈 화면에 복습 메뉴 4개가 표시된다', (tester) async {
    await tester.pumpWidget(const ReviewApp());

    expect(find.text('문제 풀기'), findsOneWidget);
    expect(find.text('문제 관리'), findsOneWidget);
    expect(find.text('통계'), findsOneWidget);
    expect(find.text('설정'), findsOneWidget);
    expect(find.byType(FilledButton), findsNWidgets(4));
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('메뉴를 누르면 준비 중 안내가 표시된다', (tester) async {
    await tester.pumpWidget(const ReviewApp());

    await tester.tap(find.text('문제 풀기'));
    await tester.pump();

    expect(find.text('문제 풀기 기능은 준비 중이에요.'), findsOneWidget);
  });

  testWidgets('Material 3 테마를 사용한다', (tester) async {
    await tester.pumpWidget(const ReviewApp());

    final context = tester.element(find.byType(HomeScreen));
    expect(Theme.of(context).useMaterial3, isTrue);
  });

  testWidgets('작은 Android 화면에서도 레이아웃이 넘치지 않는다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ReviewApp());

    expect(tester.takeException(), isNull);
    expect(find.byType(FilledButton), findsNWidgets(4));
  });
}
