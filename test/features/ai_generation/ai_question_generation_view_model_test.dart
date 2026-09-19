import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/features/ai_generation/ai_question_generation_view_model.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/repository_providers.dart';

import '../../support/fake_ai.dart';
import '../../support/fake_sync.dart';

void main() {
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
