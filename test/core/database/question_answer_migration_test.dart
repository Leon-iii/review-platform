import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('v12 단답형을 서술형으로 전환하되 ID·답안·출처·풀이 이력을 보존하고 재실행하지 않는다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'review_essay_migration_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/migration.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    final folder = await DriftFolderRepository(original)
        .createFolder(name: '기존');
    final questions = DriftQuestionRepository(original);
    final quizzes = DriftQuizRepository(original);
    final attempts = DriftAttemptRepository(original);
    final source = await DriftSourceRepository(original)
        .createSource(folderId: folder, name: '자료');
    final id = (await questions.createQuestions(
      [
        QuestionDraft(
          folderId: folder,
          type: QuestionType.shortAnswer,
          prompt: '캐시를 설명하시오.',
          acceptableAnswers: const ['캐시는 중개자다.'],
          explanation: '기존 해설',
          difficulty: 4,
          importance: ConceptImportance.high,
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: source.source.id,
          pageNumbers: const [2, 3],
        ),
      ],
    )).single;
    final draftId = await questions.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        prompt: '기존 초안',
        acceptableAnswers: const ['초안 답안'],
        status: QuestionStatus.draft,
      ),
    );
    final question = (await questions.getQuestion(id))!;
    const future = '2030-01-01T00:00:00Z';
    await original.questionDao.updateQuestion(
      id,
      QuestionsCompanion(updatedAt: Value(DateTime.parse(future))),
    );
    final filter = QuizFilter(
      rootFolderId: folder,
      enabledQuestionTypes: const {QuestionType.shortAnswer},
      questionCount: 1,
    );
    final finishedId = await quizzes.createSession(
      filter: filter,
      questions: [question],
    );
    final finished = (await quizzes.getSession(finishedId))!;
    final attemptId = await attempts.recordAttempt(
      AttemptDraft(
        questionId: id,
        sessionId: finishedId,
        response: const {'textAnswer': '오래된 답안'},
        questionSnapshot: finished.items.single.questionSnapshot,
        score: 0,
        maxScore: 1,
        gradingType: GradingType.local,
        durationMs: 12,
      ),
    );
    await quizzes.linkAttempt(
      sessionId: finishedId,
      itemId: finished.items.single.id,
      attemptId: attemptId,
    );
    final ongoing = await quizzes.createSession(
      filter: filter,
      questions: [question],
    );
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute(
      'ALTER TABLE quiz_session_items DROP COLUMN pending_essay_response_json',
    );
    legacy.execute('DELETE FROM sync_outbox');
    legacy.execute(
      'ALTER TABLE quiz_session_items DROP COLUMN skipped_for_review',
    );
    legacy.execute('PRAGMA user_version = 12');
    legacy.execute('ALTER TABLE questions DROP COLUMN case_sensitive');
    legacy.execute('ALTER TABLE questions DROP COLUMN whitespace_sensitive');
    legacy.execute('ALTER TABLE questions DROP COLUMN correct_choice_ids_json');
    legacy.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    var upgradedClosed = false;
    addTearDown(() async {
      if (!upgradedClosed) await upgraded.close();
    });
    final upgradedQuestions = DriftQuestionRepository(upgraded);
    final converted = (await upgradedQuestions.getQuestion(id))!;
    expect(converted.type, QuestionType.essay);
    expect(converted.id, id);
    expect(converted.prompt, question.prompt);
    expect(converted.explanation, '기존 해설');
    expect(converted.difficulty, 4);
    expect(converted.importance, ConceptImportance.high);
    expect(
      converted.acceptableAnswers.single.id,
      question.acceptableAnswers.single.id,
    );
    expect(converted.acceptableAnswers.single.text, '캐시는 중개자다.');
    expect(converted.sourceReferences.single.sourceId, source.source.id);
    expect(converted.sourceReferences.single.pageNumbers, [2, 3]);
    expect(converted.updatedAt.isAfter(DateTime.parse(future)), true);
    expect(
      (await upgradedQuestions.getQuestion(draftId))!.type,
      QuestionType.essay,
    );
    expect(
      (await upgradedQuestions.getQuestion(draftId))!.status,
      QuestionStatus.draft,
    );
    final upgradedQuiz = DriftQuizRepository(upgraded);
    expect(
      (await upgradedQuiz.getSession(ongoing))!
          .items
          .single
          .questionSnapshot
          .type,
      QuestionType.essay,
    );
    expect(
      (await upgradedQuiz.getSession(finishedId))!
          .items
          .single
          .questionSnapshot
          .type,
      QuestionType.shortAnswer,
    );
    final history = (await DriftAttemptRepository(
      upgraded,
    ).getAttemptsForSession(finishedId)).single;
    expect(history.id, attemptId);
    expect(history.score, 0);
    expect(history.questionSnapshot.type, QuestionType.shortAnswer);
    final batch = await DriftSyncRepository(upgraded).buildPushBatch();
    expect(batch.where((e) => e.entityType == 'question').length, 2);
    final uploaded = batch.singleWhere((e) => e.entityId == id);
    expect(uploaded.payload!['type'], 'essay');
    expect(uploaded.payload!['answerFormatVersion'], 2);
    final newId = await upgradedQuestions.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        prompt: '새 용어 문제',
        acceptableAnswers: const ['캐시 히트'],
      ),
    );
    final after = await upgraded
        .customSelect('SELECT COUNT(*) AS count FROM sync_outbox')
        .getSingle();
    await upgraded.close();
    upgradedClosed = true;
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(
      (await DriftQuestionRepository(reopened).getQuestion(newId))!.type,
      QuestionType.shortAnswer,
    );
    expect(
      (await reopened
              .customSelect('SELECT COUNT(*) AS count FROM sync_outbox')
              .getSingle())
          .read<int>('count'),
      after.read<int>('count'),
    );
    expect(
      jsonDecode(
        (await reopened.select(reopened.quizSessionItems).get())
            .first
            .questionSnapshotJson,
      ),
      isA<Map>(),
    );
  });
}
