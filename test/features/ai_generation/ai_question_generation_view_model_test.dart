import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/features/ai_generation/ai_question_generation_view_model.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/repositories/repository_providers.dart';

import '../../support/fake_ai.dart';
import '../../support/fake_sync.dart';

void main() {
  test('AI 순서 배열형은 정답 순서를 ID로 저장하고 주개념·중요도·실제 난이도를 유지한다', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final folder = await DriftFolderRepository(db).createFolder(name: '과정');
    final sources = DriftSourceRepository(db);
    final source = (await sources.createSource(
      folderId: folder,
      name: '자료',
    )).source;
    final concept = await sources.addConcept(
      sourceId: source.id,
      title: '처리 과정',
      content: '설정을 완료하고 정보를 처리한 뒤 결과를 저장한다.',
      importance: ConceptImportance.high,
    );
    final remote = FakeRemoteAiApi();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        remoteAiApiProvider.overrideWithValue(remote),
        syncCredentialsStoreProvider.overrideWithValue(
          MemorySyncCredentialsStore(
            configuration: const SyncConfiguration(
              serverUrl: 'http://127.0.0.1:5080',
              accessToken: 'token',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final provider = aiQuestionGenerationControllerProvider(folder);
    await container
        .read(provider.notifier)
        .generate(
          folderId: folder,
          sourceText: concept.content,
          concepts: [concept],
          questionCount: 1,
          questionTypes: {QuestionType.ordering},
          minimumDifficulty: 4,
          maximumDifficulty: 5,
          sourceReference: QuestionSourceDraft(
            sourceId: source.id,
            pageNumbers: const [],
          ),
        );
    final item = container.read(provider).requireValue!.items.single;
    final question = (await container
        .read(questionRepositoryProvider)
        .getQuestion(item.questionId))!;
    expect(question.type, QuestionType.ordering);
    expect(question.correctChoiceIds, question.choices.map((c) => c.id));
    expect(question.primaryConceptId, concept.id);
    expect(question.importance, ConceptImportance.high);
    expect(question.difficulty, 2);
    expect(question.status, QuestionStatus.draft);
    await container.read(provider.notifier).approveAll();
    expect(
      (await container
              .read(questionRepositoryProvider)
              .getQuestion(item.questionId))!
          .status,
      QuestionStatus.approved,
    );
  });
  for (final invalidId in [false, true]) {
    test('문항별 주개념 연결을 검증하고 중요도를 상속한다 (잘못된 ID: $invalidId)', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final folder = await DriftFolderRepository(db).createFolder(name: '자료');
      final sources = DriftSourceRepository(db);
      final source = (await sources.createSource(
        folderId: folder,
        name: '자료',
      )).source;
      final concepts = [
        await sources.addConcept(
          sourceId: source.id,
          title: '지엽적',
          content: '충분히 긴 개념 내용입니다.',
          importance: ConceptImportance.veryLow,
        ),
        await sources.addConcept(
          sourceId: source.id,
          title: '핵심',
          content: '충분히 긴 핵심 개념 내용입니다.',
          importance: ConceptImportance.veryHigh,
        ),
      ];
      final remote = FakeRemoteAiApi()..invalidConceptId = invalidId;
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          remoteAiApiProvider.overrideWithValue(remote),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(
              configuration: const SyncConfiguration(
                serverUrl: 'http://127.0.0.1:5080',
                accessToken: 'token',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final provider = aiQuestionGenerationControllerProvider(folder);
      final request = container
          .read(provider.notifier)
          .generate(
            folderId: folder,
            sourceText: '구조화된 개념 내용으로 문제를 생성합니다.',
            questionCount: 2,
            questionTypes: {QuestionType.shortAnswer},
            minimumDifficulty: 4,
            maximumDifficulty: 5,
            concepts: concepts,
            reflectConceptImportance: true,
            sourceReference: QuestionSourceDraft(
              sourceId: source.id,
              pageNumbers: const [],
            ),
          );
      final questions = container.read(questionRepositoryProvider);
      if (invalidId) {
        await expectLater(request, throwsA(isA<ValidationFailure>()));
        expect(await questions.watchQuestions(folder).first, isEmpty);
      } else {
        await request;
        for (var i = 0; i < 2; i++) {
          final item = container.read(provider).requireValue!.items[i];
          final question = (await questions.getQuestion(item.questionId))!;
          expect(question.primaryConceptId, concepts[i].id);
          expect(question.importance, concepts[i].importance);
          expect(question.difficulty, 1);
          expect(question.status, QuestionStatus.draft);
        }
      }
      final json = remote.lastRequest!.toJson();
      expect(json['reflectConceptImportance'], true);
      expect((json['concepts']! as List).last['importance'], 'veryHigh');
    });
  }

  test('생성 결과를 Draft로 저장하고 모두 승인한다', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '전자기학');
    final credentials = MemorySyncCredentialsStore(
      configuration: const SyncConfiguration(
        serverUrl: 'http://127.0.0.1:5080',
        accessToken: 'token',
      ),
    );
    final remote = FakeRemoteAiApi();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        syncCredentialsStoreProvider.overrideWithValue(credentials),
        remoteAiApiProvider.overrideWithValue(remote),
      ],
    );
    addTearDown(container.dispose);
    final provider = aiQuestionGenerationControllerProvider(folderId);

    await container
        .read(provider.notifier)
        .generate(
          folderId: folderId,
          sourceText: '가우스 법칙에 관한 충분히 긴 학습 내용입니다.',
          questionCount: 2,
          questionTypes: {
            QuestionType.multipleChoice,
            QuestionType.shortAnswer,
          },
        );

    final review = container.read(provider).requireValue!;
    expect(remote.callCount, 1);
    expect(review.items, hasLength(2));
    final repository = container.read(questionRepositoryProvider);
    for (final item in review.items) {
      expect(
        (await repository.getQuestion(item.questionId))!.status,
        QuestionStatus.draft,
      );
    }

    await container.read(provider.notifier).approveAll();

    expect(container.read(provider).requireValue!.pendingCount, 0);
    for (final item in review.items) {
      expect(
        (await repository.getQuestion(item.questionId))!.status,
        QuestionStatus.approved,
      );
    }
  });
}
