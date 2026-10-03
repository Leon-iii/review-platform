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
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/services/quiz_builder.dart';
import 'package:review_platform/features/study/result/quiz_result_view_model.dart';
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
  for (final type in [
    QuestionType.multipleChoice,
    QuestionType.trueFalse,
    QuestionType.shortAnswer,
  ]) {
    for (final timing in AnswerFeedbackTiming.values) {
      testWidgets(
        '${type.name} ${timing.name}: 모름을 0점으로 기록·재개·복습하고 결과에서 구분한다',
        (tester) async {
          final database = AppDatabase(NativeDatabase.memory());
          addTearDown(database.close);
          final folders = DriftFolderRepository(database);
          final folder = await folders.createFolder(name: '모름 복습');
          final questions = DriftQuestionRepository(database);
          final quizzes = DriftQuizRepository(database);
          final attempts = DriftAttemptRepository(database);
          final items = <Question>[];
          for (var index = 0; index < 2; index++) {
            final id = await questions.createQuestion(
              QuestionDraft(
                folderId: folder,
                type: type,
                prompt: '모름 테스트 ${index + 1}',
                explanation: '모름 문제의 해설',
                choices: type == QuestionType.shortAnswer
                    ? const []
                    : [
                        QuestionChoiceDraft(
                          text: type == QuestionType.trueFalse ? 'O' : '정답 선택지',
                          isCorrect: true,
                        ),
                        QuestionChoiceDraft(
                          text: type == QuestionType.trueFalse ? 'X' : '오답 선택지',
                          isCorrect: false,
                        ),
                      ],
                acceptableAnswers: type == QuestionType.shortAnswer
                    ? const ['정답']
                    : const [],
              ),
            );
            items.add((await questions.getQuestion(id))!);
          }
          final sessionId = await quizzes.createSession(
            filter: QuizFilter(
              rootFolderId: folder,
              enabledQuestionTypes: {type},
              questionCount: 2,
              shuffle: false,
              feedbackTiming: timing,
            ),
            questions: items,
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
                appDatabaseProvider.overrideWithValue(database),
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
          router.go(AppRoutes.studySession(sessionId));
          await tester.pumpAndSettle();
          Future<void> unknown() async {
            final button = find.byKey(const Key('unknown-answer-button'));
            await tester.ensureVisible(button);
            await tester.tap(button);
            await tester.pumpAndSettle();
          }

          final control = find.byKey(
            type == QuestionType.trueFalse
                ? const Key('true-false-o-button')
                : const Key('submit-answer-button'),
          );
          expect(
            tester
                .getTopLeft(find.byKey(const Key('unknown-answer-button')))
                .dy,
            greaterThan(tester.getBottomLeft(control).dy),
          );
          // No choice/text is required, including short-answer questions.
          await unknown();
          expect(find.text('모름 테스트 2'), findsOneWidget);
          final first = (await attempts.getAttemptsForSession(sessionId))
              .single;
          expect(first.isUnknown, isTrue);
          expect(first.response, {'isUnknown': true});
          expect(first.score, 0);
          expect(first.maxScore, 1);
          expect(
            find.text('모름으로 기록했어요.'),
            timing == AnswerFeedbackTiming.immediate
                ? findsOneWidget
                : findsNothing,
          );
          // The marker and progress survive exiting and resuming a session.
          router.go(AppRoutes.home);
          await tester.pumpAndSettle();
          router.go(AppRoutes.studySession(sessionId));
          await tester.pumpAndSettle();
          expect(find.text('모름 테스트 2'), findsOneWidget);
          // A previous correct selection/input must not count as a guessed answer.
          if (type == QuestionType.multipleChoice) {
            await tester.tap(
              find.byKey(Key('choice-${items[1].choices.first.id}')),
            );
            await tester.pumpAndSettle();
          } else if (type == QuestionType.shortAnswer) {
            final details = (await quizzes.getSession(sessionId))!;
            await tester.enterText(
              find.byKey(Key('answer-${details.items[1].id}')),
              '정답',
            );
          }
          await unknown();
          expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
          final saved = await attempts.getAttemptsForSession(sessionId);
          expect(saved, hasLength(2));
          expect(
            saved.every(
              (attempt) =>
                  attempt.isUnknown &&
                  attempt.score == 0 &&
                  attempt.maxScore == 1,
            ),
            isTrue,
          );
          expect(
            saved.every((attempt) => attempt.response.length == 1),
            isTrue,
          );
          expect(
            (await quizzes.getSession(sessionId))!.session.finishedAt,
            isNotNull,
          );
          final summary = await container.read(
            quizResultProvider(sessionId).future,
          );
          expect(summary.correctCount, 0);
          expect(summary.accuracyPercent, 0);
          expect(summary.wrongAttempts, hasLength(2));
          final card = find.byKey(Key('quiz-answer-result-${items.first.id}'));
          await tester.ensureVisible(card);
          await tester.tap(card);
          await tester.pumpAndSettle();
          expect(find.text('내 답: 모름'), findsOneWidget);
          expect(find.text('해설: 모름 문제의 해설'), findsOneWidget);
          final retry = await QuizBuilder(folders, questions, quizzes, attempts)
              .build(
                QuizFilter(
                  rootFolderId: folder,
                  enabledQuestionTypes: {type},
                  questionCount: 10,
                  onlyWrongQuestions: true,
                ),
              );
          expect(retry.questionCount, 2);
          expect(tester.takeException(), isNull);
        },
        variant: platforms,
      );
    }
  }
}
