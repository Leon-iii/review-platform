import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

void main() {
  late AppDatabase database;
  late DriftSourceRepository sourceRepository;
  late String folderId;
  late bool databaseClosed;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    databaseClosed = false;
    sourceRepository = DriftSourceRepository(database);
    folderId = await DriftFolderRepository(database).createFolder(name: '물리학');
  });

  tearDown(() async {
    if (!databaseClosed) await database.close();
  });

  test('PDF Source와 보류된 Concept을 저장하고 승인한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );

    expect(saved.source.fileName, '전자기학.pdf');
    final concept = saved.concepts.single;
    expect(concept.status, ConceptStatus.held);
    expect(concept.importance, ConceptImportance.medium);
    expect(concept.pageNumbers, [3, 4]);

    await sourceRepository.setConceptApproval(id: concept.id, approved: true);
    final seed = await sourceRepository.getConceptGenerationSeed(concept.id);

    expect(seed.folderId, folderId);
    expect(seed.sourceLabel, contains('p.3, 4'));
    expect(seed.sourceText, contains('가우스 법칙'));
  });

  test('개념을 첫 페이지 순서로 정렬한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: DocumentImportResult(
        source: ImportedSource(
          id: 'ordered-source',
          fileName: '운영체제.pdf',
          contentHash: List.filled(64, 'b').join(),
          pageCount: 20,
          extractionMethod: 'textLayer',
          importedAt: DateTime.utc(2026, 10, 1),
        ),
        concepts: const [
          ImportedConcept(
            title: '가상 메모리',
            content: '가상 주소 공간을 설명한다.',
            pageNumbers: [12],
          ),
          ImportedConcept(
            title: '프로세스',
            content: '실행 중인 프로그램을 설명한다.',
            pageNumbers: [3, 4],
          ),
        ],
      ),
    );

    expect(saved.concepts.map((concept) => concept.title), ['프로세스', '가상 메모리']);
  });

  test('Concept 기반 생성 문제에 Source, 페이지, Concept을 연결한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final concept = saved.concepts.single;
    await sourceRepository.setConceptApproval(id: concept.id, approved: true);
    final questionRepository = DriftQuestionRepository(database);

    final ids = await questionRepository.createQuestions(
      [
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '폐곡면의 전기선속과 내부 전하를 연결하는 법칙은?',
          acceptableAnswers: const ['가우스 법칙'],
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: saved.source.id,
          conceptId: concept.id,
          pageNumbers: concept.pageNumbers,
        ),
      ],
    );

    final question = await questionRepository.getQuestion(ids.single);
    final reference = question!.sourceReferences.single;
    expect(reference.fileName, '전자기학.pdf');
    expect(reference.conceptTitle, '가우스 법칙');
    expect(reference.pageNumbers, [3, 4]);

    final changes = await DriftSyncRepository(database).buildPushBatch();
    expect(
      changes.map((change) => change.entityType),
      containsAll(['source', 'concept', 'question']),
    );
    final questionChange = changes.singleWhere(
      (change) => change.entityType == 'question',
    );
    final syncedReference =
        (questionChange.payload!['sourceReferences']! as List).single as Map;
    expect(syncedReference['sourceId'], 'source-1');
    expect(syncedReference['pageNumbers'], [3, 4]);

    await database.close();
    databaseClosed = true;
    final secondDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(secondDatabase.close);
    await DriftSyncRepository(secondDatabase).applyPulledChanges([
      for (var index = 0; index < changes.length; index++)
        PullSyncChange(
          entityType: changes[index].entityType,
          entityId: changes[index].entityId,
          operation: changes[index].operation,
          payload: changes[index].payload,
          updatedAt: changes[index].updatedAt,
          deletedAt: changes[index].deletedAt,
          revision: index + 1,
        ),
    ]);

    final syncedQuestion = await DriftQuestionRepository(secondDatabase)
        .getQuestion(ids.single);
    expect(syncedQuestion!.sourceReferences.single.sourceId, 'source-1');
    expect(syncedQuestion.sourceReferences.single.conceptTitle, '가우스 법칙');
  });

  test('PDF 자료 이름을 변경하고 Source upsert를 기록한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );

    await sourceRepository.renameSource(
      id: saved.source.id,
      fileName: '전자기학 2주차',
    );

    final updated = await sourceRepository.getSourceWithConcepts(
      saved.source.id,
    );
    expect(updated.source.fileName, '전자기학 2주차.pdf');
    final changes = await DriftSyncRepository(database).buildPushBatch();
    final sourceChanges = changes.where(
      (change) => change.entityType == 'source',
    );
    expect(sourceChanges.last.payload!['fileName'], '전자기학 2주차.pdf');
  });

  test('AI가 실제로 수정한 개념만 저장하고 승인 상태를 보류로 되돌린다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: DocumentImportResult(
        source: ImportedSource(
          id: 'revision-source',
          fileName: '전자기학.pdf',
          contentHash: List.filled(64, 'c').join(),
          pageCount: 10,
          extractionMethod: 'textLayer',
          importedAt: DateTime.utc(2026, 10, 1),
        ),
        concepts: const [
          ImportedConcept(
            title: '가우스 법칙',
            content: '전기선속과 전하의 관계',
            pageNumbers: [3, 4],
          ),
          ImportedConcept(
            title: '쿨롱 법칙',
            content: '두 전하 사이의 힘',
            pageNumbers: [5],
          ),
        ],
      ),
    );
    final first = saved.concepts.first;
    final second = saved.concepts.last;
    await sourceRepository.setConceptApproval(id: first.id, approved: true);
    await sourceRepository.setConceptApproval(id: second.id, approved: true);

    final result = await sourceRepository.applyConceptRevisions(
      sourceId: saved.source.id,
      revisions: [
        ConceptRevision(
          id: first.id,
          title: '가우스 법칙',
          content: '폐곡면의 전기선속과 내부 전하의 관계를 설명한다.',
          pageNumbers: const [4, 3, 3],
          importance: ConceptImportance.high,
        ),
        ConceptRevision(
          id: second.id,
          title: second.title,
          content: second.content,
          pageNumbers: second.pageNumbers,
          importance: second.importance,
        ),
      ],
    );

    expect(result.changedCount, 1);
    final revised = result.review.concepts.singleWhere(
      (concept) => concept.id == first.id,
    );
    final unchanged = result.review.concepts.singleWhere(
      (concept) => concept.id == second.id,
    );
    expect(revised.content, contains('폐곡면'));
    expect(revised.pageNumbers, [3, 4]);
    expect(revised.status, ConceptStatus.held);
    expect(revised.importance, ConceptImportance.high);
    expect(unchanged.status, ConceptStatus.approved);

    final changes = await DriftSyncRepository(database).buildPushBatch();
    final revisedChanges = changes.where(
      (change) => change.entityType == 'concept' && change.entityId == first.id,
    );
    expect(revisedChanges.last.payload!['status'], ConceptStatus.held.name);
  });

  test('PDF 자료 삭제 시 개념과 문제 출처를 제거하고 delete를 기록한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final questionRepository = DriftQuestionRepository(database);
    final questionIds = await questionRepository.createQuestions(
      [
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '가우스 법칙이란?',
          acceptableAnswers: const ['전기선속과 전하의 관계'],
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: saved.source.id,
          conceptId: saved.concepts.single.id,
          pageNumbers: const [3, 4],
        ),
      ],
    );

    await sourceRepository.deleteSource(saved.source.id);

    expect(await database.sourceDao.getSource(saved.source.id), isNull);
    expect(await database.sourceDao.getConcepts(saved.source.id), isEmpty);
    final question = await questionRepository.getQuestion(questionIds.single);
    expect(question, isNotNull);
    expect(question!.sourceReferences, isEmpty);
    final changes = await DriftSyncRepository(database).buildPushBatch();
    expect(
      changes.where(
        (change) =>
            change.entityType == 'source' && change.operation == 'delete',
      ),
      isNotEmpty,
    );
    expect(
      changes.where(
        (change) =>
            change.entityType == 'concept' && change.operation == 'delete',
      ),
      isNotEmpty,
    );
  });

  test('개념 삭제 시 문제 출처 연결을 해제하고 delete를 기록한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final concept = saved.concepts.single;
    final questionRepository = DriftQuestionRepository(database);
    final questionIds = await questionRepository.createQuestions(
      [
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '가우스 법칙이란?',
          acceptableAnswers: const ['전기선속과 전하의 관계'],
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: saved.source.id,
          conceptId: concept.id,
          pageNumbers: concept.pageNumbers,
        ),
      ],
    );

    await sourceRepository.deleteConcept(concept.id);

    expect(await database.sourceDao.getConcept(concept.id), isNull);
    final question = await questionRepository.getQuestion(questionIds.single);
    expect(question!.sourceReferences.single.conceptId, isNull);
    final changes = await DriftSyncRepository(database).buildPushBatch();
    expect(
      changes.where(
        (change) =>
            change.entityType == 'concept' && change.operation == 'delete',
      ),
      isNotEmpty,
    );
  });
}

DocumentImportResult _result() => DocumentImportResult(
  source: ImportedSource(
    id: 'source-1',
    fileName: '전자기학.pdf',
    contentHash: List.filled(64, 'a').join(),
    pageCount: 10,
    extractionMethod: 'textLayer',
    importedAt: DateTime.utc(2026, 9, 19),
  ),
  concepts: const [
    ImportedConcept(
      title: '가우스 법칙',
      content: '폐곡면의 전기선속은 내부의 전체 전하에 비례한다.',
      pageNumbers: [4, 3, 3],
    ),
  ],
);
