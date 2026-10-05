import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/library/question_list/question_management_list.dart';
import 'package:review_platform/features/library/question_list/question_management_filter.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_sync.dart';

void main() {
  late AppDatabase db;
  late DriftQuestionRepository questions;
  late DriftSourceRepository sources;
  late String folder;
  late String other;
  late String ox;
  late String short;
  late String outside;
  late StudyConcept concept;
  late StudySource source;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    questions = DriftQuestionRepository(db);
    sources = DriftSourceRepository(db);
    final folders = DriftFolderRepository(db);
    folder = await folders.createFolder(name: '문제 폴더');
    other = await folders.createFolder(name: '이동 대상');
    source = (await sources.createSource(
      folderId: other,
      name: '네트워크 노트',
    )).source;
    concept = await sources.addConcept(
      sourceId: source.id,
      title: '웹 캐시',
      content: '현재 개념의 실제 본문',
      importance: ConceptImportance.high,
    );
    ox = await questions.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.trueFalse,
        status: QuestionStatus.draft,
        prompt: '캐시에 객체가 있으면 캐시 히트다.',
        explanation: '객체가 없으면 캐시 미스다.',
        difficulty: 2,
        choices: const [
          QuestionChoiceDraft(text: 'O', isCorrect: true),
          QuestionChoiceDraft(text: 'X', isCorrect: false),
        ],
      ),
      primaryConceptId: concept.id,
    );
    short = await questions.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        status: QuestionStatus.draft,
        prompt: '전송 계층 프로토콜 이름은?',
        acceptableAnswers: const ['TCP'],
        difficulty: 4,
      ),
    );
    outside = await questions.createQuestion(
      QuestionDraft(
        folderId: other,
        type: QuestionType.shortAnswer,
        status: QuestionStatus.draft,
        prompt: '다른 폴더 캐시 문제',
        acceptableAnswers: const ['캐시'],
      ),
      primaryConceptId: concept.id,
    );
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1100, 1000)
          : const Size(390, 850),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          isWindowsPlatformProvider.overrideWithValue(false),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(),
          ),
          remoteSyncApiProvider.overrideWithValue(FakeRemoteSyncApi()),
        ],
        child: const ReviewApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    container.read(routerProvider).go(AppRoutes.folder(folder));
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(finder);
      for (var i = 0; i < 35; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle();
  }

  const platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  testWidgets('문제 필터 툴팁·대화상자는 안전한 스크롤 구조에서 접근성을 유지한다', (tester) async {
    final semantics = tester.ensureSemantics();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    try {
      await open(tester);
      final filter = find.byKey(const Key('question-filter-button'));
      final sort = find.byKey(const Key('question-sort-button'));
      // Native Windows AXTree failures are engine logs, not Dart exceptions.
      // Guard the problematic ancestor path, not merely takeException().
      expect(
        find.ancestor(of: filter, matching: find.byType(Viewport)),
        findsNothing,
      );
      await mouse.addPointer(location: const Offset(4, 4));
      for (var round = 0; round < 3; round++) {
        await tester.ensureVisible(filter);
        await tester.pumpAndSettle();
        await mouse.moveTo(tester.getCenter(sort));
        await tester.pump(const Duration(milliseconds: 800));
        await mouse.moveTo(tester.getCenter(filter));
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.text('문제 필터', findRichText: true), findsOneWidget);
        final node = tester.getSemantics(filter);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        if (round == 1) {
          node.owner!.performAction(node.id, SemanticsAction.tap);
        } else {
          await tester.tap(filter, kind: PointerDeviceKind.mouse);
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byKey(const Key('question-type-filter')), findsOneWidget);
        expect(find.byKey(const Key('question-source-filter')), findsOneWidget);
        if (round == 1) {
          // Include a dropdown's overlay route and actual filter application.
          await tester.tap(find.byKey(const Key('question-type-filter')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('O/X').last);
          await tester.pumpAndSettle();
        }
        await tester.tap(
          round == 0
              ? find.widgetWithText(TextButton, '취소')
              : find.byKey(const Key('apply-question-filters')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          tester
              .getSemantics(filter)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        if (round > 0) {
          expect(find.byKey(Key('question-prompt-$ox')), findsOneWidget);
          expect(find.byKey(Key('question-prompt-$short')), findsNothing);
        }
      }
      await mouse.moveTo(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await mouse.removePointer();
      semantics.dispose();
    }
  }, variant: platforms);
  testWidgets('문제 본문은 중간 높이를 거치고 빠른 반전에도 애니메이션이 이어진다', (tester) async {
    await open(tester);
    final title = find.byKey(Key('question-prompt-$ox'));
    final body = find.byKey(Key('question-details-$ox'));
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, 0);
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final opening = tester.getSize(body).height;
    expect(opening, greaterThan(0));
    await tester.pumpAndSettle();
    final opened = tester.getSize(body).height;
    expect(opened, greaterThan(opening));
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final closing = tester.getSize(body).height;
    expect(closing, greaterThan(0));
    expect(closing, lessThan(opened));
    await tester.tap(title);
    await tester.pump();
    expect(tester.getSize(body).height, closeTo(closing, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, closeTo(opened, 0.1));
    expect(find.byKey(Key('question-answer-divider-$ox')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
  testWidgets('문제 박스 클릭으로 펼침·접힘, 배지·구분선·정답 체크를 표시하고 체크박스는 독립 동작한다', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(Key('question-answer-divider-$ox')), findsNothing);
    final badge = find.byKey(Key('question-badges-$ox'));
    expect(
      find.descendant(of: badge, matching: find.text('O/X')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: badge, matching: find.text('난이도 2/5')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: badge, matching: find.text('중요도 높음')),
      findsOneWidget,
    );
    await tap(tester, find.byKey(Key('select-question-$ox')));
    expect(find.byKey(Key('question-answer-divider-$ox')), findsNothing);
    await tap(tester, find.byKey(Key('question-prompt-$ox')));
    for (final section in ['answer', 'explanation', 'source']) {
      expect(find.byKey(Key('question-$section-divider-$ox')), findsOneWidget);
    }
    final card = find.byKey(Key('question-card-$ox'));
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.text('O')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('X')), findsOneWidget);
    expect(find.text('객체가 없으면 캐시 미스다.'), findsOneWidget);
    await tap(tester, find.byKey(Key('question-prompt-$ox')));
    expect(find.byKey(Key('question-explanation-divider-$ox')), findsNothing);
    await tap(tester, find.byKey(Key('question-prompt-$short')));
    expect(find.text('TCP'), findsOneWidget);
    expect(find.text('등록된 해설이 없어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('검색은 현재 폴더만 대상으로 하고 필터 적용·초기화·정렬·선택 해제를 지원한다', (tester) async {
    await open(tester);
    await tap(tester, find.byKey(Key('select-question-$short')));
    final search = find.byKey(const Key('question-search-field'));
    await tester.enterText(search, '캐시');
    await tester.pumpAndSettle();
    expect(find.byKey(Key('question-prompt-$short')), findsNothing);
    expect(find.text('다른 폴더 캐시 문제'), findsNothing);
    expect(find.byKey(const Key('question-selection-actions')), findsNothing);
    await tester.enterText(search, 'TCP');
    await tester.pumpAndSettle();
    expect(find.byKey(Key('question-prompt-$short')), findsOneWidget);
    await tester.enterText(search, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('question-filter-button')));
    await tap(tester, find.byKey(const Key('question-type-filter')));
    await tap(tester, find.text('O/X').last);
    await tap(tester, find.byKey(const Key('apply-question-filters')));
    expect(find.byKey(Key('question-prompt-$short')), findsNothing);
    expect(find.byKey(Key('question-prompt-$ox')), findsOneWidget);
    await tap(tester, find.byKey(const Key('reset-question-filters')));
    expect(find.byKey(Key('question-prompt-$short')), findsOneWidget);
    await tap(tester, find.byKey(const Key('question-sort-button')));
    await tap(
      tester,
      find.ancestor(
        of: find.text('난이도 높은순'),
        matching: find.byType(CheckedPopupMenuItem<QuestionManagementSort>),
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(Key('question-prompt-$short'))).dy,
      lessThan(tester.getTopLeft(find.byKey(Key('question-prompt-$ox'))).dy),
    );
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('선택한 현재 폴더 문제만 일괄 승인·이동하고 삭제는 확인 후 실행한다', (tester) async {
    await open(tester);
    await tap(tester, find.byKey(const Key('select-all-visible-questions')));
    expect(find.text('2개 선택'), findsOneWidget);
    await tap(tester, find.byKey(const Key('approve-selected-questions')));
    expect(
      (await tester.runAsync(() => questions.getQuestion(ox)))!.status,
      QuestionStatus.approved,
    );
    expect(
      (await tester.runAsync(() => questions.getQuestion(short)))!.status,
      QuestionStatus.approved,
    );
    expect(
      (await tester.runAsync(() => questions.getQuestion(outside)))!.status,
      QuestionStatus.draft,
    );
    await tester.enterText(
      find.byKey(const Key('question-search-field')),
      'TCP',
    );
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tap(tester, find.byKey(const Key('select-all-visible-questions')));
    await tap(tester, find.byKey(const Key('delete-selected-questions')));
    expect(find.text('선택한 문제 1개를 삭제하시겠습니까?'), findsOneWidget);
    await tap(tester, find.text('취소'));
    expect(
      await tester.runAsync(() => questions.getQuestion(short)),
      isNotNull,
    );
    await tap(tester, find.byKey(const Key('delete-selected-questions')));
    await tap(
      tester,
      find.byKey(const Key('confirm-delete-selected-questions')),
    );
    expect(await tester.runAsync(() => questions.getQuestion(short)), isNull);
    expect(await tester.runAsync(() => questions.getQuestion(ox)), isNotNull);
    await tester.enterText(find.byKey(const Key('question-search-field')), '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('select-all-visible-questions')));
    await tap(tester, find.byKey(const Key('move-selected-questions')));
    await tester.enterText(
      find.byKey(const Key('folder-picker-search-field')),
      '이동 대상',
    );
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(Key('folder-picker-item-$other')));
    expect(
      (await tester.runAsync(() => questions.getQuestion(ox)))!.folderId,
      other,
    );
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('문제에서 실제 개념을 보고 자료의 해당 개념으로 이동하며 역방향 연결은 폴더를 넘어 조회한다', (
    tester,
  ) async {
    await open(tester);
    await tap(tester, find.byKey(Key('question-prompt-$ox')));
    await tap(
      tester,
      find.byKey(Key('view-question-concept-$ox-${concept.id}')),
    );
    expect(find.text('현재 개념의 실제 본문'), findsOneWidget);
    await tap(tester, find.text('자료에서 보기'));
    expect(find.byKey(const Key('document-import-view')), findsOneWidget);
    expect(find.text('현재 개념의 실제 본문'), findsOneWidget);
    await tap(tester, find.byKey(Key('view-concept-questions-${concept.id}')));
    expect(find.byKey(const Key('concept-questions-view')), findsOneWidget);
    expect(find.byKey(Key('question-prompt-$ox')), findsOneWidget);
    expect(find.byKey(Key('question-prompt-$outside')), findsOneWidget);
    expect(find.byKey(Key('question-prompt-$short')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('좁은 화면·큰 글씨에서 배지와 도구 모음이 줄바꿈되고 필터 대화상자가 스크롤된다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final items = (await tester.runAsync(
      () => questions.watchQuestions(folder).first,
    ))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: QuestionManagementList(questions: items, folderId: folder),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(Key('question-prompt-$ox')));
    await tap(tester, find.byKey(const Key('question-filter-button')));
    expect(find.byKey(const Key('question-difficulty-filter')), findsOneWidget);
    await tap(tester, find.byKey(const Key('apply-question-filters')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('자료 바로가기는 긴 자료에서도 대상 개념 위치로 스크롤한다', (tester) async {
    final last = (await tester.runAsync(() async {
      StudyConcept? result;
      for (var i = 0; i < 12; i++) {
        result = await sources.addConcept(
          sourceId: source.id,
          title: '추가 개념 $i',
          content: List.filled(8, '긴 자료 본문을 확인합니다.').join('\n'),
        );
      }
      return result!;
    }))!;
    await open(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('library-view'))),
    );
    container
        .read(routerProvider)
        .push(
          AppRoutes.documentsForConcept(source.folderId, source.id, last.id),
        );
    await tester.runAsync(() async {
      for (var i = 0; i < 35; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle();
    final target = find.byKey(Key('concept-focus-${last.id}'));
    expect(tester.getTopLeft(target).dy, greaterThanOrEqualTo(0));
    expect(
      tester.getTopLeft(target).dy,
      lessThan(tester.view.physicalSize.height / tester.view.devicePixelRatio),
    );
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}
