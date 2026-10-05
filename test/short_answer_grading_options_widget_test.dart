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
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';

import 'support/fake_sync.dart';

void main() {
  testWidgets(
    '단답형 채점 토글은 기본 꺼짐이고 저장·재진입·개별 변경이 가능하다',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final folder = await DriftFolderRepository(db).createFolder(name: '설정');
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
      final router = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      ).read(routerProvider);
      router.push('${AppRoutes.newQuestion}?folderId=$folder');
      await tester.pumpAndSettle();
      final caseToggle = find.byKey(
        const Key('short-answer-case-sensitive-switch'),
      );
      final spaceToggle = find.byKey(
        const Key('short-answer-whitespace-sensitive-switch'),
      );
      expect(caseToggle, findsNothing);
      await tester.tap(find.text('단답형'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(caseToggle).value, false);
      expect(tester.widget<SwitchListTile>(spaceToggle).value, false);
      await tester.enterText(
        find.byKey(const Key('question-prompt-field')),
        '영어 용어는?',
      );
      final answer = find.byKey(const Key('answer-field-0'));
      await tester.ensureVisible(answer);
      await tester.pumpAndSettle();
      await tester.enterText(answer, 'Cache Hit');
      for (final toggle in [caseToggle, spaceToggle]) {
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(toggle).value, true);
      }
      final save = find.byKey(const Key('save-question-button'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final repo = DriftQuestionRepository(db);
      final id = (await db.questionDao.getActiveQuestionIdsInFolders([folder]))
          .single;
      final created = (await repo.getQuestion(id))!;
      expect(created.caseSensitive, true);
      expect(created.whitespaceSensitive, true);
      router.push(AppRoutes.editQuestion(id));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(caseToggle).value, true);
      expect(tester.widget<SwitchListTile>(spaceToggle).value, true);
      await tester.ensureVisible(caseToggle);
      await tester.pumpAndSettle();
      await tester.tap(caseToggle);
      await tester.pumpAndSettle();
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final edited = (await repo.getQuestion(id))!;
      expect(edited.caseSensitive, false);
      expect(edited.whitespaceSensitive, true);
      router.push(AppRoutes.editQuestion(id));
      await tester.pumpAndSettle();
      await tester.tap(find.text('서술형'));
      await tester.pumpAndSettle();
      expect(caseToggle, findsNothing);
      expect(spaceToggle, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
