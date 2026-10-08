import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/services/answer_grader.dart';
import 'package:review_platform/domain/services/question_validator.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

QuestionDraft orderingDraft(String folder, {int count = 4, List<int>? order}) =>
    QuestionDraft(
      folderId: folder,
      type: QuestionType.ordering,
      prompt: '과정을 올바르게 배열해라.',
      choices: [
        for (var i = 0; i < count; i++)
          QuestionChoiceDraft(text: '단계 $i', isCorrect: true),
      ],
      correctOrder: order ?? List.generate(count, (i) => i + 1),
      explanation: '선후 관계 해설',
    );

void main() {
  for (final count in [3, 4, 5, 6]) {
    test('$count개 단계를 허용하고 순서는 고유 ID로 저장하며 섞은 후에도 정확히 채점한다', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final folder = await DriftFolderRepository(db).createFolder(name: '배열');
      final repo = DriftQuestionRepository(db);
      final indices = [for (var i = count; i >= 1; i--) i];
      final id = await repo.createQuestion(
        orderingDraft(folder, count: count, order: indices),
      );
      final question = (await repo.getQuestion(id))!;
      expect(question.correctChoiceIds, [
        for (final index in indices) question.choices[index - 1].id,
      ]);
      for (var seed = 0; seed < 12; seed++) {
        final snap = QuestionSnapshot.fromQuestion(
          question,
          random: Random(seed),
        );
        expect(
          snap.choices.map((c) => c.id),
          isNot(orderedEquals(snap.correctChoiceIds)),
        );
        expect(
          AnswerGrader.gradeOrdering(snap, question.correctChoiceIds).score,
          1,
        );
        expect(
          AnswerGrader.gradeOrdering(
            snap,
            question.correctChoiceIds.reversed.toList(),
          ).score,
          0,
        );
        for (final invalid in [
          question.correctChoiceIds.take(count - 1).toList(),
          [...question.correctChoiceIds.take(count - 1), 'unknown'],
          List.filled(count, question.correctChoiceIds.first),
        ]) {
          expect(
            () => AnswerGrader.gradeOrdering(snap, invalid),
            throwsA(isA<ValidationFailure>()),
          );
        }
        final restored = QuestionSnapshot.fromJson(
          jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>,
        );
        expect(restored.correctChoiceIds, snap.correctChoiceIds);
        expect(
          restored.choices.map((c) => c.id),
          snap.choices.map((c) => c.id),
        );
      }
      final session = await DriftQuizRepository(db).createSession(
        filter: QuizFilter(
          rootFolderId: folder,
          enabledQuestionTypes: const {QuestionType.ordering},
          questionCount: 1,
          shuffle: false,
        ),
        questions: [question],
      );
      final before = (await DriftQuizRepository(db).getSession(session))!
          .items
          .single
          .questionSnapshot;
      await repo.updateQuestion(
        id,
        orderingDraft(
          folder,
          count: count,
          order: List.generate(count, (i) => i + 1),
        ),
      );
      final updated = (await repo.getQuestion(id))!;
      expect(updated.correctChoiceIds, updated.choices.map((c) => c.id));
      final resumed = (await DriftQuizRepository(db).resumeSession(session))!
          .items
          .single
          .questionSnapshot;
      expect(resumed.toJson(), before.toJson());
      expect(
        AnswerGrader.gradeOrdering(resumed, before.correctChoiceIds).isCorrect,
        isTrue,
      );
    });
  }
  for (final draft in [
    orderingDraft('f', count: 2),
    orderingDraft('f', count: 7),
    orderingDraft('f', order: [1, 2, 3]),
    orderingDraft('f', order: [1, 1, 3, 4]),
    orderingDraft('f', order: [0, 2, 3, 4]),
    orderingDraft('f', order: [1, 2, 3, 5]),
    const QuestionDraft(
      folderId: 'f',
      type: QuestionType.ordering,
      prompt: '질문',
      choices: [
        QuestionChoiceDraft(text: '단계', isCorrect: true),
        QuestionChoiceDraft(text: '단계', isCorrect: true),
        QuestionChoiceDraft(text: '', isCorrect: false),
      ],
      correctOrder: [1, 2, 3],
    ),
  ]) {
    test(
      '잘못된 단계와 순서를 저장 전에 거부한다 ${draft.choices.length}/${draft.correctOrder}',
      () {
        expect(
          () => QuestionValidator.validate(draft),
          throwsA(isA<ValidationFailure>()),
        );
      },
    );
  }

  test('순서 배열형의 정답 ID와 섞인 세션 선지 순서를 다른 기기로 동기화한다', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    addTearDown(target.close);
    final folder = await DriftFolderRepository(db).createFolder(name: '동기화');
    final repo = DriftQuestionRepository(db);
    final id = await repo.createQuestion(
      orderingDraft(folder, order: [2, 1, 4, 3]),
    );
    final question = (await repo.getQuestion(id))!;
    final session = await DriftQuizRepository(db).createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.ordering},
        questionCount: 1,
      ),
      questions: [question],
    );
    final push = await DriftSyncRepository(db).buildPushBatch();
    final pull = [
      for (final (index, entry) in push.indexed)
        PullSyncChange(
          entityType: entry.entityType,
          entityId: entry.entityId,
          operation: entry.operation,
          updatedAt: entry.updatedAt,
          revision: index + 1,
          payload: Map<String, Object?>.from(
            jsonDecode(jsonEncode(entry.payload)) as Map,
          ),
        ),
    ];
    await DriftSyncRepository(target).applyPulledChanges(pull);
    final restored = (await DriftQuestionRepository(target).getQuestion(id))!;
    expect(restored.correctChoiceIds, question.correctChoiceIds);
    final first = (await DriftQuizRepository(db).getSession(session))!
        .items
        .single
        .questionSnapshot;
    final second = (await DriftQuizRepository(target).resumeSession(session))!
        .items
        .single
        .questionSnapshot;
    expect(second.toJson(), first.toJson());
    expect(
      AnswerGrader.gradeOrdering(second, question.correctChoiceIds).isCorrect,
      isTrue,
    );
    final corrupt = pull.singleWhere((entry) => entry.entityType == 'question');
    await expectLater(
      DriftSyncRepository(target).applyPulledChanges([
        PullSyncChange(
          entityType: 'question',
          entityId: id,
          operation: 'upsert',
          revision: push.length + 1,
          updatedAt: corrupt.updatedAt.add(const Duration(seconds: 2)),
          payload: {
            ...corrupt.payload!,
            'correctChoiceIds': ['missing', 'missing', 'missing', 'missing'],
          },
        ),
      ]),
      throwsA(isA<ValidationFailure>()),
    );
    expect(
      (await DriftQuestionRepository(target).getQuestion(id))!.correctChoiceIds,
      question.correctChoiceIds,
    );
  });

  test('v15→v16은 기존 문제와 풀이 데이터를 유지하고 새 정답 목록만 빈 값으로 추가한다', () async {
    final temp = await Directory.systemTemp.createTemp('ordering_migration_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/app.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    final folder = await DriftFolderRepository(original)
        .createFolder(name: '기존');
    final repo = DriftQuestionRepository(original);
    final id = await repo.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        prompt: '기존 단답',
        acceptableAnswers: const ['정답'],
      ),
    );
    final quiz = DriftQuizRepository(original);
    final sessionId = await quiz.createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [(await repo.getQuestion(id))!],
    );
    final before = (await quiz.getSession(sessionId))!
        .items
        .single
        .questionSnapshot
        .toJson();
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute('ALTER TABLE questions DROP COLUMN correct_choice_ids_json');
    legacy.execute('PRAGMA user_version = 15');
    legacy.close();
    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final result = (await DriftQuestionRepository(migrated).getQuestion(id))!;
    expect(result.type, QuestionType.shortAnswer);
    expect(result.acceptableAnswers.single.text, '정답');
    expect(result.correctChoiceIds, isEmpty);
    final resumed = (await DriftQuizRepository(migrated)
        .resumeSession(sessionId))!;
    expect(resumed.items.single.questionSnapshot.toJson(), before);
    expect(
      (await migrated.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      16,
    );
  });
}
