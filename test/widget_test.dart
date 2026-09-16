import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/repositories/folder_repository.dart';

void main() {
  late AppDatabase database;

  setUp(() => database = AppDatabase(NativeDatabase.memory()));
  tearDown(() => database.close());

  Widget buildApp() => ProviderScope(
    overrides: [appDatabaseProvider.overrideWithValue(database)],
    child: const ReviewApp(),
  );

  testWidgets('홈 화면에 MVP 학습 요약과 시작 기능이 표시된다', (tester) async {
    await tester.pumpWidget(buildApp());

    expect(find.text('오늘 푼 문제'), findsOneWidget);
    expect(find.text('최근 정답률'), findsOneWidget);
    expect(find.text('문제 풀기'), findsOneWidget);
    expect(find.text('최근 오답'), findsOneWidget);
    expect(find.text('최근 학습'), findsOneWidget);
  });

  testWidgets('좁은 화면에서 NavigationBar로 화면을 전환한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildApp());

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-view')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('통계 화면에 기간·폴더·최근 오답 영역을 표시한다', (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('statistics-view')), findsOneWidget);
    expect(find.text('기간별 정답률'), findsOneWidget);
    expect(find.text('폴더별 정답률'), findsOneWidget);
    expect(find.text('최근 오답'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('문제 관리에서 새 폴더를 생성한다', (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '전자기학');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('전자기학'), findsOneWidget);
    expect(find.text('전자기학 폴더를 생성했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('폴더에 객관식 문제를 추가한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await DriftFolderRepository(database).createFolder(name: '전자기학');
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('전자기학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-question-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('question-prompt-field')),
      '전기장의 SI 단위는?',
    );
    await tester.enterText(find.byKey(const Key('choice-field-0')), 'V/m');
    await tester.enterText(find.byKey(const Key('choice-field-1')), 'A/m');
    await tester.enterText(find.byKey(const Key('choice-field-2')), 'T');
    await tester.enterText(find.byKey(const Key('choice-field-3')), 'Wb');
    await tester.tap(find.byKey(const Key('save-question-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('save-question-button')), findsNothing);
    expect(find.text('전기장의 SI 단위는?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('넓은 화면에서 NavigationRail을 사용한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildApp());

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material 3와 시스템 테마를 사용한다', (tester) async {
    await tester.pumpWidget(buildApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.useMaterial3, isTrue);
    expect(app.darkTheme?.useMaterial3, isTrue);
  });
}
