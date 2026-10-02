import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';

import 'support/fake_ai.dart';
import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late String folderId;
  late FakeRemoteAiApi api;
  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    folderId = await DriftFolderRepository(database)
        .createFolder(name: '난이도 테스트');
    api = FakeRemoteAiApi();
  });
  tearDown(() => database.close());

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final mode in AiQuestionGenerationMode.values) {
    testWidgets(
      '$mode 생성 목표 범위를 전달하되 최종 난이도는 AI 평가를 저장한다',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(database),
              isWindowsPlatformProvider.overrideWithValue(false),
              remoteAiApiProvider.overrideWithValue(api),
              syncCredentialsStoreProvider.overrideWithValue(
                MemorySyncCredentialsStore(
                  configuration: const SyncConfiguration(
                    serverUrl: 'http://127.0.0.1:5080',
                    accessToken: 'test-token',
                  ),
                ),
              ),
              remoteSyncApiProvider.overrideWithValue(FakeRemoteSyncApi()),
            ],
            child: const ReviewApp(),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go('${AppRoutes.aiGenerate}?folderId=$folderId');
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('ai-source-text-field')),
          '목표 난이도와 별개로 완성된 문항의 평가를 저장하는 학습 내용',
        );
        final finder = find.byKey(const Key('ai-difficulty-range-slider'));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        var slider = tester.widget<RangeSlider>(finder);
        expect(slider.values, const RangeValues(1, 5));
        expect(slider.divisions, 4);
        expect(slider.semanticFormatterCallback!(3), '3 · 보통');
        final rect = tester.getRect(finder);
        final start = Offset(rect.left + 24, rect.center.dy);
        final end = Offset(rect.right - 24, rect.center.dy);
        final step = (end.dx - start.dx) / 4;
        var gesture = await tester.startGesture(start);
        await gesture.moveBy(Offset(step, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          tester.widget<RangeSlider>(finder).values,
          const RangeValues(2, 5),
        );
        gesture = await tester.startGesture(end);
        await gesture.moveBy(Offset(-step, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        slider = tester.widget<RangeSlider>(finder);
        expect(slider.values, const RangeValues(2, 4));
        expect(slider.labels, const RangeLabels('2 · 쉬움', '4 · 어려움'));
        // Equal endpoints are supported, but never fix generated difficulty to that value.
        slider.onChanged!(const RangeValues(4, 4));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('ai-difficulty-range-label')))
              .data,
          '4 ~ 4',
        );
        if (mode == AiQuestionGenerationMode.manual) {
          await tapVisible(
            tester,
            find.byKey(const Key('ai-count-mode-manual')),
          );
          await tester.enterText(
            find.byKey(const Key('ai-manual-question-count-field')),
            '2',
          );
        }
        await tapVisible(
          tester,
          find.byKey(const Key('generate-ai-questions-button')),
        );
        expect(api.lastRequest!.minimumDifficulty, 4);
        expect(api.lastRequest!.maximumDifficulty, 4);
        expect(api.lastRequest!.generationMode, mode);
        final questions = (await tester.runAsync(
          () =>
              DriftQuestionRepository(database).watchQuestions(folderId).first,
        ))!;
        expect(
          questions,
          hasLength(mode == AiQuestionGenerationMode.manual ? 2 : 4),
        );
        expect(questions.map((question) => question.difficulty).toSet(), {
          1,
          2,
        });
        expect(find.text('난이도 4/5'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }
}
