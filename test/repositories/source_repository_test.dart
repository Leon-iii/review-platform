import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
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

  test('중요도 5단계는 추가·편집·AI 수정·저장·동기화에서 보존된다', () async {
    expect(ConceptImportance.values.map((value) => value.label), [
      '매우 낮음',
      '낮음',
      '보통',
      '높음',
      '매우 높음',
    ]);
    final source = await sourceRepository.createSource(
      folderId: folderId,
      name: '중요도 노트',
    );
    for (final importance in ConceptImportance.values) {
      expect(ConceptImportance.fromStorage(importance.name), importance);
      expect(
        ConceptImportance.fromStorage(' ${importance.name.toUpperCase()} '),
        importance,
      );
      final added = await sourceRepository.addConcept(
        sourceId: source.source.id,
        title: importance.label,
        content: '원본',
        importance: importance,
      );
      await sourceRepository.updateConcept(
        id: added.id,
        title: added.title,
        content: '직접 편집',
        importance: importance,
      );
      final revised = await sourceRepository.applyConceptRevisions(
        sourceId: source.source.id,
        revisions: [
          ConceptRevision(
            id: added.id,
            title: added.title,
            content: 'AI 수정',
            pageNumbers: const [],
            importance: importance,
          ),
        ],
      );
      expect(
        revised.review.concepts
            .singleWhere((item) => item.id == added.id)
            .importance,
        importance,
      );
    }
    final changes = await DriftSyncRepository(database).buildPushBatch();
    final conceptChanges = changes.where(
      (change) => change.entityType == 'concept',
    );
    expect(
      conceptChanges.map((change) => change.payload!['importance']).toSet(),
      ConceptImportance.values.map((value) => value.name).toSet(),
    );
    await database.close();
    databaseClosed = true;
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    await DriftSyncRepository(target).applyPulledChanges([
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
    final restored = await DriftSourceRepository(target)
        .getSourceWithConcepts(source.source.id);
    expect(
      restored.concepts.map((concept) => concept.importance),
      ConceptImportance.values,
    );
  });

  test('사용자 자료는 비어 있으며 수동 개념은 같은 승인과 문제 생성 파이프라인을 쓴다', () async {
    final empty = await sourceRepository.createSource(
      folderId: folderId,
      name: '  나의 노트  ',
    );
    expect(empty.concepts, isEmpty);
    expect(empty.source.fileName, '나의 노트');
    expect(empty.source.isManual, isTrue);
    expect(empty.source.pageCount, 0);
    expect(empty.source.contentHash, isEmpty);
    final added = await sourceRepository.addConcept(
      sourceId: empty.source.id,
      title: '  직접 쓴 개념 ',
      content: ' 직접 작성한 개념의 상세 내용 ',
      importance: ConceptImportance.high,
    );
    expect(added.status, ConceptStatus.approved);
    expect(added.hasPageSource, isFalse);
    expect(added.importance, ConceptImportance.high);
    expect(
      (await sourceRepository.getConceptGenerationSeed(added.id)).concept.id,
      added.id,
    );
    await sourceRepository.setConceptApproval(id: added.id, approved: false);
    await expectLater(
      sourceRepository.getConceptGenerationSeed(added.id),
      throwsA(isA<ValidationFailure>()),
    );
    await sourceRepository.setConceptApproval(id: added.id, approved: true);
    final seed = await sourceRepository.getConceptGenerationSeed(added.id);
    expect(seed.sourceLabel, '나의 노트 · 직접 쓴 개념');
    final all = await sourceRepository.getSourceGenerationSeed(empty.source.id);
    expect(all.sourceText, isNot(contains('페이지:')));
    expect(all.sourceReference.pageNumbers, isEmpty);
    await sourceRepository.renameSource(id: empty.source.id, fileName: '새 이름');
    expect(
      (await sourceRepository.getSourceWithConcepts(empty.source.id))
          .source
          .fileName,
      '새 이름',
    );
  });

  test('검토 표시명만 변경하고 기존 저장 값과 수동 편집 상태를 보존한다', () async {
    expect(ConceptStatus.fromStorage('draft').label, '검토 필요');
    expect(ConceptStatus.fromStorage('held').label, '검토 필요');
    expect(ConceptStatus.fromStorage('approved').label, '검토 완료');
    final source = await sourceRepository.createSource(
      folderId: folderId,
      name: '노트',
    );
    for (final reviewed in [true, false]) {
      final concept = await sourceRepository.addConcept(
        sourceId: source.source.id,
        title: '수동 개념',
        content: '사용자가 직접 입력한 내용',
        reviewed: reviewed,
      );
      final expected = reviewed ? ConceptStatus.approved : ConceptStatus.held;
      expect(concept.status, expected);
      await sourceRepository.updateConcept(
        id: concept.id,
        title: concept.title,
        content: '직접 편집한 내용',
        importance: concept.importance,
      );
      final updated = (await sourceRepository.getSourceWithConcepts(
        source.source.id,
      )).concepts.singleWhere((entry) => entry.id == concept.id);
      expect(updated.status, expected);
      if (!reviewed) {
        await expectLater(
          sourceRepository.getConceptGenerationSeed(concept.id),
          throwsA(isA<ValidationFailure>()),
        );
      }
    }
  });

  for (final markReviewed in [false, true]) {
    test('AI 수정 적용은 실제 변경된 개념만 검토 상태와 함께 원자적으로 저장한다 ($markReviewed)', () async {
      final source = await sourceRepository.saveImport(
        folderId: folderId,
        result: _result(),
      );
      final changed = source.concepts.single;
      final unchanged = await sourceRepository.addConcept(
        sourceId: source.source.id,
        title: '그대로 둘 개념',
        content: '이 내용과 검토 상태는 변경하지 않아야 합니다.',
        reviewed: false,
      );
      await sourceRepository.setConceptApproval(id: changed.id, approved: true);
      final result = await sourceRepository.applyConceptRevisions(
        sourceId: source.source.id,
        markReviewed: markReviewed,
        revisions: [
          ConceptRevision(
            id: changed.id,
            title: changed.title,
            content: '${changed.content} 수정',
            pageNumbers: changed.pageNumbers,
            importance: changed.importance,
          ),
          ConceptRevision(
            id: unchanged.id,
            title: unchanged.title,
            content: unchanged.content,
            pageNumbers: unchanged.pageNumbers,
            importance: unchanged.importance,
          ),
        ],
      );
      final expected = markReviewed
          ? ConceptStatus.approved
          : ConceptStatus.held;
      expect(result.changedCount, 1);
      expect(result.review.concepts.first.status, expected);
      expect(result.review.concepts.last.status, ConceptStatus.held);
      final payloads = await DriftSyncRepository(database).buildPushBatch();
      expect(
        payloads
            .lastWhere((entry) => entry.entityId == changed.id)
            .payload!['status'],
        expected.name,
      );
      // Invalid batches must not partially apply either content or review state.
      await expectLater(
        sourceRepository.applyConceptRevisions(
          sourceId: source.source.id,
          markReviewed: true,
          revisions: [
            ConceptRevision(
              id: changed.id,
              title: changed.title,
              content: '저장되면 안 되는 변경',
              pageNumbers: changed.pageNumbers,
              importance: changed.importance,
            ),
            ConceptRevision(
              id: 'missing',
              title: '없는 개념',
              content: '내용',
              pageNumbers: const [],
              importance: ConceptImportance.medium,
            ),
          ],
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect(
        (await sourceRepository.getSourceWithConcepts(source.source.id))
            .concepts
            .first
            .content,
        '${changed.content} 수정',
      );
    });
  }

  test('자료 및 개념 추가의 잘못된 입력은 저장과 Outbox를 변경하지 않는다', () async {
    for (final name in ['', '  ', List.filled(201, 'a').join()]) {
      await expectLater(
        sourceRepository.createSource(folderId: folderId, name: name),
        throwsA(isA<ValidationFailure>()),
      );
    }
    await expectLater(
      sourceRepository.createSource(folderId: 'missing', name: '노트'),
      throwsA(isA<ValidationFailure>()),
    );
    final empty = await sourceRepository.createSource(
      folderId: folderId,
      name: '노트',
    );
    final sync = DriftSyncRepository(database);
    final count = (await sync.getPending()).length;
    for (final entry in [
      ('', '내용'),
      ('제목', ''),
      (List.filled(201, 'a').join(), '내용'),
      ('제목', List.filled(8001, 'a').join()),
    ]) {
      await expectLater(
        sourceRepository.addConcept(
          sourceId: empty.source.id,
          title: entry.$1,
          content: entry.$2,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    }
    await expectLater(
      sourceRepository.addConcept(
        sourceId: 'missing',
        title: '제목',
        content: '내용',
      ),
      throwsA(isA<ValidationFailure>()),
    );
    expect(
      (await sourceRepository.getSourceWithConcepts(empty.source.id)).concepts,
      isEmpty,
    );
    expect((await sync.getPending()).length, count);
  });

  test('PDF에 직접 추가한 개념은 추출 개념 뒤에 유지되고 AI가 페이지 출처를 만들거나 지울 수 없다', () async {
    final pdf = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final first = await sourceRepository.addConcept(
      sourceId: pdf.source.id,
      title: '후기',
      content: '개인적으로 작성한 첫 번째 메모',
    );
    final second = await sourceRepository.addConcept(
      sourceId: pdf.source.id,
      title: '가나다',
      content: '개인적으로 작성한 두 번째 메모',
    );
    final mixed = await sourceRepository.getSourceWithConcepts(pdf.source.id);
    expect(mixed.concepts.map((concept) => concept.id), [
      pdf.concepts.single.id,
      first.id,
      second.id,
    ]);
    await sourceRepository.setConceptApproval(id: first.id, approved: true);
    final applied = await sourceRepository.applyConceptRevisions(
      sourceId: pdf.source.id,
      revisions: [
        ConceptRevision(
          id: first.id,
          title: first.title,
          content: '${first.content} 수정',
          pageNumbers: const [],
          importance: first.importance,
        ),
      ],
    );
    expect(applied.changedCount, 1);
    expect(applied.review.concepts[1].status, ConceptStatus.held);
    expect(applied.review.concepts[1].pageNumbers, isEmpty);
    for (final entry in [
      (first, <int>[1]),
      (pdf.concepts.single, <int>[]),
    ]) {
      await expectLater(
        sourceRepository.applyConceptRevisions(
          sourceId: pdf.source.id,
          revisions: [
            ConceptRevision(
              id: entry.$1.id,
              title: entry.$1.title,
              content: '잘못된 출처 변경',
              pageNumbers: entry.$2,
              importance: entry.$1.importance,
            ),
          ],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    }
  });

  test('빈 자료와 수동 개념, 출처가 연결된 문제는 기존 동기화로 복원된다', () async {
    final empty = await sourceRepository.createSource(
      folderId: folderId,
      name: '빈 자료',
    );
    final material = await sourceRepository.createSource(
      folderId: folderId,
      name: '노트',
    );
    final concept = await sourceRepository.addConcept(
      sourceId: material.source.id,
      title: '메모',
      content: '동기화할 내용',
    );
    await sourceRepository.setConceptApproval(id: concept.id, approved: true);
    final questions = DriftQuestionRepository(database);
    final ids = await questions.createQuestions(
      [
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '메모 문제',
          acceptableAnswers: const ['정답'],
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: material.source.id,
          conceptId: concept.id,
          pageNumbers: const [],
        ),
      ],
    );
    final changes = await DriftSyncRepository(database).buildPushBatch();
    await database.close();
    databaseClosed = true;
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    await DriftSyncRepository(target).applyPulledChanges([
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
    final repository = DriftSourceRepository(target);
    expect(
      (await repository.getSourceWithConcepts(empty.source.id)).concepts,
      isEmpty,
    );
    final restored = await repository.getSourceWithConcepts(material.source.id);
    expect(restored.source.isManual, isTrue);
    expect(restored.concepts.single.status, ConceptStatus.approved);
    expect(restored.concepts.single.pageNumbers, isEmpty);
    expect(
      (await DriftQuestionRepository(target).getQuestion(ids.single))!
          .sourceReferences
          .single
          .conceptId,
      concept.id,
    );
    expect(
      (await repository.getConceptGenerationSeed(concept.id)).sourceText,
      contains('동기화할 내용'),
    );
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

  test('자료 전체 문제 생성은 승인 개념만 페이지 순으로 묶고 출처를 보존한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: DocumentImportResult(
        source: _result().source,
        concepts: const [
          ImportedConcept(
            title: '나중 개념',
            content: '마지막 페이지의 승인 내용',
            pageNumbers: [9],
          ),
          ImportedConcept(
            title: '처음 개념',
            content: '첫 페이지의 승인 내용',
            pageNumbers: [2, 1],
          ),
          ImportedConcept(
            title: '보류 개념',
            content: '생성에 포함하면 안 되는 내용',
            pageNumbers: [3],
          ),
          ImportedConcept(
            title: '삭제 개념',
            content: '삭제 후 제외해야 하는 내용',
            pageNumbers: [4],
          ),
        ],
      ),
    );
    for (final concept in saved.concepts.where(
      (concept) => concept.title != '보류 개념',
    )) {
      await sourceRepository.setConceptApproval(id: concept.id, approved: true);
    }
    await sourceRepository.deleteConcept(
      saved.concepts.singleWhere((concept) => concept.title == '삭제 개념').id,
    );
    final seed = await sourceRepository.getSourceGenerationSeed(
      saved.source.id,
    );
    expect(seed.folderId, folderId);
    expect(seed.sourceLabel, saved.source.fileName);
    expect(seed.concepts.map((concept) => concept.title), ['처음 개념', '나중 개념']);
    expect(seed.sourceText, contains('1. 처음 개념'));
    expect(seed.sourceText, contains('2. 나중 개념'));
    expect(seed.sourceText, isNot(contains('보류 개념')));
    expect(seed.sourceText, isNot(contains('삭제 개념')));
    expect(seed.sourceReference.sourceId, saved.source.id);
    expect(seed.sourceReference.pageNumbers, [1, 2, 9]);
    expect(seed.sourceReference.conceptId, isNull);
  });

  test('승인 개념이 없거나 모두 승인 해제되면 자료 전체 문제 생성을 거부한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    await expectLater(
      sourceRepository.getSourceGenerationSeed(saved.source.id),
      throwsA(isA<ValidationFailure>()),
    );
    await sourceRepository.setConceptApproval(
      id: saved.concepts.single.id,
      approved: true,
    );
    expect(
      (await sourceRepository.getSourceGenerationSeed(saved.source.id))
          .concepts,
      hasLength(1),
    );
    await sourceRepository.setConceptApproval(
      id: saved.concepts.single.id,
      approved: false,
    );
    await expectLater(
      sourceRepository.getSourceGenerationSeed(saved.source.id),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('삭제되었거나 없는 PDF는 자료 전체 문제 생성에 사용할 수 없다', () async {
    await expectLater(
      sourceRepository.getSourceGenerationSeed('missing'),
      throwsA(isA<ValidationFailure>()),
    );
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    await sourceRepository.setConceptApproval(
      id: saved.concepts.single.id,
      approved: true,
    );
    await sourceRepository.deleteSource(saved.source.id);
    await expectLater(
      sourceRepository.getSourceGenerationSeed(saved.source.id),
      throwsA(isA<ValidationFailure>()),
    );
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

  test('확인한 AI 추가·삭제를 원자적으로 적용하고 기존 문제와 동기화를 보존한다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final original = saved.concepts.single;
    final questions = DriftQuestionRepository(database);
    final ids = await questions.createQuestions(
      [
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '기존 문제',
          acceptableAnswers: const ['정답'],
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: saved.source.id,
          conceptId: original.id,
          pageNumbers: original.pageNumbers,
        ),
      ],
    );
    final snapshot = await sourceRepository.getSourceWithConcepts(
      saved.source.id,
    );
    final beforePending = await database.syncDao.getPendingCount();
    await database.questionDao.updateQuestion(
      ids.single,
      QuestionsCompanion(updatedAt: Value(DateTime.utc(2020))),
    );
    final addition = const ConceptRevision(
      id: 'proposal-new',
      title: '새로운 개념',
      content: '요청한 새로운 개념',
      pageNumbers: [],
      importance: ConceptImportance.veryHigh,
      kind: ConceptChangeKind.add,
      groupId: 'replace',
    );
    final deletion = ConceptRevision(
      id: original.id,
      title: '',
      content: '',
      pageNumbers: const [],
      importance: ConceptImportance.medium,
      kind: ConceptChangeKind.delete,
      reason: '기존 개념을 교체',
      groupId: 'replace',
    );
    final all = [addition, deletion];
    await expectLater(
      sourceRepository.applyConceptRevisions(
        sourceId: saved.source.id,
        revisions: [addition],
        allChanges: all,
        expectedConcepts: snapshot.concepts,
        editableConceptIds: {original.id},
        allowAdditions: true,
        allowDeletions: true,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await database.syncDao.getPendingCount(), beforePending);
    expect(
      (await sourceRepository.getSourceWithConcepts(saved.source.id))
          .concepts
          .single
          .id,
      original.id,
    );
    final result = await sourceRepository.applyConceptRevisions(
      sourceId: saved.source.id,
      revisions: all,
      allChanges: all,
      expectedConcepts: snapshot.concepts,
      editableConceptIds: {original.id},
      allowAdditions: true,
      allowDeletions: true,
    );
    expect(result.changedCount, 2);
    final created = result.review.concepts.single;
    expect(created.id, isNot(addition.id));
    expect(created.status, ConceptStatus.held);
    expect(created.importance, ConceptImportance.veryHigh);
    expect(created.pageNumbers, isEmpty);
    final question = (await questions.getQuestion(ids.single))!;
    expect(question.prompt, '기존 문제');
    expect(question.sourceReferences.single.conceptId, isNull);
    expect(question.sourceReferences.single.sourceId, saved.source.id);
    expect(question.sourceReferences.single.pageNumbers, original.pageNumbers);
    expect(question.updatedAt.isAfter(DateTime.utc(2020)), isTrue);
    expect(await database.syncDao.getPendingCount(), beforePending + 3);
    final batch = await DriftSyncRepository(database).buildPushBatch();
    expect(
      batch.any(
        (item) => item.entityId == original.id && item.operation == 'delete',
      ),
      isTrue,
    );
    expect(
      batch
          .lastWhere((item) => item.entityId == ids.single)
          .payload!['sourceReferences'],
      [containsPair('conceptId', null)],
    );
  });

  test('원본 변경·권한·중복·출처 오류는 데이터와 Outbox를 변경하지 않는다', () async {
    final saved = await sourceRepository.saveImport(
      folderId: folderId,
      result: _result(),
    );
    final original = saved.concepts.single;
    final snapshot = await sourceRepository.getSourceWithConcepts(
      saved.source.id,
    );
    final addition = const ConceptRevision(
      id: 'new',
      title: '새 개념',
      content: '새 내용',
      pageNumbers: [],
      importance: ConceptImportance.low,
      kind: ConceptChangeKind.add,
    );
    final before = await database.syncDao.getPendingCount();
    await expectLater(
      sourceRepository.applyConceptRevisions(
        sourceId: saved.source.id,
        revisions: [addition],
        expectedConcepts: snapshot.concepts,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    final badPage = const ConceptRevision(
      id: 'bad',
      title: '새 개념',
      content: '새 내용',
      pageNumbers: [10],
      importance: ConceptImportance.low,
      kind: ConceptChangeKind.add,
    );
    await expectLater(
      sourceRepository.applyConceptRevisions(
        sourceId: saved.source.id,
        revisions: [addition, badPage],
        allowAdditions: true,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    final duplicate = ConceptRevision(
      id: 'duplicate',
      title: original.title,
      content: '내용',
      pageNumbers: const [],
      importance: ConceptImportance.medium,
      kind: ConceptChangeKind.add,
    );
    await expectLater(
      sourceRepository.applyConceptRevisions(
        sourceId: saved.source.id,
        revisions: [addition, duplicate],
        allowAdditions: true,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await database.syncDao.getPendingCount(), before);
    await sourceRepository.updateConcept(
      id: original.id,
      title: original.title,
      content: '사용자가 대기 중 수정한 내용',
      importance: original.importance,
    );
    final afterEdit = await database.syncDao.getPendingCount();
    await expectLater(
      sourceRepository.applyConceptRevisions(
        sourceId: saved.source.id,
        revisions: [addition],
        expectedConcepts: snapshot.concepts,
        allowAdditions: true,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await database.syncDao.getPendingCount(), afterEdit);
    expect(
      (await sourceRepository.getSourceWithConcepts(saved.source.id))
          .concepts
          .single
          .content,
      '사용자가 대기 중 수정한 내용',
    );
  });

  test('빈 사용자 자료에도 AI 개념을 추가하고 명시적으로 검토 완료할 수 있다', () async {
    final saved = await sourceRepository.createSource(
      folderId: folderId,
      name: '새 자료',
    );
    final result = await sourceRepository.applyConceptRevisions(
      sourceId: saved.source.id,
      revisions: const [
        ConceptRevision(
          id: 'new',
          title: '새 개념',
          content: '새 내용',
          pageNumbers: [],
          importance: ConceptImportance.high,
          kind: ConceptChangeKind.add,
        ),
      ],
      expectedConcepts: const [],
      allowAdditions: true,
      markReviewed: true,
    );
    expect(result.review.concepts.single.status, ConceptStatus.approved);
    expect(result.review.concepts.single.pageNumbers, isEmpty);
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
