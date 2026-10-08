import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

  testWidgets('업로드만으로 호출하지 않고 분할 지점 추가 후 자동 점검, 경고 확인 후 중복 없이 시작', (
    tester,
  ) async {
    final api = FakePdfExtractionApi();
    await mount(tester, api);
    expect(find.text('PDF 추출 설정'), findsOneWidget);
    expect(api.starts, 0);
    expect(api.checks, 0);
    expect(find.text('개요 새로고침'), findsNothing);
    expect(find.text('PDF를 모델에 직접 전달해 개념을 추출합니다.'), findsNothing);
    expect(find.textContaining('파일은 보관되며, 업로드만으로'), findsNothing);
    expect(find.byKey(const Key('pdf-split-boundary')), findsNothing);
    await reveal(tester, find.byKey(const Key('pdf-add-split')));
    await tester.tap(find.byKey(const Key('pdf-add-split')));
    await tester.pumpAndSettle();
    expect(find.text('요청 범위: p.1 / p.2–3'), findsOneWidget);
    expect(api.checks, 1);
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

  testWidgets('분할 목록은 정렬되며 추가·삭제마다 재점검하고 잘못된 입력은 호출하지 않는다', (tester) async {
    final api = FakePdfExtractionApi();
    await mount(tester, api);
    final input = find.byKey(const Key('pdf-split-page-input'));
    final add = find.byKey(const Key('pdf-add-split'));
    await reveal(tester, input);
    await tester.enterText(input, '2');
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(api.checks, 1);
    await reveal(tester, input);
    await tester.enterText(input, '1');
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(api.lastSelection!['splitAfterPages'], [1, 2]);
    expect(api.checks, 2);
    await reveal(tester, input);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('이미 추가한 분할 지점이에요.'), findsOneWidget);
    await tester.enterText(input, '3');
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(api.checks, 2);
    await reveal(tester, find.byKey(const Key('pdf-remove-split-1')));
    await tester.tap(find.byKey(const Key('pdf-remove-split-1')));
    await tester.pumpAndSettle();
    expect(api.checks, 3);
    expect(api.lastSelection!['splitAfterPages'], [2]);
    await reveal(tester, find.byKey(const Key('pdf-remove-split-2')));
    await tester.tap(find.byKey(const Key('pdf-remove-split-2')));
    await tester.pumpAndSettle();
    expect(api.checks, 4);
    expect(api.lastSelection!['splitAfterPages'], isEmpty);
    expect(find.text('요청 범위: p.1–3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('재점검 대기 중 중복 변경을 막고 이전 경고 확인을 초기화한다', (tester) async {
    final api = FakePdfExtractionApi();
    await mount(tester, api);
    await reveal(tester, find.byKey(const Key('pdf-preflight')));
    await tester.tap(find.byKey(const Key('pdf-preflight')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('pdf-risk-acknowledgement')));
    await tester.tap(find.byKey(const Key('pdf-risk-acknowledgement')));
    await tester.pumpAndSettle();
    api.checkGate = Completer<void>();
    await reveal(tester, find.byKey(const Key('pdf-add-split')));
    await tester.tap(find.byKey(const Key('pdf-add-split')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('pdf-add-split')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pdf-start-extraction')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('pdf-add-split')));
    expect(api.checks, 2);
    api.checkGate!.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('pdf-risk-acknowledgement')),
          )
          .value,
      false,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('미리보기 휠·아이콘·입력으로 페이지 이동하고 첫/마지막 경계를 유지한다', (tester) async {
    final api = FakePdfExtractionApi();
    await mount(tester, api);
    final preview = find.byKey(const Key('pdf-preview-wheel'));
    await reveal(tester, preview);
    final position = tester.getCenter(preview);
    Future<void> wheel(double delta) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: position, scrollDelta: Offset(0, delta)),
      );
      await tester.pumpAndSettle();
    }

    await wheel(20);
    expect(api.previewPages.last, 2);
    await wheel(20);
    expect(api.previewPages.last, 3);
    final calls = api.previewPages.length;
    await wheel(20);
    expect(api.previewPages.length, calls);
    await wheel(-20);
    expect(api.previewPages.last, 2);
    expect(find.byType(InteractiveViewer), findsNothing);
    await reveal(tester, find.byKey(const Key('pdf-previous-page')));
    await tester.tap(find.byKey(const Key('pdf-previous-page')));
    await tester.pumpAndSettle();
    expect(api.previewPages.last, 1);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('pdf-previous-page')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('pdf-next-page')));
    await tester.pumpAndSettle();
    expect(api.previewPages.last, 2);
    await tester.enterText(find.byKey(const Key('pdf-page-input')), '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.previewPages.last, 3);
    expect(api.checks, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('자동 점검 실패 시 분할 목록을 보존하고 다시 점검으로 복구한다', (tester) async {
    final api = FakePdfExtractionApi()..checkError = Exception('점검 연결 실패');
    await mount(tester, api);
    await reveal(tester, find.byKey(const Key('pdf-add-split')));
    await tester.tap(find.byKey(const Key('pdf-add-split')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pdf-remove-split-1')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pdf-start-extraction')))
          .onPressed,
      isNull,
    );
    api.checkError = null;
    await reveal(tester, find.byKey(const Key('pdf-preflight')));
    await tester.tap(find.byKey(const Key('pdf-preflight')));
    await tester.pumpAndSettle();
    expect(api.checks, 2);
    expect(api.lastSelection!['splitAfterPages'], [1]);
    expect(find.text('점검 결과 · 주의 필요'), findsOneWidget);
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

  testWidgets('예상량과 안전 기준, 실제 API 한도를 구분하고 표본 부족을 표시한다', (tester) async {
    final api = FakePdfExtractionApi();
    await mount(tester, api);
    await reveal(tester, find.byKey(const Key('pdf-preflight')));
    await tester.tap(find.byKey(const Key('pdf-preflight')));
    await tester.pumpAndSettle();
    expect(find.text('예상 출력: 예측 자료 부족 · 정상 완료 표본 0/5개'), findsOneWidget);
    expect(find.text('분할 권장 기준: 64,000토큰 · 강제 종료하지 않음'), findsOneWidget);
    expect(find.text('API 출력 한도: 128,000토큰 · 추론 포함'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '64k 초과 실측 예상량을 경고로 표시하고 확인 후 진행 · ${dark ? 'dark' : 'light'}',
      (tester) async {
        final api = FakePdfExtractionApi()
          ..outputEstimate = {
            'tokens': 65000,
            'lowerTokens': 40000,
            'upperTokens': 80000,
            'sampleCount': 8,
            'confidence': 'low',
          };
        await mount(tester, api, width: 360, scale: 2, dark: dark);
        await reveal(tester, find.byKey(const Key('pdf-preflight')));
        await tester.tap(find.byKey(const Key('pdf-preflight')));
        await tester.pumpAndSettle();
        expect(find.text('예상 출력: 약 65,000토큰 · 신뢰도 낮음'), findsOneWidget);
        expect(
          find.text('실측 환산 범위: 40,000–80,000토큰 · 표본 8개 · 보장 범위 아님'),
          findsOneWidget,
        );
        await reveal(tester, find.byKey(const Key('pdf-risk-acknowledgement')));
        await tester.tap(find.byKey(const Key('pdf-risk-acknowledgement')));
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(const Key('pdf-start-extraction')));
        await tester.tap(find.byKey(const Key('pdf-start-extraction')));
        await tester.pumpAndSettle();
        expect(api.starts, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('출력 한도 미등록 모델은 경고 확인으로 강제 진행할 수 없다', (tester) async {
    final api = FakePdfExtractionApi()
      ..status = 'unknown'
      ..outputBudget = null;
    await mount(tester, api);
    await reveal(tester, find.byKey(const Key('pdf-preflight')));
    await tester.tap(find.byKey(const Key('pdf-preflight')));
    await tester.pumpAndSettle();
    expect(
      find.text('API 출력 한도: 미등록 · 지원 정보가 등록된 모델을 선택해 주세요.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pdf-risk-acknowledgement')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('pdf-start-extraction')))
          .onPressed,
      isNull,
    );
    expect(api.starts, 0);
    expect(tester.takeException(), isNull);
  });
}
