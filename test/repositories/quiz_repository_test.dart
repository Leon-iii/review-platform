import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/services/quiz_builder.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

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

  test('중단은 미풀이 문항을 채점하지 않고 종료를 동기화하며 중복 종료·추가 제출을 막는다', () async {
    final folder = await folderRepository.createFolder(name: '중단');
    final questionId = await _createShortQuestion(
      questionRepository,
      folder,
      '종료 문항',
    );
    final sessionId = await quizRepository.createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [(await questionRepository.getQuestion(questionId))!],
    );
    final sync = DriftSyncRepository(database);
    final before = (await sync.getPending()).length;
    await quizRepository.finishSession(sessionId);
    final session = (await quizRepository.getSession(sessionId))!;
    expect(session.session.finishedAt, isNotNull);
    expect(session.session.completedQuestions, 0);
    expect(session.items.single.attemptId, isNull);
    expect(await attemptRepository.getAttemptsForSession(sessionId), isEmpty);
    expect((await sync.getPending()).length, before + 1);
    await quizRepository.finishSession(sessionId);
    expect(
      (await quizRepository.getSession(sessionId))!.session.finishedAt,
      session.session.finishedAt,
    );
    expect((await sync.getPending()).length, before + 1);
    final pushed = (await sync.buildPushBatch()).where(
      (e) => e.entityType == 'quizSession',
    );
    expect(
      pushed.every(
        (e) =>
            e.payload!['finishedAt'] != null &&
            e.payload!['completedQuestions'] == 0,
      ),
      isTrue,
    );
    await expectLater(
      quizRepository.linkAttempt(
        sessionId: sessionId,
        itemId: session.items.single.id,
        attemptId: 'not-created',
      ),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      quizRepository.finishSession('missing'),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('난이도와 문제 유형을 함께 필터링하고 세션 재개 시 설정을 보존한다', () async {
    final root = await folderRepository.createFolder(name: '난이도');
    final child = await folderRepository.createFolder(
      name: '하위',
      parentId: root,
    );
    await _createShortQuestion(questionRepository, root, '보통', difficulty: 3);
    final selected = await _createShortQuestion(
      questionRepository,
      child,
      '매우 어려움',
      difficulty: 5,
    );
    await questionRepository.createQuestion(
      QuestionDraft(
        folderId: child,
        type: QuestionType.multipleChoice,
        prompt: '객관식 제외',
        difficulty: 5,
        choices: const [
          QuestionChoiceDraft(text: '정답', isCorrect: true),
          QuestionChoiceDraft(text: '오답', isCorrect: false),
        ],
      ),
    );
    final builder = QuizBuilder(
      folderRepository,
      questionRepository,
      quizRepository,
      attemptRepository,
    );
    final result = await builder.build(
      QuizFilter(
        rootFolderId: root,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 10,
        enabledDifficulties: const {5},
        feedbackTiming: AnswerFeedbackTiming.afterCompletion,
      ),
    );
    final resumed = (await quizRepository.resumeSession(result.sessionId))!;
    expect(resumed.items.single.questionId, selected);
    expect(resumed.session.filter.enabledDifficulties, {5});
    expect(
      resumed.session.filter.feedbackTiming,
      AnswerFeedbackTiming.afterCompletion,
    );
  });

  for (final difficulties in [
    <int>{},
    {0},
    {6},
  ]) {
    test('빈 난이도나 범위 밖 난이도 $difficulties 는 세션 생성 전에 거부한다', () async {
      final root = await folderRepository.createFolder(name: '검증');
      final builder = QuizBuilder(
        folderRepository,
        questionRepository,
        quizRepository,
        attemptRepository,
      );
      await expectLater(
        builder.build(
          QuizFilter(
            rootFolderId: root,
            enabledQuestionTypes: const {QuestionType.shortAnswer},
            questionCount: 10,
            enabledDifficulties: difficulties,
          ),
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await database.select(database.quizSessions).get(), isEmpty);
    });
  }

  test('선택한 난이도의 문제가 없으면 세션을 만들지 않는다', () async {
    final root = await folderRepository.createFolder(name: '없음');
    await _createShortQuestion(questionRepository, root, '보통', difficulty: 3);
    final builder = QuizBuilder(
      folderRepository,
      questionRepository,
      quizRepository,
      attemptRepository,
    );
    await expectLater(
      builder.build(
        QuizFilter(
          rootFolderId: root,
          enabledQuestionTypes: const {QuestionType.shortAnswer},
          questionCount: 10,
          enabledDifficulties: const {1},
        ),
      ),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await database.select(database.quizSessions).get(), isEmpty);
  });

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
  String prompt, {
  int difficulty = 3,
}) {
  return repository.createQuestion(
    QuestionDraft(
      folderId: folderId,
      type: QuestionType.shortAnswer,
      prompt: prompt,
      difficulty: difficulty,
      acceptableAnswers: const ['정답'],
    ),
  );
}
