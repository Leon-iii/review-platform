import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/question_list/question_management_card.dart';
import 'package:review_platform/features/library/question_list/question_management_filter.dart';
import 'package:review_platform/features/library/question_list/question_management_list.dart';

Question _question(
  int index, {
  QuestionStatus status = QuestionStatus.approved,
  ConceptImportance importance = ConceptImportance.medium,
}) {
  final id = 'q${index.toString().padLeft(4, '0')}';
  return Question(
    id: id,
    folderId: 'folder',
    type: QuestionType.multipleChoice,
    status: status,
    importance: importance,
    prompt: '문제 $id: 웹 캐시의 동작으로 올바른 것은?',
    explanation: '객체가 캐시에 있으면 바로 반환하고 없으면 원본 서버에서 가져온다.',
    choices: List.generate(
      4,
      (i) => QuestionChoice(
        id: '$id-$i',
        position: i,
        text: '선택지 $i',
        isCorrect: i == 0,
      ),
    ),
    acceptableAnswers: const [],
    difficulty: index % 5 + 1,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
}

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });

  Future<void> open(
    WidgetTester tester,
    List<Question> questions, {
    String folderId = 'folder',
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: QuestionManagementList(
                questions: questions,
                folderId: folderId,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('122개 목록에서 펼침·접힘은 해당 카드만 재빌드한다', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, List.generate(122, _question));
    // The list remains eager; this change deliberately does not add laziness.
    expect(find.byType(QuestionManagementCard), findsNWidgets(122));
    final title = find.byKey(const ValueKey('question-prompt-q0000'));
    final body = find.byKey(const ValueKey('question-details-q0000'));
    final ink = find.byKey(const ValueKey('question-card-q0000'));
    final originalInk = tester.element(ink);
    final originalCards = {
      for (final element in find.byType(QuestionManagementCard).evaluate())
        (element.widget as QuestionManagementCard).question.id: element,
    };
    var cardBuilds = 0;
    var listBuilds = 0;
    final previousCallback = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is QuestionManagementCard) cardBuilds++;
      if (element.widget is QuestionManagementList) listBuilds++;
      previousCallback?.call(element, builtOnce);
    };
    try {
      for (var round = 0; round < 2; round++) {
        cardBuilds = 0;
        listBuilds = 0;
        await tester.tap(title);
        await tester.pump();
        expect(cardBuilds, 1);
        expect(listBuilds, 0);
        await tester.pump(const Duration(milliseconds: 80));
        final openingHeight = tester.getSize(body).height;
        expect(openingHeight, greaterThan(0));
        await tester.pumpAndSettle();
        expect(tester.getSize(body).height, greaterThan(openingHeight));
        expect(tester.element(ink), same(originalInk));
        for (final element in find.byType(QuestionManagementCard).evaluate()) {
          final id = (element.widget as QuestionManagementCard).question.id;
          expect(element, same(originalCards[id]));
        }
        cardBuilds = 0;
        listBuilds = 0;
        await tester.tap(title);
        await tester.pump();
        expect(cardBuilds, 1);
        expect(listBuilds, 0);
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getSize(body).height, greaterThan(0));
        await tester.pumpAndSettle();
        expect(tester.getSize(body).height, 0);
      }
      expect(tester.takeException(), isNull);
    } finally {
      debugOnRebuildDirtyWidget = previousCallback;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, variant: platforms);

  testWidgets('문제 배지 문구·크기·스타일은 펼침 여부와 무관하게 유지된다', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, [_question(0, importance: ConceptImportance.high)]);
    final badges = find.byKey(const ValueKey('question-badges-q0000'));
    final chips = find.descendant(of: badges, matching: find.byType(Chip));
    final initialStyles = tester
        .widgetList<Chip>(chips)
        .map(
          (chip) => (
            (chip.label as Text).data,
            chip.padding,
            chip.labelPadding,
            chip.labelStyle,
            chip.backgroundColor,
            chip.side,
            chip.shape,
          ),
        )
        .toList();
    final initialSizes = [
      for (final element in chips.evaluate())
        tester.getSize(
          find.byElementPredicate((candidate) => identical(candidate, element)),
        ),
    ];
    void expectUnchangedBadges() {
      expect(
        find.descendant(of: badges, matching: find.text('중요도 높음')),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<Chip>(chips)
            .map(
              (chip) => (
                (chip.label as Text).data,
                chip.padding,
                chip.labelPadding,
                chip.labelStyle,
                chip.backgroundColor,
                chip.side,
                chip.shape,
              ),
            )
            .toList(),
        initialStyles,
      );
      expect([
        for (final element in chips.evaluate())
          tester.getSize(
            find.byElementPredicate(
              (candidate) => identical(candidate, element),
            ),
          ),
      ], initialSizes);
    }

    final title = find.byKey(const ValueKey('question-prompt-q0000'));
    final divider = find.byKey(const ValueKey('question-answer-divider-q0000'));
    expectUnchangedBadges();
    expect(divider, findsNothing);
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expectUnchangedBadges();
    await tester.pumpAndSettle();
    expectUnchangedBadges();
    expect(divider, findsOneWidget);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expectUnchangedBadges();
    expect(divider, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('선택·정렬·데이터 갱신과 검색 후에도 펼침 상태를 유지한다', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final questions = List.generate(3, _question);
    await open(tester, questions);
    final title = find.byKey(const ValueKey('question-prompt-q0000'));
    final divider = find.byKey(const ValueKey('question-answer-divider-q0000'));
    await tester.tap(title);
    await tester.pumpAndSettle();
    final card = find.ancestor(
      of: title,
      matching: find.byType(QuestionManagementCard),
    );
    final originalCard = tester.element(card);

    await tester.tap(find.byKey(const ValueKey('select-question-q0000')));
    await tester.pumpAndSettle();
    expect(divider, findsOneWidget);
    expect(tester.element(card), same(originalCard));

    await tester.tap(find.byKey(const Key('question-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is CheckedPopupMenuItem<QuestionManagementSort> &&
            widget.value == QuestionManagementSort.difficulty,
      ),
    );
    await tester.pumpAndSettle();
    expect(divider, findsOneWidget);
    expect(tester.element(card), same(originalCard));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('question-prompt-q0002'))).dy,
      lessThan(tester.getTopLeft(title).dy),
    );

    await open(tester, [
      _question(0, status: QuestionStatus.draft),
      ...questions.skip(1),
    ]);
    expect(divider, findsOneWidget);
    expect(tester.element(card), same(originalCard));
    expect(find.text('미승인'), findsOneWidget);

    final search = find.byKey(const Key('question-search-field'));
    await tester.enterText(search, 'q0001');
    await tester.pumpAndSettle();
    expect(title, findsNothing);
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(divider, findsOneWidget);

    // Clearing the cache on collapse also survives removal/reinsertion.
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    await tester.tap(title);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'q0001');
    await tester.pumpAndSettle();
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(divider, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);

  testWidgets('폴더가 바뀌면 펼침 상태를 초기화한다', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final questions = [_question(0)];
    await open(tester, questions);
    await tester.tap(find.byKey(const ValueKey('question-prompt-q0000')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('question-answer-divider-q0000')),
      findsOneWidget,
    );
    await open(tester, questions, folderId: 'other');
    expect(
      find.byKey(const ValueKey('question-answer-divider-q0000')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: platforms);
}
