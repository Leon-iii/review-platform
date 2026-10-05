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
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';

import 'support/fake_sync.dart';

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  for (final timing in AnswerFeedbackTiming.values) {
    for (final isCorrect in [true, false]) {
      testWidgets(
        '서술형 ${timing.name} 정답=$isCorrect: 답안 저장·재개 후 자기 채점하며 통계는 채점 후 기록한다',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final folder = await DriftFolderRepository(db)
              .createFolder(name: '서술형');
          final questions = DriftQuestionRepository(db);
          final quizzes = DriftQuizRepository(db);
          final attempts = DriftAttemptRepository(db);
          final essayId = await questions.createQuestion(
            QuestionDraft(
              folderId: folder,
              type: QuestionType.essay,
              prompt: '캐시 동작을 설명하시오.',
              acceptableAnswers: const ['객체가 캐시에 있으면 즉시 반환한다.'],
              explanation: '캐시 히트 해설',
            ),
          );
          final shortId = await questions.createQuestion(
            QuestionDraft(
              folderId: folder,
              type: QuestionType.shortAnswer,
              prompt: '캐시에 객체가 있는 상태의 용어는?',
              acceptableAnswers: const ['캐시 히트'],
            ),
          );
          final session = await quizzes.createSession(
            filter: QuizFilter(
              rootFolderId: folder,
              enabledQuestionTypes: const {
                QuestionType.essay,
                QuestionType.shortAnswer,
              },
              questionCount: 2,
              shuffle: false,
              feedbackTiming: timing,
            ),
            questions: [
              (await questions.getQuestion(essayId))!,
              (await questions.getQuestion(shortId))!,
            ],
          );
          await tester.binding.setSurfaceSize(
            defaultTargetPlatform == TargetPlatform.windows
                ? const Size(1100, 900)
                : const Size(390, 800),
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
              ],
              child: const ReviewApp(),
            ),
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          });
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(
            tester.element(find.byKey(const Key('home-view'))),
          );
          final router = container.read(routerProvider);
          router.go(AppRoutes.studySession(session));
          await tester.pumpAndSettle();
          final initial = (await quizzes.getSession(session))!;
          final input = find.byKey(Key('answer-${initial.items.first.id}'));
          final field = tester.widget<TextField>(
            find.descendant(of: input, matching: find.byType(TextField)),
          );
          expect(field.maxLines, 8);
          expect(field.textInputAction, TextInputAction.newline);
          expect(field.onSubmitted, isNull);
          expect(find.text('객체가 캐시에 있으면 즉시 반환한다.'), findsNothing);
          await tester.enterText(input, '내 표현으로 설명한 답안\n줄바꿈도 보존');
          Future<void> tap(Finder target) async {
            await tester.ensureVisible(target);
            await tester.tap(target);
            await tester.pumpAndSettle();
          }

          await tap(find.byKey(const Key('submit-answer-button')));
          expect(await attempts.getAttemptsForSession(session), isEmpty);
          expect(
            (await quizzes.getSession(session))!
                .items
                .first
                .pendingEssayResponse!['textAnswer'],
            '내 표현으로 설명한 답안\n줄바꿈도 보존',
          );
          if (timing == AnswerFeedbackTiming.afterCompletion) {
            expect(find.text('객체가 캐시에 있으면 즉시 반환한다.'), findsNothing);
            expect(find.text('캐시에 객체가 있는 상태의 용어는?'), findsOneWidget);
            await tester.enterText(
              find.byKey(Key('answer-${initial.items.last.id}')),
              '캐시 히트',
            );
            await tap(find.byKey(const Key('submit-answer-button')));
            expect(find.text('정답이에요.'), findsNothing);
          }
          expect(find.text('자기 채점'), findsOneWidget);
          expect(find.text('객체가 캐시에 있으면 즉시 반환한다.'), findsOneWidget);
          expect(find.text('내 표현으로 설명한 답안\n줄바꿈도 보존'), findsOneWidget);
          expect(find.byKey(const Key('unknown-answer-button')), findsNothing);
          router.go(AppRoutes.home);
          await tester.pumpAndSettle();
          router.go(AppRoutes.studySession(session));
          await tester.pumpAndSettle();
          expect(find.text('자기 채점'), findsOneWidget);
          await tap(
            find.byKey(
              Key(isCorrect ? 'essay-grade-correct' : 'essay-grade-incorrect'),
            ),
          );
          if (timing == AnswerFeedbackTiming.immediate) {
            expect(find.text('캐시에 객체가 있는 상태의 용어는?'), findsOneWidget);
            await tester.enterText(
              find.byKey(Key('answer-${initial.items.last.id}')),
              '캐시 히트',
            );
            await tap(find.byKey(const Key('submit-answer-button')));
          }
          expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
          final saved = await attempts.getAttemptsForSession(session);
          expect(saved, hasLength(2));
          final essay = saved.singleWhere((a) => a.questionId == essayId);
          expect(essay.score, isCorrect ? 1 : 0);
          expect(essay.gradingType, GradingType.manual);
          expect(essay.response['selfAssessed'], true);
          expect(essay.response['textAnswer'], '내 표현으로 설명한 답안\n줄바꿈도 보존');
          expect(
            saved.singleWhere((a) => a.questionId == shortId).gradingType,
            GradingType.local,
          );
          expect(tester.takeException(), isNull);
        },
        variant: platforms,
      );
    }
  }
}
