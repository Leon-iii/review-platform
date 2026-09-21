import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
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

  test('PDF Source와 Draft Concept을 저장하고 승인한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );

    expect(saved.source.fileName, '전자기학.pdf');
    final concept = saved.concepts.single;
    expect(concept.status, ConceptStatus.draft);
    expect(concept.pageNumbers, [3, 4]);

    await sourceRepository.approveConcept(concept.id);
    final seed = await sourceRepository.getConceptGenerationSeed(concept.id);

    expect(seed.folderId, folderId);
    expect(seed.sourceLabel, contains('p.3, 4'));
    expect(seed.sourceText, contains('가우스 법칙'));
  });

  test('Concept 기반 생성 문제에 Source, 페이지, Concept을 연결한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final concept = saved.concepts.single;
    await sourceRepository.approveConcept(concept.id);
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
      summary: '폐곡면의 전기선속과 내부 전하를 연결한다.',
      details: '전기선속은 폐곡면 내부의 전체 전하에 비례한다.',
      pageNumbers: [4, 3, 3],
    ),
  ],
);
