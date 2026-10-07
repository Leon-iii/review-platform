import 'dart:async';

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
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_pdf_jobs.dart';
import 'support/fake_pdf_extraction.dart';
import 'support/fake_sync.dart';

void main() {
  testWidgets(
    '미완료 PDF를 폴더 메뉴로 이동하고 새 폴더에서 완료 결과를 연다',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final folders = DriftFolderRepository(database);
      final originId = await folders.createFolder(name: '원래 폴더');
      final archiveId = await folders.createFolder(name: '보관함');
      final targetId = await folders.createFolder(
        name: '복습',
        parentId: archiveId,
      );
      final jobs = DocumentJobRepository(database);
      const id = 'moving-job';
      final api = FakePdfExtractionApi()
        ..jobs[id] = pdfJob(id, status: 'awaiting_review', completedPages: 80);
      await jobs.add(
        folderId: originId,
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
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      final router = container.read(routerProvider);
      final coordinator = container.read(documentJobCoordinatorProvider)!;
      router.go(AppRoutes.folder(originId));
      await tester.pumpAndSettle();
      Future<void> openMove() async {
        await tester.tap(find.byKey(const Key('pdf-job-menu-moving-job')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('이동'));
        await tester.pumpAndSettle();
      }

      await openMove();
      expect(find.text('자료 이동'), findsOneWidget);
      expect(find.byKey(const Key('folder-picker-root-item')), findsNothing);
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect((await jobs.get(id))!.folderId, originId);
      api.offline = true;
      await openMove();
      await tester.enterText(
        find.byKey(const Key('folder-picker-search-field')),
        '보관함',
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(Key('folder-picker-item-$targetId'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folder-picker-item-$targetId')));
      await tester.pumpAndSettle();
      expect((await jobs.get(id))!.folderId, targetId);
      expect(find.byKey(const Key('pdf-job-moving-job')), findsNothing);
      expect(api.actions, isEmpty);
      expect(api.deletedJobs, isEmpty);
      router.go(AppRoutes.folder(targetId));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pdf-job-moving-job')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pdf-job-moving-job')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pdf-start-extraction')), findsOneWidget);
      router.go(AppRoutes.folder(targetId));
      await tester.pumpAndSettle();
      api.offline = false;
      api.jobs[id] = pdfJob(id, status: 'completed');
      await coordinator.poll();
      await tester.pumpAndSettle();
      expect(
        await DriftSourceRepository(database).getSources(originId),
        isEmpty,
      );
      expect(
        (await DriftSourceRepository(database).getSources(targetId)).single.id,
        id,
      );
      expect(find.byKey(const Key('pdf-job-moving-job')), findsNothing);
      expect(
        find.byKey(const Key('pdf-source-menu-moving-job')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('app-error-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  for (final detail in [false, true]) {
    testWidgets(
      '${detail ? '상세 화면' : '폴더 메뉴'}에서 예전 PDF 작업 삭제를 확인·취소·재시도한다',
      (tester) async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final folderId = await DriftFolderRepository(database)
            .createFolder(name: '자료');
        final jobs = DocumentJobRepository(database);
        const id = 'obsolete-job';
        final api = FakePdfExtractionApi()
          ..jobs[id] = pdfJob(
            id,
            status: 'failed',
            error: '서버의 분석 지침 버전이 변경되었습니다. PDF를 새 작업으로 다시 업로드해 주세요.',
          );
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
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        if (find
            .byKey(const Key('acknowledge-app-error'))
            .evaluate()
            .isNotEmpty) {
          await tester.tap(find.byKey(const Key('acknowledge-app-error')));
          await tester.pumpAndSettle();
        }
        final router = container.read(routerProvider);
        router.go(
          detail
              ? AppRoutes.documentsForJob(folderId, id)
              : AppRoutes.folder(folderId),
        );
        await tester.pumpAndSettle();
        Future<void> openDelete() async {
          final button = find.byKey(
            detail
                ? const Key('delete-pdf-job')
                : const Key('pdf-job-menu-obsolete-job'),
          );
          await Scrollable.ensureVisible(
            tester.element(button),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          if (!detail) {
            expect(
              find.descendant(
                of: button,
                matching: find.byIcon(Icons.more_vert_rounded),
              ),
              findsOneWidget,
            );
          }
          await tester.tap(button);
          await tester.pumpAndSettle();
          if (!detail) {
            await tester.tap(find.text('삭제'));
            await tester.pumpAndSettle();
          }
        }

        await openDelete();
        expect(find.text('PDF 작업 삭제'), findsWidgets);
        await tester.tap(find.byKey(const Key('cancel-delete-pdf-job')));
        await tester.pumpAndSettle();
        expect(api.deletedJobs, isEmpty);
        expect(await jobs.get(id), isNotNull);
        api.deleteError = const NetworkFailure('삭제 연결 실패');
        await openDelete();
        await tester.tap(find.byKey(const Key('confirm-delete-pdf-job')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
        expect(find.text('삭제 연결 실패'), findsOneWidget);
        expect(await jobs.get(id), isNotNull);
        await tester.tap(find.byKey(const Key('acknowledge-app-error')));
        await tester.pumpAndSettle();
        api.deleteError = null;
        await openDelete();
        await tester.tap(find.byKey(const Key('confirm-delete-pdf-job')));
        await tester.pumpAndSettle();
        expect(api.deletedJobs, [id]);
        expect(await jobs.get(id), isNull);
        expect(find.byKey(const Key('pdf-job-obsolete-job')), findsNothing);
        expect(find.byKey(const Key('delete-pdf-job')), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets('Windows 앱 시작 시 서버 health 준비 전에는 PDF를 조회하지 않는다', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '자료');
    final api = FakePdfExtractionApi()..jobs['startup'] = pdfJob('startup');
    final syncApi = FakeRemoteSyncApi();
    await DocumentJobRepository(database).add(
      folderId: folderId,
      serverUrl: 'http://127.0.0.1:5080',
      job: api.jobs['startup']!,
    );
    final ready = Completer<bool>();
    var launched = false;
    final service = LocalServerService(
      secretStore: _Secrets(),
      isWindows: true,
      healthCheck: (_) async => launched ? await ready.future : false,
      directoryResolver: () async => r'C:\test\server',
      accessTokenReader: () async => 'token',
      portAvailabilityCheck: (_) async => true,
      processLauncher:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            launched = true;
            return _Process();
          },
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          isWindowsPlatformProvider.overrideWithValue(true),
          localServerServiceProvider.overrideWithValue(service),
          localServerConfigStoreProvider.overrideWithValue(_Config()),
          remoteDocumentApiProvider.overrideWithValue(api),
          remoteSyncApiProvider.overrideWithValue(syncApi),
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
      if (!ready.isCompleted) ready.complete(false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(launched, isTrue);
    expect(service.currentState.status, LocalServerStatus.starting);
    expect(api.statusReads, isEmpty);
    expect(syncApi.pullCallCount, 0);
    expect(syncApi.pushedBatches, isEmpty);
    expect(find.byKey(const Key('app-error-dialog')), findsNothing);
    ready.complete(true);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    await container.read(documentJobCoordinatorProvider)!.poll();
    await tester.pumpAndSettle();
    expect(service.currentState.status, LocalServerStatus.running);
    expect(api.statusReads, isNotEmpty);
    expect(syncApi.pullCallCount, 1);
    expect(find.byKey(const Key('app-error-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '이전 작업의 연결 실패는 시작·재조회 시 오류 창과 오류 박스를 표시하지 않는다',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final folderId = await DriftFolderRepository(database)
          .createFolder(name: '자료');
      final jobs = DocumentJobRepository(database);
      final api = FakePdfExtractionApi()..offline = true;
      await jobs.add(
        folderId: folderId,
        serverUrl: 'http://server:5080',
        job: pdfJob(
          'waiting',
          status: 'awaiting_review',
          completedPages: 80,
          error: 'PDF 처리 서버에 연결할 수 없어요.',
        ),
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
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      await container.read(documentJobCoordinatorProvider)!.poll();
      container
          .read(routerProvider)
          .go(AppRoutes.documentsForJob(folderId, 'waiting'));
      await tester.pumpAndSettle();
      expect(find.text('PDF 추출 설정'), findsOneWidget);
      expect(find.byKey(const Key('pdf-start-extraction')), findsOneWidget);
      expect(find.byKey(const Key('app-error-dialog')), findsNothing);
      expect(find.text('PDF 처리 서버에 연결할 수 없어요.'), findsNothing);
      expect(find.text('오류가 발생했어요'), findsNothing);
      expect(api.actions, isEmpty);
      expect(api.results, 0);
      expect(
        DocumentJobRepository.job((await jobs.get('waiting'))!).completedPages,
        80,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('폴더에서 진행 중인 자료를 열고 취소·재시도·완료 검토로 연결한다', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '자료 폴더');
    final jobs = DocumentJobRepository(database);
    const id = 'pending-job';
    final api = FakePdfExtractionApi()..jobs[id] = pdfJob(id);
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
    // The user may leave the PDF screen before an error occurs.
    api.jobs[id] = pdfJob(
      id,
      status: 'failed',
      error: 'OpenAI API 요청이 실패했습니다: 400',
    );
    await container.read(documentJobCoordinatorProvider)!.poll();
    await settle();
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    expect(find.text('OpenAI API 요청이 실패했습니다: 400'), findsOneWidget);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await settle();
    await container.read(documentJobCoordinatorProvider)!.poll();
    await settle();
    expect(find.byKey(const Key('app-error-dialog')), findsNothing);
    router.go(AppRoutes.documentsForJob(folderId, id));
    await settle();
    // Acknowledging the alert does not remove the persistent job error.
    expect(find.text('OpenAI API 요청이 실패했습니다: 400'), findsOneWidget);
    expect(find.text('오류가 발생했어요'), findsOneWidget);
    expect(find.byKey(const Key('pdf-preflight')), findsOneWidget);
    await container.read(documentJobCoordinatorProvider)!.change(id, 'retry');
    api.jobs[id] = pdfJob(id);
    await container.read(documentJobCoordinatorProvider)!.poll();
    await settle();
    router.go(AppRoutes.folder(folderId));
    await settle();
    expect(find.byKey(const Key('pdf-job-pending-job')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pdf-job-pending-job')));
    await settle();
    expect(find.text('개념 추출 1 / 4 묶음'), findsOneWidget);
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
    expect(find.text('PDF 추출 설정'), findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('pdf-preflight'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf-preflight')));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('pdf-risk-acknowledgement'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf-risk-acknowledgement')));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('pdf-start-extraction'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf-start-extraction')));
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

class _Config implements LocalServerConfigStore {
  @override
  Future<LocalServerConfig> read() async => const LocalServerConfig.defaults();
  @override
  Future<void> write(LocalServerConfig config) async {}
}

class _Secrets implements LocalServerSecretStore {
  @override
  Future<String?> read(LocalLlmProvider provider) async => null;
  @override
  Future<void> write(LocalLlmProvider provider, String value) async {}
}

class _Process implements ManagedServerProcess {
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  final _exit = Completer<int>();
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _errors.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill() {
    if (!_exit.isCompleted) _exit.complete(0);
    unawaited(_output.close());
    unawaited(_errors.close());
    return true;
  }
}
