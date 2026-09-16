import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';

void main() {
  late AppDatabase database;
  late DriftFolderRepository repository;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    repository = DriftFolderRepository(database);
  });

  tearDown(() => database.close());

  test('폴더를 계층적으로 생성하고 조회한다', () async {
    final rootId = await repository.createFolder(name: ' 전자기학 ');
    final childId = await repository.createFolder(
      name: 'Chapter 1',
      parentId: rootId,
    );

    final tree = await repository.watchFolderTree().first;

    expect(rootId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(tree, hasLength(1));
    expect(tree.single.folder.name, '전자기학');
    expect(tree.single.children.single.folder.id, childId);
    expect(await repository.getDescendantIds(rootId), [childId]);
  });

  test('폴더 이름을 변경하고 다른 폴더로 옮긴다', () async {
    final firstRootId = await repository.createFolder(name: '첫 번째');
    final secondRootId = await repository.createFolder(name: '두 번째');

    await repository.renameFolder(id: firstRootId, name: '변경된 폴더');
    await repository.moveFolder(id: firstRootId, parentId: secondRootId);

    final tree = await repository.watchFolderTree().first;
    expect(tree, hasLength(1));
    expect(tree.single.folder.id, secondRootId);
    expect(tree.single.children.single.folder.name, '변경된 폴더');
  });

  test('폴더를 하위 폴더 안으로 옮길 수 없다', () async {
    final rootId = await repository.createFolder(name: '상위');
    final childId = await repository.createFolder(name: '하위', parentId: rootId);

    await expectLater(
      repository.moveFolder(id: rootId, parentId: childId),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('삭제 시 하위 폴더까지 soft delete한다', () async {
    final rootId = await repository.createFolder(name: '상위');
    final childId = await repository.createFolder(name: '하위', parentId: rootId);
    final grandchildId = await repository.createFolder(
      name: '손자',
      parentId: childId,
    );
    final questionRepository = DriftQuestionRepository(database);
    final questionId = await questionRepository.createQuestion(
      QuestionDraft(
        folderId: grandchildId,
        type: QuestionType.shortAnswer,
        prompt: '삭제될 문제',
        acceptableAnswers: const ['정답'],
      ),
    );

    final impact = await repository.getDeletionImpact(rootId);
    expect(impact.descendantFolderCount, 2);
    expect(impact.questionCount, 1);

    await repository.deleteFolder(rootId);

    expect(await repository.watchFolderTree().first, isEmpty);
    final deletedRows = await database.select(database.folders).get();
    expect(deletedRows, hasLength(3));
    expect(deletedRows.every((row) => row.deletedAt != null), isTrue);
    expect(
      deletedRows.every(
        (row) => row.deletedAt == row.deletedAt?.toUtc().toLocal(),
      ),
      isTrue,
    );
    expect(await questionRepository.getQuestion(questionId), isNull);
  });

  test('빈 폴더 이름을 허용하지 않는다', () async {
    await expectLater(
      repository.createFolder(name: '   '),
      throwsA(isA<ValidationFailure>()),
    );
  });
}
