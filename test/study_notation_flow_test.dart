import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_documents.dart';
import 'support/fake_sync.dart';

void main() {
  testWidgets(
    '수식 개념·문제 편집과 풀이·결과까지 원문과 첨자를 유지한다',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sources = DriftSourceRepository(db);
      final questions = DriftQuestionRepository(db);
      final quizzes = DriftQuizRepository(db);
      const title = r'성능 (Performance) \(\mathrm{Performance}_{X}\)';
      const content =
          r'실행 시간 \(T_{X}\)와 성능의 관계는 \[\mathrm{Performance}_{X}=\frac{1}{T_{X}}\]이다.';
      const prompt = r'\(\mathrm{Performance}_{X}\)를 구하는 식은 무엇인가?';
      const answer = r'\(\frac{1}{T_{X}}\)';
      final folder = await DriftFolderRepository(db)
          .createFolder(name: '수식 자료');
      final source = await sources.createSource(folderId: folder, name: '성능');
      final concept = await sources.addConcept(
        sourceId: source.source.id,
        title: title,
        content: content,
      );
      final id = await questions.createQuestion(
        QuestionDraft(
          folderId: folder,
          type: QuestionType.multipleChoice,
          prompt: prompt,
          explanation: content,
          choices: const [
            QuestionChoiceDraft(text: answer, isCorrect: true),
            QuestionChoiceDraft(text: r'\(T_{X}^{2}\)', isCorrect: false),
          ],
        ),
        primaryConceptId: concept.id,
      );
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 900),
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
            remoteDocumentApiProvider.overrideWithValue(
              FakeConceptRevisionApi(),
            ),
          ],
          child: const ReviewApp(),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpAndSettle();
      final router = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      ).read(routerProvider);
      Future<void> tap(Finder finder) async {
        FocusManager.instance.primaryFocus?.unfocus();
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      router.go(AppRoutes.documentsForSource(folder, source.source.id));
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsWidgets);
      await tap(find.byKey(Key('concept-menu-${concept.id}')));
      await tap(find.text('수정'));
      final conceptInput = find.byKey(const Key('concept-content-field'));
      expect(tester.widget<TextFormField>(conceptInput).initialValue, content);
      await tester.enterText(conceptInput, '$content\n추가 설명.');
      await tap(find.byKey(const Key('save-concept-button')));
      final stored = (await tester.runAsync(
        () => sources.getSourceWithConcepts(source.source.id),
      ))!.concepts.single;
      expect(stored.title, title);
      expect(stored.content, '$content\n추가 설명.');

      router.go(AppRoutes.editQuestion(id));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('question-prompt-field'));
      expect(tester.widget<TextFormField>(field).controller!.text, prompt);
      await tester.enterText(field, '$prompt 정답을 선택해라.');
      await tap(find.byKey(const Key('save-question-button')));
      final question = (await tester.runAsync(
        () => questions.getQuestion(id),
      ))!;
      expect(question.prompt, '$prompt 정답을 선택해라.');
      expect(question.choices.first.text, answer);
      expect(question.explanation, content);
      final snapshot = QuestionSnapshot.fromJson(
        QuestionSnapshot.fromQuestion(question).toJson(),
      );
      expect(snapshot.choices.first.text, answer);
      expect(snapshot.explanation, content);
      final sessionId = (await tester.runAsync(
        () => quizzes.createSession(
          filter: QuizFilter(
            rootFolderId: folder,
            enabledQuestionTypes: const {QuestionType.multipleChoice},
            questionCount: 1,
            feedbackTiming: AnswerFeedbackTiming.afterCompletion,
          ),
          questions: [question],
        ),
      ))!;
      router.go(AppRoutes.studySession(sessionId));
      await tester.pumpAndSettle();
      expect(
        find.byType(Math),
        findsNWidgets(3),
      ); // Prompt + choices, never reveal the explanation.
      await tap(find.byKey(Key('choice-${question.choices.first.id}')));
      await tap(find.byKey(const Key('submit-answer-button')));
      expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      await tap(find.byKey(Key('quiz-answer-result-$id')));
      expect(find.byType(Math), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
