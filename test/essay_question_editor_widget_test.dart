import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';

import 'support/fake_sync.dart';

void main() {
  testWidgets(
    '서술형을 직접 작성·편집하고 모범답안을 저장한다',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final folder = await DriftFolderRepository(db)
          .createFolder(name: '직접 작성');
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 950)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            isWindowsPlatformProvider.overrideWithValue(false),
            syncCredentialsStoreProvider.overrideWithValue(
              MemorySyncCredentialsStore(),
            ),
          ],
          child: const ReviewApp(),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      final router = container.read(routerProvider);
      router.push('${AppRoutes.newQuestion}?folderId=$folder');
      await tester.pumpAndSettle();
      await tester.tap(find.text('서술형'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('question-prompt-field')),
        '캐시 히트와 미스를 설명하시오.',
      );
      final answer = find.byKey(const Key('answer-field-0'));
      await tester.ensureVisible(answer);
      await tester.pumpAndSettle();
      await tester.enterText(
        answer,
        '캐시에 객체가 있으면 히트, 없으면 미스다.\n미스일 때는 원본 서버에서 가져온다.',
      );
      final save = find.byKey(const Key('save-question-button'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final repo = DriftQuestionRepository(db);
      final ids = await db.questionDao.getActiveQuestionIdsInFolders([folder]);
      final stored = (await repo.getQuestion(ids.single))!;
      expect(stored.type, QuestionType.essay);
      expect(stored.acceptableAnswers.single.text, contains('\n미스일 때'));
      expect(stored.choices, isEmpty);
      router.push(AppRoutes.editQuestion(stored.id));
      await tester.pumpAndSettle();
      expect(find.text('모범 답안'), findsOneWidget);
      await tester.ensureVisible(answer);
      await tester.pumpAndSettle();
      await tester.enterText(answer, '수정한 모범 답안.');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        (await repo.getQuestion(stored.id))!.acceptableAnswers.single.text,
        '수정한 모범 답안.',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
