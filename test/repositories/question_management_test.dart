import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

void main() {
  late AppDatabase db;
  late DriftQuestionRepository questions;
  late String folder;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    questions = DriftQuestionRepository(db);
    folder = await DriftFolderRepository(db).createFolder(name: '원본');
  });
  tearDown(() => db.close());
  Future<String> create(String title, {String? conceptId}) =>
      questions.createQuestion(
        QuestionDraft(
          folderId: folder,
          type: QuestionType.shortAnswer,
          prompt: title,
          acceptableAnswers: const ['정답'],
          status: QuestionStatus.draft,
        ),
        primaryConceptId: conceptId,
      );

  test('일괄 이동·삭제는 중복 ID를 정규화하고 상세·출처를 보존하며 동기화 작업을 기록한다', () async {
    final sources = DriftSourceRepository(db);
    final source = await sources.createSource(folderId: folder, name: '자료');
    final concept = await sources.addConcept(
      sourceId: source.source.id,
      title: '개념',
      content: '내용',
    );
    final first = await create('첫 문제', conceptId: concept.id);
    final second = await create('둘째 문제');
    final target = await DriftFolderRepository(db).createFolder(name: '대상');
    final before = await questions.getQuestion(first);
    final pending = await db.syncDao.getPendingCount();
    await questions.moveQuestions(
      ids: [first, first, second],
      folderId: target,
    );
    final after = (await questions.getQuestion(first))!;
    expect(after.folderId, target);
    expect(
      after.acceptableAnswers.single.id,
      before!.acceptableAnswers.single.id,
    );
    expect(after.primaryConceptId, concept.id);
    expect(await db.syncDao.getPendingCount(), pending + 2);
    await questions.approveQuestions([first, second]);
    expect(
      (await questions.getQuestion(first))!.status,
      QuestionStatus.approved,
    );
    await questions.deleteQuestions([first, first, second]);
    expect(await questions.getQuestion(first), isNull);
    expect(await questions.watchQuestions(target).first, isEmpty);
    expect((await db.questionDao.getQuestion(first))!.deletedAt, isNotNull);
  });

  test('일괄 작업의 중간 실패는 앞선 변경 및 동기화 큐까지 전부 롤백한다', () async {
    final first = await create('문제');
    final target = await DriftFolderRepository(db).createFolder(name: '대상');
    final pending = await db.syncDao.getPendingCount();
    await expectLater(
      questions.moveQuestions(ids: [first, 'missing'], folderId: target),
      throwsA(isA<ValidationFailure>()),
    );
    expect((await questions.getQuestion(first))!.folderId, folder);
    await expectLater(
      questions.deleteQuestions([first, 'missing']),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await questions.getQuestion(first), isNotNull);
    expect(await db.syncDao.getPendingCount(), pending);
    await expectLater(
      questions.moveQuestions(ids: [first], folderId: 'missing'),
      throwsA(isA<ValidationFailure>()),
    );
    expect((await questions.getQuestion(first))!.folderId, folder);
  });

  test('역방향 연결은 미승인·다른 폴더 문제도 조회하고 삭제·연결 해제를 실시간 반영한다', () async {
    final sources = DriftSourceRepository(db);
    final source = await sources.createSource(folderId: folder, name: '자료');
    final concept = await sources.addConcept(
      sourceId: source.source.id,
      title: '개념',
      content: '내용',
    );
    final first = await create('첫 문제', conceptId: concept.id);
    final second = await create('둘째 문제', conceptId: concept.id);
    await create('연결 없는 문제');
    final target = await DriftFolderRepository(db).createFolder(name: '다른 폴더');
    await questions.moveQuestion(id: second, folderId: target);
    final events = <List<Question>>[];
    final stream = questions.watchQuestionsForConcept(concept.id);
    final initial = await questions.watchQuestionsForConcept(concept.id).first;
    expect(initial.map((q) => q.id), containsAll([first, second]));
    expect(initial.every((q) => q.status == QuestionStatus.draft), isTrue);
    final changed = Completer<void>();
    final subscription = stream.listen((items) {
      events.add(items);
      if (items.length == 1 &&
          items.single.id == second &&
          !changed.isCompleted) {
        changed.complete();
      }
    });
    await questions.deleteQuestion(first);
    await changed.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    expect(events.last.single.id, second);
    await sources.deleteConcept(concept.id);
    expect(await questions.watchQuestionsForConcept(concept.id).first, isEmpty);
    expect((await questions.getQuestion(second))!.primaryConceptId, isNull);
  });
}
