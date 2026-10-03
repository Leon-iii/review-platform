import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

void main() {
  for (final statisticsFirst in [true, false]) {
    test('동기화·통계 관찰을 구독 순서와 무관하게 갱신한다 (통계 먼저: $statisticsFirst)', () async {
      final database = AppDatabase(NativeDatabase.memory());
      final repository = DriftSyncRepository(database);
      StreamSubscription? statistics;
      StreamSubscription? status;
      final statisticsReady = Completer<void>();
      final statusReady = Completer<void>();
      final cleared = Completer<void>();
      final pending = Completer<void>();
      final folderUpdated = Completer<void>();
      await repository.recordFailure('개인 서버에 연결할 수 없어요.');
      void watchStatistics() {
        statistics = database.statisticsDao.watchSnapshot().listen((value) {
          if (!statisticsReady.isCompleted) statisticsReady.complete();
          if (value.folders.any((folder) => folder.name == '새 폴더') &&
              !folderUpdated.isCompleted) {
            folderUpdated.complete();
          }
        });
      }

      void watchStatus() {
        status = repository.watchStatus().listen((value) {
          if (!statusReady.isCompleted) statusReady.complete();
          if (value.lastError == null &&
              value.lastSyncedAt != null &&
              !cleared.isCompleted) {
            cleared.complete();
          }
          if (value.pendingCount == 1 && !pending.isCompleted) {
            pending.complete();
          }
        });
      }

      try {
        if (statisticsFirst) {
          watchStatistics();
          await statisticsReady.future;
          watchStatus();
          await statusReady.future;
        } else {
          watchStatus();
          await statusReady.future;
          watchStatistics();
          await statisticsReady.future;
        }
        await repository.recordSuccess(revision: 0, at: DateTime.now().toUtc());
        await cleared.future.timeout(const Duration(seconds: 2));
        expect((await repository.getStatus()).lastError, isNull);
        await DriftFolderRepository(database).createFolder(name: '새 폴더');
        await Future.wait([pending.future, folderUpdated.future])
            .timeout(const Duration(seconds: 2));
      } finally {
        // Cancel both observers before closing the shared DB. Do not serialize
        // cancellation of async generators while another observer is paused.
        if (status != null) unawaited(status!.cancel());
        if (statistics != null) unawaited(statistics!.cancel());
        await database.close();
      }
    });
  }
}
