import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/services/answer_grader.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('문항별 옵션을 생성·편집·재시작·동기화하며 시작된 풀이 설정은 보존한다', () async {
    final directory = await Directory.systemTemp.createTemp('answer_options_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final db = AppDatabase(NativeDatabase(file));
    var closed = false;
    addTearDown(() async {
      if (!closed) await db.close();
    });
    final folder = await DriftFolderRepository(db).createFolder(name: '테스트');
    final repo = DriftQuestionRepository(db);
    final ids = <String>[];
    for (final caseSensitive in [false, true]) {
      for (final whitespaceSensitive in [false, true]) {
        ids.add(
          await repo.createQuestion(
            QuestionDraft(
              folderId: folder,
              type: QuestionType.shortAnswer,
              prompt: '용어',
              acceptableAnswers: const ['Cache Hit'],
              caseSensitive: caseSensitive,
              whitespaceSensitive: whitespaceSensitive,
            ),
          ),
        );
      }
    }
    final quizzes = DriftQuizRepository(db);
    final sessionId = await quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [(await repo.getQuestion(ids.last))!],
    );
    await repo.updateQuestion(
      ids.last,
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        prompt: '수정한 용어',
        acceptableAnswers: const ['Cache Hit'],
        caseSensitive: true,
        whitespaceSensitive: false,
      ),
    );
    final batch = await DriftSyncRepository(db).buildPushBatch();
    await db.close();
    closed = true;
    Future<void> verifyRestored(AppDatabase restoredDb) async {
      final restoredRepo = DriftQuestionRepository(restoredDb);
      for (var i = 0; i < ids.length; i++) {
        final question = (await restoredRepo.getQuestion(ids[i]))!;
        expect(question.caseSensitive, i >= 2);
        expect(question.whitespaceSensitive, i == 1);
      }
      final snapshot = (await DriftQuizRepository(
        restoredDb,
      ).getSession(sessionId))!.items.single.questionSnapshot;
      expect(snapshot.caseSensitive, true);
      expect(snapshot.whitespaceSensitive, true);
      expect(
        AnswerGrader.gradeShortAnswer(snapshot, 'CacheHit').isCorrect,
        false,
      );
    }

    final reopened = AppDatabase(NativeDatabase(file));
    try {
      await verifyRestored(reopened);
    } finally {
      await reopened.close();
    }
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    final targetSync = DriftSyncRepository(target);
    await targetSync.applyPulledChanges([
      for (var i = 0; i < batch.length; i++)
        PullSyncChange(
          entityType: batch[i].entityType,
          entityId: batch[i].entityId,
          operation: batch[i].operation,
          updatedAt: batch[i].updatedAt,
          revision: i + 1,
          payload: batch[i].payload,
        ),
    ]);
    await verifyRestored(target);
    // Older clients omit these fields: explicit defaults also clear prior true values.
    final oldPayload = batch.lastWhere((e) => e.entityId == ids.last);
    final payload = Map<String, Object?>.of(oldPayload.payload!)
      ..remove('caseSensitive')
      ..remove('whitespaceSensitive');
    await targetSync.applyPulledChanges([
      PullSyncChange(
        entityType: 'question',
        entityId: ids.last,
        operation: 'upsert',
        updatedAt: oldPayload.updatedAt.add(const Duration(seconds: 1)),
        revision: batch.length + 1,
        payload: payload,
      ),
    ]);
    final fallback = (await DriftQuestionRepository(target)
        .getQuestion(ids.last))!;
    expect(fallback.type, QuestionType.shortAnswer);
    expect(fallback.caseSensitive, false);
    expect(fallback.whitespaceSensitive, false);
  });

  test('v13 기존 문항을 보존하고 두 채점 옵션만 false로 추가한다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'answer_migration_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    final folder = await DriftFolderRepository(original)
        .createFolder(name: '기존');
    final id = await DriftQuestionRepository(original).createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        prompt: '기존 문제',
        acceptableAnswers: const ['Gauss Law'],
      ),
    );
    final before = (await DriftQuestionRepository(original).getQuestion(id))!;
    final pending = (await DriftSyncRepository(original).getPending()).length;
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('ALTER TABLE questions DROP COLUMN case_sensitive');
    legacy.execute('ALTER TABLE questions DROP COLUMN whitespace_sensitive');
    legacy.execute(
      'ALTER TABLE quiz_session_items DROP COLUMN skipped_for_review',
    );
    legacy.execute('PRAGMA user_version = 13');
    legacy.execute('ALTER TABLE questions DROP COLUMN correct_choice_ids_json');
    legacy.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final after = (await DriftQuestionRepository(upgraded).getQuestion(id))!;
    expect(after.type, QuestionType.shortAnswer);
    expect(after.prompt, before.prompt);
    expect(after.updatedAt, before.updatedAt);
    expect(
      after.acceptableAnswers.single.id,
      before.acceptableAnswers.single.id,
    );
    expect(after.acceptableAnswers.single.text, 'Gauss Law');
    expect(after.caseSensitive, false);
    expect(after.whitespaceSensitive, false);
    expect((await DriftSyncRepository(upgraded).getPending()).length, pending);
    expect(upgraded.schemaVersion, 16);
  });
}
