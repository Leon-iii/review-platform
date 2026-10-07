import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/documents/document_job_coordinator.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/features/documents/document_extraction_panel.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_pdf_extraction.dart';
import 'support/fake_pdf_jobs.dart';
import 'support/fake_sync.dart';

void main() {
  Future<void> reveal(WidgetTester tester, Finder target) async {
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester,
    FakePdfExtractionApi api, {
    double width = 1000,
    double scale = 1,
    bool dark = false,
  }) async {
    final database = AppDatabase(NativeDatabase.memory());
    final folder = await DriftFolderRepository(database)
        .createFolder(name: '자료');
    final jobs = DocumentJobRepository(database);
    api.jobs['id'] = pdfJob('id', status: 'awaiting_selection');
    await jobs.add(
      folderId: folder,
      serverUrl: 'http://server:5080',
      job: api.jobs['id']!,
    );
    final coordinator = DocumentJobCoordinator(
      api,
      jobs,
      DriftSourceRepository(database),
      MemorySyncCredentialsStore(
        configuration: const SyncConfiguration(
          serverUrl: 'http://server:5080',
          accessToken: 'token',
        ),
      ),
      (_) {},
    );
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          documentJobCoordinatorProvider.overrideWithValue(coordinator),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: DocumentExtractionPanel(jobId: 'id')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('개요에서 AI 호출 없이 경로 선택, 원본으로 수동 분할, 경고 확인 후 중복 없이 시작', (
    tester,
  ) async {
    final api = FakePdfExtractionApi();
    await mount(tester, api);
    expect(find.text('PDF 추출 설정'), findsOneWidget);
    expect(api.starts, 0);
    expect(api.checks, 0);
    await reveal(tester, find.byKey(const Key('pdf-split-boundary')));
    await tester.tap(find.byKey(const Key('pdf-split-boundary')));
    await tester.pumpAndSettle();
    expect(find.text('요청 범위: p.1 / p.2–3'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('pdf-preflight')));
    await tester.tap(find.byKey(const Key('pdf-preflight')));
    await tester.pumpAndSettle();
    expect(api.lastSelection!['splitAfterPages'], [1]);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pdf-start-extraction')))
          .onPressed,
      isNull,
    );
    await reveal(tester, find.byKey(const Key('pdf-risk-acknowledgement')));
    await tester.tap(find.byKey(const Key('pdf-risk-acknowledgement')));
    await tester.pumpAndSettle();
    api.startGate = Completer<PdfImportJob>();
    await reveal(tester, find.byKey(const Key('pdf-start-extraction')));
    await tester.tap(find.byKey(const Key('pdf-start-extraction')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pdf-start-extraction')));
    expect(api.starts, 1);
    api.startGate!.complete(pdfJob('id', status: 'queued'));
    await tester.pumpAndSettle();
    expect(api.lastSelection!['acknowledgeWarnings'], true);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '360dp·글자 200%·${dark ? 'dark' : 'light'}에서 긴 제목과 병렬 액션이 잘리지 않고 한도 초과를 차단',
      (tester) async {
        final api = FakePdfExtractionApi()..status = 'blocked';
        await mount(tester, api, width: 360, scale: 2, dark: dark);
        await reveal(tester, find.byKey(const Key('pdf-preflight')));
        await tester.tap(find.byKey(const Key('pdf-preflight')));
        await tester.pumpAndSettle();
        expect(find.text('점검 결과 · 분할 필요'), findsOneWidget);
        expect(find.byKey(const Key('pdf-risk-acknowledgement')), findsNothing);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('pdf-start-extraction')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('PDF 입력을 지원하지 않는 모델은 설정 변경을 안내하고 시작을 차단한다', (tester) async {
    final api = FakePdfExtractionApi()..provider = 'ollama';
    await mount(tester, api);
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    await reveal(tester, find.byKey(const Key('pdf-start-extraction')));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pdf-start-extraction')))
          .onPressed,
      isNull,
    );
    expect(api.starts, 0);
    expect(api.checks, 0);
    expect(tester.takeException(), isNull);
  });
}
