import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/features/settings/settings_view_model.dart';
import 'package:review_platform/repositories/sync_repository.dart';

import 'support/fake_sync.dart';

void main() {
  testWidgets(
    '홈 통계 구독 이후 0건 수동 동기화에 성공하면 이전 오류 박스를 제거한다',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final api = _OfflineApi();
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(900, 1200)
            : const Size(390, 1000),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            isWindowsPlatformProvider.overrideWithValue(false),
            remoteSyncApiProvider.overrideWithValue(api),
            syncCredentialsStoreProvider.overrideWithValue(
              MemorySyncCredentialsStore(
                configuration: const SyncConfiguration(
                  serverUrl: 'http://127.0.0.1:5080',
                  accessToken: 'token',
                ),
              ),
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
      container.read(routerProvider).go(AppRoutes.settings);
      await tester.pumpAndSettle();
      expect(find.text('개인 서버에 연결할 수 없어요.'), findsOneWidget);
      expect(find.text('오류가 발생했어요'), findsOneWidget);
      api.offline = false;
      final sync = find.byKey(const Key('manual-sync-button'));
      await tester.ensureVisible(sync);
      await tester.tap(sync);
      await tester.pumpAndSettle();
      expect(find.text('동기화 완료: 업로드 0건, 다운로드 0건'), findsOneWidget);
      expect(
        (await DriftSyncRepository(database).getStatus()).lastError,
        isNull,
      );
      expect(container.read(syncStatusProvider).requireValue.lastError, isNull);
      expect(find.text('개인 서버에 연결할 수 없어요.'), findsNothing);
      expect(find.text('오류가 발생했어요'), findsNothing);
      // A real new failure must still appear; do not hide the notice locally.
      api.offline = true;
      await container.read(automaticSyncControllerProvider).onForeground();
      await tester.pumpAndSettle();
      expect(find.text('개인 서버에 연결할 수 없어요.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}

class _OfflineApi extends FakeRemoteSyncApi {
  bool offline = true;
  @override
  Future<PullSyncResponse> pull({
    required SyncConfiguration configuration,
    required int sinceRevision,
    int limit = 500,
  }) {
    if (offline) throw const NetworkFailure('개인 서버에 연결할 수 없어요.');
    return super.pull(
      configuration: configuration,
      sinceRevision: sinceRevision,
      limit: limit,
    );
  }
}
