import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/services/quiz_builder.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';

void main() {
  late AppDatabase database;
  late DriftFolderRepository folderRepository;
  late DriftQuestionRepository questionRepository;
  late DriftQuizRepository quizRepository;
  late DriftAttemptRepository attemptRepository;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    folderRepository = DriftFolderRepository(database);
    questionRepository = DriftQuestionRepository(database);
    quizRepository = DriftQuizRepository(database);
    attemptRepository = DriftAttemptRepository(database);
  });

  tearDown(() => database.close());

  test('하위 폴더를 포함하고 제외 폴더를 제거해 세션을 구성한다', () async {
    final rootId = await folderRepository.createFolder(name: '전체');
    final childId = await folderRepository.createFolder(
      name: '포함',
      parentId: rootId,
    );
    final excludedId = await folderRepository.createFolder(
      name: '제외',
      parentId: rootId,
    );

    final rootQuestionId = await _createShortQuestion(
      questionRepository,
      rootId,
      '루트 문제',
    );
    final childQuestionId = await _createShortQuestion(
      questionRepository,
      childId,
      '하위 문제',
    );
    await _createShortQuestion(questionRepository, excludedId, '제외 문제');

    final builder = QuizBuilder(
      folderRepository,
      questionRepository,
      quizRepository,
      attemptRepository,
      random: Random(7),
    );
    final result = await builder.build(
      QuizFilter(
        rootFolderId: rootId,
        excludedFolderIds: {excludedId},
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 10,
        shuffle: false,
      ),
    );
    final details = await quizRepository.getSession(result.sessionId);

    expect(result.questionCount, 2);
    expect(details, isNotNull);
    expect(
      details!.items.map((item) => item.questionId),
      containsAll([rootQuestionId, childQuestionId]),
    );
    expect(
      details.items.map((item) => item.questionSnapshot.prompt),
      isNot(contains('제외 문제')),
    );
  });

  test('문제 스냅샷과 풀이 기록을 보존하고 완료 세션을 재개한다', () async {
    final folderId = await folderRepository.createFolder(name: '학습');
    final questionId = await _createShortQuestion(
      questionRepository,
      folderId,
      '원본 문제',
    );
    final sessionId = await quizRepository.createSession(
      filter: QuizFilter(
        rootFolderId: folderId,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [(await questionRepository.getQuestion(questionId))!],
    );

    await questionRepository.updateQuestion(
      questionId,
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        prompt: '수정된 문제',
        acceptableAnswers: const ['새 정답'],
      ),
    );
    final beforeAttempt = await quizRepository.getSession(sessionId);
    final item = beforeAttempt!.items.single;
    expect(item.questionSnapshot.prompt, '원본 문제');

    final attemptId = await attemptRepository.recordAttempt(
      AttemptDraft(
        questionId: questionId,
        sessionId: sessionId,
        response: const {'textAnswer': '정답'},
        questionSnapshot: item.questionSnapshot,
        score: 1,
        maxScore: 1,
        gradingType: GradingType.local,
        durationMs: 1200,
      ),
    );
    await quizRepository.linkAttempt(
      sessionId: sessionId,
      itemId: item.id,
      attemptId: attemptId,
    );

    final resumed = await quizRepository.resumeSession(sessionId);
    final attempts = await attemptRepository.getAttemptsForSession(sessionId);
    expect(resumed!.session.completedQuestions, 1);
    expect(resumed.session.finishedAt, isNotNull);
    expect(resumed.items.single.attemptId, attemptId);
    expect(attempts, hasLength(1));
    expect(attempts.single.questionSnapshot.prompt, '원본 문제');
    expect(attempts.single.response, {'textAnswer': '정답'});
  });

  test('각 문제의 가장 최근 풀이가 오답인 문제만 다시 출제한다', () async {
    final folderId = await folderRepository.createFolder(name: '오답 학습');
    final wrongQuestionId = await _createShortQuestion(
      questionRepository,
      folderId,
      '틀린 문제',
    );
    final correctQuestionId = await _createShortQuestion(
      questionRepository,
      folderId,
      '맞힌 문제',
    );
    final questions = [
      (await questionRepository.getQuestion(wrongQuestionId))!,
      (await questionRepository.getQuestion(correctQuestionId))!,
    ];
    final sourceSessionId = await quizRepository.createSession(
      filter: QuizFilter(
        rootFolderId: folderId,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 2,
      ),
      questions: questions,
    );
    final sourceSession = await quizRepository.getSession(sourceSessionId);
    for (final item in sourceSession!.items) {
      final isWrong = item.questionId == wrongQuestionId;
      final attemptId = await attemptRepository.recordAttempt(
        AttemptDraft(
          questionId: item.questionId,
          sessionId: sourceSessionId,
          response: const {'textAnswer': '답'},
          questionSnapshot: item.questionSnapshot,
          score: isWrong ? 0 : 1,
          maxScore: 1,
          gradingType: GradingType.local,
          durationMs: 100,
        ),
      );
      await quizRepository.linkAttempt(
        sessionId: sourceSessionId,
        itemId: item.id,
        attemptId: attemptId,
      );
    }

    final builder = QuizBuilder(
      folderRepository,
      questionRepository,
      quizRepository,
      attemptRepository,
      random: Random(3),
    );
    final retry = await builder.build(
      QuizFilter(
        rootFolderId: folderId,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 10,
        onlyWrongQuestions: true,
      ),
    );
    final retrySession = await quizRepository.getSession(retry.sessionId);

    expect(retrySession!.items, hasLength(1));
    expect(retrySession.items.single.questionId, wrongQuestionId);
  });
}

Future<String> _createShortQuestion(
  DriftQuestionRepository repository,
  String folderId,
  String prompt,
) {
  return repository.createQuestion(
    QuestionDraft(
      folderId: folderId,
      type: QuestionType.shortAnswer,
      prompt: prompt,
      acceptableAnswers: const ['정답'],
    ),
  );
}
