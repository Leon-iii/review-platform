import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';

Future<
  ({String sessionId, String attemptId, String folderId, Question question})
>
createWrongQuiz(
  AppDatabase db, {
  QuestionType type = QuestionType.shortAnswer,
  AnswerFeedbackTiming timing = AnswerFeedbackTiming.afterCompletion,
  bool unknown = false,
  bool correct = false,
  String submittedAnswer = '다른 용어',
  List<String> acceptableAnswers = const ['용어'],
  bool caseSensitive = false,
  bool whitespaceSensitive = false,
}) async {
  final folder = await DriftFolderRepository(db).createFolder(name: '정답 등록');
  final questions = DriftQuestionRepository(db);
  final questionId = await questions.createQuestion(
    QuestionDraft(
      folderId: folder,
      type: type,
      prompt: '정답 등록 테스트 문제',
      explanation: '정답 등록 테스트 해설',
      caseSensitive: caseSensitive,
      whitespaceSensitive: whitespaceSensitive,
      correctOrder: type == QuestionType.ordering ? const [1, 2, 3] : const [],
      choices: type == QuestionType.ordering
          ? const [
              QuestionChoiceDraft(text: '시작', isCorrect: true),
              QuestionChoiceDraft(text: '처리', isCorrect: true),
              QuestionChoiceDraft(text: '종료', isCorrect: true),
            ]
          : type == QuestionType.multipleChoice ||
                type == QuestionType.trueFalse
          ? [
              QuestionChoiceDraft(
                text: type == QuestionType.trueFalse ? 'O' : '기존 정답',
                isCorrect: true,
              ),
              QuestionChoiceDraft(
                text: type == QuestionType.trueFalse ? 'X' : '제출한 선택지',
                isCorrect: false,
              ),
            ]
          : const [],
      acceptableAnswers:
          type == QuestionType.shortAnswer || type == QuestionType.essay
          ? acceptableAnswers
          : const [],
    ),
  );
  final question = (await questions.getQuestion(questionId))!;
  final quizzes = DriftQuizRepository(db);
  final session = await quizzes.createSession(
    filter: QuizFilter(
      rootFolderId: folder,
      enabledQuestionTypes: {type},
      questionCount: 1,
      feedbackTiming: timing,
    ),
    questions: [question],
  );
  final attempt = await DriftAttemptRepository(db).recordAttempt(
    AttemptDraft(
      questionId: question.id,
      sessionId: session,
      response: unknown
          ? {'isUnknown': true}
          : type == QuestionType.ordering
          ? {
              'orderedChoiceIds': correct
                  ? question.correctChoiceIds
                  : question.correctChoiceIds.reversed.toList(),
            }
          : question.choices.isNotEmpty
          ? {'selectedChoiceId': question.choices[correct ? 0 : 1].id}
          : {'textAnswer': correct ? acceptableAnswers.first : submittedAnswer},
      questionSnapshot: QuestionSnapshot.fromQuestion(question),
      score: correct ? 1 : 0,
      maxScore: 1,
      gradingType: GradingType.values.first,
      durationMs: 1200,
    ),
  );
  final item = (await quizzes.getSession(session))!.items.single;
  await quizzes.linkAttempt(
    sessionId: session,
    itemId: item.id,
    attemptId: attempt,
  );
  return (
    sessionId: session,
    attemptId: attempt,
    folderId: folder,
    question: question,
  );
}
