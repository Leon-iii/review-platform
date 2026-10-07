import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_pdf_extraction.dart';
import 'support/fake_pdf_jobs.dart';

import 'package:review_platform/domain/models/pdf_import_job.dart';

import 'support/fake_ai.dart';
import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late String folderId;
  late _ImportApi api;
  late _Picker picker;
  late MemorySyncCredentialsStore credentials;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    folderId = await DriftFolderRepository(database)
        .createFolder(name: '자료 폴더');
    api = _ImportApi();
    picker = _Picker();
    credentials = MemorySyncCredentialsStore(
      configuration: const SyncConfiguration(
        serverUrl: 'http://127.0.0.1:5080',
        accessToken: 'test-token',
      ),
    );
  });
  tearDown(() => database.close());

  Future<GoRouter> open(WidgetTester tester, String path) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
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
          syncCredentialsStoreProvider.overrideWithValue(credentials),
          remoteSyncApiProvider.overrideWithValue(FakeRemoteSyncApi()),
          remoteAiApiProvider.overrideWithValue(FakeRemoteAiApi()),
          remoteDocumentApiProvider.overrideWithValue(api),
          documentPickerProvider.overrideWithValue(picker),
        ],
        child: const ReviewApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    final router = container.read(routerProvider);
    router.go(path);
    await tester.pumpAndSettle();
    return router;
  }

  Finder target(String key) => find.descendant(
    of: find.byKey(Key(key), skipOffstage: false),
    matching: find.byType(DropTarget, skipOffstage: false),
    skipOffstage: false,
  );
  DropDoneDetails details(
    WidgetTester tester,
    Finder finder, {
    String name = '강의.PDF',
  }) => DropDoneDetails(
    files: [DropItemFile.fromData(_pdfBytes, path: name)],
    localPosition: Offset.zero,
    globalPosition: tester.getCenter(finder),
  );

  for (final inFolder in [false, true]) {
    testWidgets(
      'Windows PDF ${inFolder ? '폴더 자료 영역' : '업로드 화면'} 드롭은 같은 분석·저장을 사용한다',
      (tester) async {
        await open(
          tester,
          inFolder
              ? AppRoutes.folder(folderId)
              : AppRoutes.documentsForFolder(folderId),
        );
        final finder = target(
          inFolder ? 'folder-pdf-drop-zone' : 'pdf-import-drop-zone',
        );
        final widget = tester.widget<DropTarget>(finder);
        expect(widget.enable, isTrue);
        widget.onDragEntered!(
          DropEventDetails(
            localPosition: Offset.zero,
            globalPosition: tester.getCenter(finder),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('pdf-drop-highlight')), findsOneWidget);
        final pending = Completer<PdfImportJob>();
        api.pending = pending;
        final drop = details(tester, finder);
        widget.onDragDone!(drop);
        widget.onDragDone!(drop); // Ignore a duplicate while reading/uploading.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(api.calls, 1);
        expect(picker.calls, 0);
        expect(api.fileName, '강의.PDF');
        expect(api.bytes, _pdfBytes);
        expect(find.byKey(const Key('pdf-import-progress')), findsOneWidget);
        final uploadTarget = tester.widget<DropTarget>(
          target('pdf-import-drop-zone'),
        );
        expect(uploadTarget.enable, isFalse);
        if (inFolder) {
          expect(tester.widget<DropTarget>(finder).enable, isFalse);
        }
        uploadTarget.onDragDone!(
          details(tester, target('pdf-import-drop-zone')),
        );
        await tester.pump();
        expect(api.calls, 1);
        pending.complete(
          pdfJob('dropped-source', status: 'awaiting_selection'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets('잘못된 드롭과 다중 파일은 서버에 보내지 않고 재시도할 수 있다', (tester) async {
    await open(tester, AppRoutes.documentsForFolder(folderId));
    final finder = target('pdf-import-drop-zone');
    tester.widget<DropTarget>(finder).onDragDone!(
      details(tester, finder, name: 'notes.txt'),
    );
    await tester.pumpAndSettle();
    expect(api.calls, 0);
    expect(find.text('폴더가 아닌 PDF 파일을 놓아 주세요.'), findsOneWidget);
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    final drop = details(tester, finder);
    tester.widget<DropTarget>(finder).onDragDone!(
      DropDoneDetails(
        files: [...drop.files, ...drop.files],
        localPosition: drop.localPosition,
        globalPosition: drop.globalPosition,
      ),
    );
    await tester.pumpAndSettle();
    expect(api.calls, 0);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    expect(tester.widget<DropTarget>(finder).enable, isTrue);
    expect(await DriftSourceRepository(database).getSources(folderId), isEmpty);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('가려진 폴더·대화상자에서는 PDF 드롭을 받지 않는다', (tester) async {
    final router = await open(tester, AppRoutes.folder(folderId));
    final finder = target('folder-pdf-drop-zone');
    final drop = details(tester, finder);
    await tester.tap(find.byKey(const Key('create-source-button')));
    await tester.pumpAndSettle();
    tester.widget<DropTarget>(finder).onDragDone!(drop);
    await tester.pumpAndSettle();
    expect(api.calls, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    unawaited(router.push(AppRoutes.aiGenerateForFolder(folderId)));
    await tester.pumpAndSettle();
    expect(tester.widget<DropTarget>(finder).enable, isFalse);
    tester.widget<DropTarget>(finder).onDragDone!(drop);
    await tester.pumpAndSettle();
    expect(api.calls, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Android에는 네이티브 드롭 대신 기존 PDF 선택 버튼을 유지한다', (tester) async {
    await open(tester, AppRoutes.documentsForFolder(folderId));
    expect(find.byType(DropTarget), findsNothing);
    await tester.tap(find.byKey(const Key('pick-pdf-button')));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(api.calls, 1);
    expect(find.text('PDF 추출 설정'), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

final _pdfBytes = Uint8List.fromList([37, 80, 68, 70, 45, 49]);

class _Picker implements DocumentPicker {
  int calls = 0;
  @override
  Future<PickedPdfDocument?> pickPdf() async {
    calls++;
    return PickedPdfDocument(fileName: '선택.pdf', bytes: _pdfBytes);
  }
}

class _ImportApi extends FakePdfExtractionApi {
  int calls = 0;
  String? fileName;
  Uint8List? bytes;
  Completer<PdfImportJob>? pending;
  @override
  Future<PdfImportJob> uploadJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  ) async {
    calls++;
    fileName = document.fileName;
    final buffer = <int>[];
    await for (final chunk in document.openRead()) {
      buffer.addAll(chunk);
    }
    bytes = Uint8List.fromList(buffer);
    return jobs[id] = pending == null
        ? pdfJob(id, status: 'awaiting_selection')
        : await pending!.future.then(
            (job) => PdfImportJob({...job.data, 'id': id}),
          );
  }
}
