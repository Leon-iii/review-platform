import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/services/quiz_builder.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

void main() {
  late AppDatabase db;
  late DriftFolderRepository folders;
  late DriftQuestionRepository questions;
  late DriftSourceRepository sources;
  late DriftQuizRepository quizzes;
  late DriftAttemptRepository attempts;
  late String folder;
  late StudySource source;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    folders = DriftFolderRepository(db);
    questions = DriftQuestionRepository(db);
    sources = DriftSourceRepository(db);
    quizzes = DriftQuizRepository(db);
    attempts = DriftAttemptRepository(db);
    folder = await folders.createFolder(name: '중요도');
    source = (await sources.createSource(folderId: folder, name: '자료')).source;
  });
  tearDown(() => db.close());

  QuestionDraft draft(
    String title, {
    ConceptImportance importance = ConceptImportance.medium,
    int difficulty = 3,
  }) => QuestionDraft(
    folderId: folder,
    type: QuestionType.shortAnswer,
    prompt: title,
    acceptableAnswers: const ['정답'],
    importance: importance,
    difficulty: difficulty,
  );

  Future<String> fromConcept(
    StudyConcept concept,
    String title, {
    int difficulty = 3,
  }) async => (await questions.createQuestions(
    [draft(title, difficulty: difficulty)],
    sourceReferences: [
      QuestionSourceDraft(
        sourceId: source.id,
        conceptId: concept.id,
        pageNumbers: concept.pageNumbers,
      ),
    ],
  )).single;

  test('직접 작성 문제는 보통 기본값과 수동 중요도를 저장한다', () async {
    final id = await questions.createQuestion(draft('직접 문제'));
    expect(
      (await questions.getQuestion(id))!.importance,
      ConceptImportance.medium,
    );
    await questions.updateQuestion(
      id,
      draft('수정', importance: ConceptImportance.veryLow),
    );
    final question = (await questions.getQuestion(id))!;
    expect(question.importance, ConceptImportance.veryLow);
    expect(question.inheritsImportance, false);
    expect(question.difficulty, 3);
  });

  for (final deleteSource in [false, true]) {
    test(
      '개념 중요도를 실시간 상속하고 ${deleteSource ? '자료' : '개념'} 삭제 후 마지막 값을 유지한다',
      () async {
        final concept = await sources.addConcept(
          sourceId: source.id,
          title: '주개념',
          content: '내용',
          importance: ConceptImportance.veryHigh,
        );
        final id = await fromConcept(concept, '연결 문제', difficulty: 1);
        final changed = questions
            .watchQuestions(folder)
            .firstWhere(
              (values) => values.single.importance == ConceptImportance.low,
            );
        expect(
          (await questions.getQuestion(id))!.importance,
          ConceptImportance.veryHigh,
        );
        await sources.updateConcept(
          id: concept.id,
          title: '주개념',
          content: '내용',
          importance: ConceptImportance.low,
        );
        expect(
          (await questions.getQuestion(id))!.importance,
          ConceptImportance.low,
        );
        expect((await questions.getQuestion(id))!.difficulty, 1);
        // The reactive question list must also refresh on concept changes.
        expect((await changed).single.importance, ConceptImportance.low);
        if (deleteSource) {
          await sources.deleteSource(source.id);
        } else {
          await sources.deleteConcept(concept.id);
        }
        final retained = (await questions.getQuestion(id))!;
        expect(retained.importance, ConceptImportance.low);
        expect(retained.primaryConceptId, null);
        expect((await db.questionDao.getQuestion(id))!.importance, 'low');
        final sync = DriftSyncRepository(db);
        final outgoing = await sync.buildPushBatch();
        expect(
          outgoing.where((c) => c.entityId == id).last.payload!['importance'],
          'low',
        );
      },
    );
  }

  test('중요도와 개념 연결이 동기화되고 원격 삭제 후 마지막 중요도를 보존한다', () async {
    final concept = await sources.addConcept(
      sourceId: source.id,
      title: '주개념',
      content: '내용',
      importance: ConceptImportance.high,
    );
    final id = await fromConcept(concept, '연결 문제');
    final payloads = await DriftSyncRepository(db).buildPushBatch();
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    final sync = DriftSyncRepository(target);
    await sync.applyPulledChanges([
      for (var i = 0; i < payloads.length; i++)
        PullSyncChange(
          entityType: payloads[i].entityType,
          entityId: payloads[i].entityId,
          operation: payloads[i].operation,
          payload: payloads[i].payload,
          updatedAt: payloads[i].updatedAt,
          deletedAt: payloads[i].deletedAt,
          revision: i + 1,
        ),
    ]);
    final targetQuestions = DriftQuestionRepository(target);
    expect(
      (await targetQuestions.getQuestion(id))!.primaryConceptId,
      concept.id,
    );
    expect(
      (await targetQuestions.getQuestion(id))!.importance,
      ConceptImportance.high,
    );
    await sync.applyPulledChanges([
      PullSyncChange(
        entityType: 'concept',
        entityId: concept.id,
        operation: 'delete',
        payload: null,
        updatedAt: DateTime.now().toUtc(),
        deletedAt: DateTime.now().toUtc(),
        revision: 100,
      ),
    ]);
    expect(
      (await targetQuestions.getQuestion(id))!.importance,
      ConceptImportance.high,
    );
    expect((await targetQuestions.getQuestion(id))!.inheritsImportance, false);
    expect(await sync.getPending(), isEmpty);
  });

  test('개념별 가중 추첨은 문항 수에 의해 이중 가중되지 않는다', () async {
    final high = await sources.addConcept(
      sourceId: source.id,
      title: '중요 개념',
      content: '내용',
      importance: ConceptImportance.veryHigh,
    );
    final low = await sources.addConcept(
      sourceId: source.id,
      title: '지엽적 개념',
      content: '내용',
      importance: ConceptImportance.veryLow,
    );
    final importantId = await fromConcept(high, '중요 문제');
    for (var i = 0; i < 20; i++) {
      await fromConcept(low, '지엽적 문제 $i');
    }
    final builder = QuizBuilder(
      folders,
      questions,
      quizzes,
      attempts,
      random: Random(73),
    );
    var hits = 0;
    for (var i = 0; i < 120; i++) {
      final result = await builder.build(
        QuizFilter(
          rootFolderId: folder,
          enabledQuestionTypes: const {QuestionType.shortAnswer},
          questionCount: 1,
          prioritizeImportantConcepts: true,
        ),
      );
      if ((await quizzes.getSession(result.sessionId))!
              .items
              .single
              .questionId ==
          importantId) {
        hits++;
      }
    }
    // Expected ~5/6, not 5/(5+20). Fixed seed avoids flaky assertions.
    expect(hits, greaterThan(85));
    expect(hits, lessThan(115));
    final all = await builder.build(
      QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 50,
        prioritizeImportantConcepts: true,
      ),
    );
    final session = (await quizzes.resumeSession(all.sessionId))!;
    expect(session.items.map((item) => item.questionId).toSet(), hasLength(21));
    expect(session.session.filter.prioritizeImportantConcepts, true);
  });

  test('가중 출제도 난이도·오답 필터를 지키고 모름을 포함한다', () async {
    final easy = await questions.createQuestion(
      draft('쉬움', difficulty: 1, importance: ConceptImportance.veryHigh),
    );
    final hard = await questions.createQuestion(draft('모름', difficulty: 5));
    final question = (await questions.getQuestion(hard))!;
    final sessionId = await quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [question],
    );
    await attempts.recordAttempt(
      AttemptDraft(
        questionId: hard,
        sessionId: sessionId,
        response: const {'isUnknown': true},
        questionSnapshot: QuestionSnapshot.fromQuestion(question),
        score: 0,
        maxScore: 1,
        gradingType: GradingType.local,
        durationMs: 1,
      ),
    );
    final result = await QuizBuilder(folders, questions, quizzes, attempts)
        .build(
          QuizFilter(
            rootFolderId: folder,
            enabledQuestionTypes: const {QuestionType.shortAnswer},
            questionCount: 10,
            enabledDifficulties: const {5},
            onlyWrongQuestions: true,
            prioritizeImportantConcepts: true,
          ),
        );
    final ids = (await quizzes.getSession(result.sessionId))!.items
        .map((item) => item.questionId);
    expect(ids, [hard]);
    expect(ids, isNot(contains(easy)));
  });
}
