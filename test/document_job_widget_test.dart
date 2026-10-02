import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';

import 'support/fake_pdf_jobs.dart';
import 'support/fake_sync.dart';

void main() {
  testWidgets('폴더에서 진행 중인 자료를 열고 취소·재시도·완료 검토로 연결한다', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '자료 폴더');
    final jobs = DocumentJobRepository(database);
    const id = 'pending-job';
    final api = FakePdfJobsApi()..jobs[id] = pdfJob(id);
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          isWindowsPlatformProvider.overrideWithValue(false),
          remoteDocumentApiProvider.overrideWithValue(api),
          remoteSyncApiProvider.overrideWithValue(FakeRemoteSyncApi()),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(
              configuration: const SyncConfiguration(
                serverUrl: 'http://server:5080',
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
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    final router = container.read(routerProvider);
    router.go(AppRoutes.folder(folderId));
    await settle();
    expect(find.byKey(const Key('pdf-job-pending-job')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pdf-job-pending-job')));
    await settle();
    expect(find.text('페이지 분석 12 / 80 페이지'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('pdf-import-progress')),
          )
          .value,
      greaterThan(0),
    );
    await tester.tap(find.byKey(const Key('cancel-pdf-job')));
    await settle();
    expect(find.text('취소됨'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-pdf-job')));
    await settle();
    expect(find.text('분석 대기 중'), findsOneWidget);
    api.jobs[id] = pdfJob(id, status: 'completed');
    await container.read(documentJobCoordinatorProvider)!.poll();
    await settle();
    expect(find.text('검토할 개념 내용'), findsOneWidget);
    expect(find.byKey(const Key('cancel-pdf-job')), findsNothing);
    expect((await jobs.get(id))!.applied, isTrue);
    router.go(AppRoutes.folder(folderId));
    await settle();
    expect(find.byKey(const Key('pdf-job-pending-job')), findsNothing);
    expect(find.text('긴 강의.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
