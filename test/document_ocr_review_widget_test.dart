import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/pdf_review_preference.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/document_ocr_review.dart';
import 'package:review_platform/features/documents/document_import_view_model.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_pdf_jobs.dart';
import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late FakePdfJobsApi api;
  late String folder;
  const id = 'review-job';
  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    folder = await DriftFolderRepository(database).createFolder(name: '자료 폴더');
    api = FakePdfJobsApi()..jobs[id] = pdfJob(id, status: 'awaiting_review');
    await DocumentJobRepository(database).add(
      folderId: folder,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
  });
  tearDown(() => database.close());
  Future<ProviderContainer> open(
    WidgetTester tester, {
    bool archive = false,
  }) async {
    await tester.binding.setSurfaceSize(
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1200, 900)
          : const Size(390, 850),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    container
        .read(routerProvider)
        .go(
          archive
              ? AppRoutes.documentsForSource(folder, id)
              : AppRoutes.documentsForJob(folder, id),
        );
    await tester.pumpAndSettle();
    if (!archive) {
      expect(find.text('OCR 검토 대기'), findsOneWidget);
      expect(find.byKey(const Key('pdf-import-progress')), findsNothing);
    }
    await tester.tap(
      find.byKey(Key(archive ? 'open-ocr-archive' : 'open-ocr-review')),
    );
    await tester.pumpAndSettle();
    if (defaultTargetPlatform != TargetPlatform.windows) {
      await tester.tap(find.text(archive ? '추출 텍스트' : '추출 내용 편집'));
      await tester.pumpAndSettle();
    }
    return container;
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tallPreview(WidgetTester tester) async {
    api.previewBytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 300, 1200),
        ui.Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(300, 1200);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return bytes!.buffer.asUint8List();
    });
  }

  testWidgets('PC 원본·추출본을 함께 스크롤하고 페이지 표시와 버튼은 고정한다', (tester) async {
    await tallPreview(tester);
    api.reviewBlocks[1] = List.generate(
      5,
      (index) => OcrReviewBlock(
        text: List.generate(20, (line) => '영역 $index의 학습 내용 $line').join('\n'),
      ),
    );
    await open(tester);
    final comparison = find.byKey(const Key('ocr-desktop-comparison-scroll'));
    final scroll = tester.widget<SingleChildScrollView>(comparison).controller!;
    final image = find.byKey(const Key('ocr-page-image'));
    final editor = find.byKey(const Key('ocr-block-text-0'));
    final toolbar = find.byKey(const Key('ocr-page-number'));
    final imageTop = tester.getTopLeft(image).dy;
    final editorTop = tester.getTopLeft(editor).dy;
    final toolbarTop = tester.getTopLeft(toolbar).dy;
    final imageSize = tester.getSize(image);
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getTopLeft(image) + const Offset(100, 100),
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, 240),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(
      imageTop - tester.getTopLeft(image).dy,
      closeTo(scroll.offset, 0.01),
    );
    expect(
      editorTop - tester.getTopLeft(editor).dy,
      closeTo(scroll.offset, 0.01),
    );
    expect(tester.getTopLeft(toolbar).dy, toolbarTop);
    expect(tester.getSize(image), imageSize);
    final before = scroll.offset;
    final pane = tester.getRect(comparison);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: Offset(pane.left + pane.width * 0.75, pane.top + 100),
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, 180),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(before));
    expect(find.text('p.1 / 2'), findsOneWidget);
    expect(find.byKey(const Key('ocr-save-page')), findsOneWidget);
    expect(find.byKey(const Key('ocr-confirm-review')), findsOneWidget);
    await tap(tester, find.byKey(const Key('ocr-next-page')));
    expect(find.text('p.2 / 2'), findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(comparison).controller!.offset,
      0,
    );
    await tap(tester, find.byKey(const Key('ocr-previous-page')));
    expect(find.text('p.1 / 2'), findsOneWidget);
    expect(api.reviewSaves, 0);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('PC 완료된 OCR 기록의 원본·추출 텍스트도 공통 스크롤을 사용한다', (tester) async {
    await tallPreview(tester);
    api.originalReviewText = List.generate(
      80,
      (index) => 'OCR 원문의 긴 학습 내용 $index',
    ).join('\n');
    api.jobs[id] = pdfJob(id, status: 'completed');
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await open(tester, archive: true);
    final comparison = find.byKey(const Key('ocr-desktop-comparison-scroll'));
    final image = find.byKey(const Key('ocr-page-image'));
    final text = find.byKey(const Key('ocr-archive-original-text'));
    final scroll = tester
        .widget<CustomScrollView>(
          find.descendant(
            of: comparison,
            matching: find.byType(CustomScrollView),
          ),
        )
        .controller!;
    final imageTop = tester.getTopLeft(image).dy;
    final textTop = tester.getTopLeft(text).dy;
    final rect = tester.getRect(comparison);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: Offset(rect.left + rect.width * 0.75, rect.top + 200),
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, 200),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(
      imageTop - tester.getTopLeft(image).dy,
      closeTo(scroll.offset, 0.01),
    );
    expect(textTop - tester.getTopLeft(text).dy, closeTo(scroll.offset, 0.01));
    expect(find.text('p.1 / 2'), findsOneWidget);
    expect(find.byKey(const Key('ocr-save-page')), findsNothing);
    expect(api.reviewSaves, 0);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('모바일 OCR 검토는 기존 탭과 개별 스크롤을 유지한다', (tester) async {
    await open(tester);
    expect(
      find.byKey(const Key('ocr-desktop-comparison-scroll')),
      findsNothing,
    );
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(TabBarView), findsOneWidget);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('ocr-block-list')))
          .shrinkWrap,
      isFalse,
    );
    await tap(tester, find.text('원본 페이지'));
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .scaleFactor
          .isFinite,
      isTrue,
    );
    expect(find.text('p.1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Windows OCR 대조는 휠로 페이지 경계를 연속해서 넘고 되돌아간다', (tester) async {
    await tallPreview(tester);
    api.jobs[id] = pdfJob(id, status: 'completed');
    api.reviewTotalPages = 4;
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await open(tester, archive: true);
    final comparison = find.byKey(const Key('ocr-desktop-comparison-scroll'));
    final pane = tester.getRect(comparison);
    final toolbar = find.byKey(const Key('ocr-page-number'));
    final toolbarTop = tester.getTopLeft(toolbar).dy;
    final firstHeight = tester
        .getSize(find.byKey(const Key('ocr-comparison-page-1')))
        .height;
    Future<void> wheel(double delta, {bool left = true}) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: Offset(
            pane.left + pane.width * (left ? 0.25 : 0.75),
            pane.top + 100,
          ),
          kind: PointerDeviceKind.mouse,
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pumpAndSettle();
    }

    await wheel(firstHeight - pane.height / 2);
    final first = tester.getRect(
      find.byKey(const Key('ocr-comparison-page-1')),
    );
    final second = tester.getRect(
      find.byKey(const Key('ocr-comparison-page-2')),
    );
    // Both page pairs are on screen at the boundary, without replacing a pane.
    expect(first.bottom, greaterThan(pane.top));
    expect(second.top, lessThan(pane.bottom));
    expect(second.top, closeTo(first.bottom, 0.01));
    await wheel(pane.height / 2 + 100, left: false);
    expect(find.text('p.2 / 4'), findsOneWidget);
    expect(tester.getTopLeft(toolbar).dy, toolbarTop);
    await wheel(-firstHeight - 200);
    expect(find.text('p.1 / 4'), findsOneWidget);
    expect(api.previewReads.where((number) => number == 1), hasLength(1));
    expect(api.reviewSaves, 0);
    expect(api.actions, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows OCR 긴 자료는 필요한 페이지만 로딩하고 직접 이동 후 역방향 스크롤한다', (
    tester,
  ) async {
    await tallPreview(tester);
    api.jobs[id] = pdfJob(id, status: 'completed');
    api.reviewTotalPages = 1000;
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await open(tester, archive: true);
    expect(api.reviewPageReads.toSet().length, lessThanOrEqualTo(3));
    await tap(tester, find.text('페이지 이동'));
    await tester.enterText(find.byKey(const Key('ocr-jump-page-field')), '900');
    await tap(tester, find.text('이동'));
    expect(find.text('p.900 / 1000'), findsOneWidget);
    expect(api.previewReads.toSet().length, lessThanOrEqualTo(6));
    final pane = tester.getRect(
      find.byKey(const Key('ocr-desktop-comparison-scroll')),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: pane.topLeft + const Offset(120, 100),
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, -200),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('p.899 / 1000'), findsOneWidget);
    await tap(tester, find.byKey(const Key('ocr-next-page')));
    expect(find.text('p.900 / 1000'), findsOneWidget);
    expect(api.reviewSaves, 0);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows OCR 다음 페이지 오류는 현재 원문을 유지하고 해당 페이지에서 재시도한다', (
    tester,
  ) async {
    await tallPreview(tester);
    api.jobs[id] = pdfJob(id, status: 'completed');
    api.reviewPageErrors[2] = const NetworkFailure('다음 페이지 로딩 실패');
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await open(tester, archive: true);
    expect(find.byKey(const Key('ocr-archive-original-text')), findsOneWidget);
    await tap(tester, find.byKey(const Key('ocr-next-page')));
    expect(find.text('p.2 / 2'), findsOneWidget);
    expect(find.text('다음 페이지 로딩 실패'), findsOneWidget);
    api.reviewPageErrors.clear();
    await tap(
      tester,
      find.descendant(
        of: find.byKey(const Key('ocr-comparison-page-2')),
        matching: find.text('다시 시도'),
      ),
    );
    expect(find.text('다음 페이지 로딩 실패'), findsNothing);
    expect(find.byKey(const Key('ocr-archive-original-text')), findsOneWidget);
    await tap(tester, find.byKey(const Key('ocr-previous-page')));
    expect(find.text('p.1 / 2'), findsOneWidget);
    expect(api.reviewSaves, 0);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows OCR 대조는 현재 페이지 새로고침과 전체 텍스트 모드 전환을 유지한다', (
    tester,
  ) async {
    await tallPreview(tester);
    api.jobs[id] = pdfJob(id, status: 'completed');
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await open(tester, archive: true);
    await tap(tester, find.byKey(const Key('ocr-next-page')));
    expect(find.text('p.2 / 2'), findsOneWidget);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final offset = scroll.offset;
    api.originalReviewText = '갱신한 OCR 원문';
    await tap(tester, find.text('새로고침'));
    expect(find.text('p.2 / 2'), findsOneWidget);
    expect(scroll.offset, closeTo(offset, 0.01));
    expect(
      tester
          .widget<StudyText>(find.byKey(const Key('ocr-archive-original-text')))
          .data,
      '갱신한 OCR 원문',
    );
    await tap(tester, find.text('최종 추출 입력'));
    expect(find.byKey(const Key('ocr-archive-final-text-0')), findsOneWidget);
    expect(find.byKey(const Key('ocr-archive-original-text')), findsNothing);
    // Offscreen pages may be disposed by the lazy viewport; verify the mode
    // remains selected when navigating to another page instead.
    await tap(tester, find.byKey(const Key('ocr-previous-page')));
    expect(find.text('p.1 / 2'), findsOneWidget);
    expect(find.byKey(const Key('ocr-archive-final-text-0')), findsOneWidget);
    expect(find.byKey(const Key('ocr-archive-original-text')), findsNothing);
    await tap(tester, find.byKey(const Key('ocr-next-page')));
    await tap(tester, find.text('OCR 원문'));
    expect(
      tester
          .widget<StudyText>(find.byKey(const Key('ocr-archive-original-text')))
          .data,
      '갱신한 OCR 원문',
    );
    expect(api.reviewSaves, 0);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    '완료한 자료에서 원본 이미지·OCR 원문·최종 입력을 읽기 전용으로 대조한다',
    (tester) async {
      api.jobs[id] = pdfJob(id, status: 'completed');
      api.reviewBlocks[1] = const [
        OcrReviewBlock(text: '확정한 수정본입니다.', independent: true),
        OcrReviewBlock(text: 'AI 입력에서 제외한 내용입니다.', excluded: true),
      ];
      final repository = DriftSourceRepository(database);
      final saved = await repository.saveImport(
        folderId: folder,
        result: pdfResult(id),
      );
      await repository.setConceptApproval(
        id: saved.concepts.single.id,
        approved: true,
      );
      await DocumentJobRepository(database).applyResult(id, (_) async {});
      await open(tester, archive: true);
      if (defaultTargetPlatform != TargetPlatform.windows) {
        await tap(tester, find.text('원본 페이지'));
      }
      expect(find.byKey(const Key('ocr-page-image')), findsOneWidget);
      if (defaultTargetPlatform != TargetPlatform.windows) {
        await tap(tester, find.text('추출 텍스트'));
      }
      expect(
        find.byKey(const Key('ocr-archive-original-text')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<StudyText>(
              find.byKey(const Key('ocr-archive-original-text')),
            )
            .data,
        '원래 추출 텍스트',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('ocr-archive-original-kinds')))
            .data,
        contains('영역 2: 도식'),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('ocr-block-kind-0')), findsNothing);
      expect(find.byKey(const Key('ocr-save-page')), findsNothing);
      expect(find.byKey(const Key('ocr-confirm-review')), findsNothing);
      expect(find.byKey(const Key('ocr-block-independent-0')), findsNothing);
      await tap(tester, find.text('최종 추출 입력'));
      expect(find.text('확정한 수정본입니다.'), findsOneWidget);
      expect(find.textContaining('추출에서 제외됨'), findsOneWidget);
      expect(find.text('AI 입력에서 제외한 내용입니다.'), findsOneWidget);
      await tap(tester, find.byKey(const Key('ocr-next-page')));
      await tap(tester, find.byKey(const Key('ocr-previous-page')));
      expect(api.previewReads, [1, 2]);
      await tap(tester, find.byKey(const Key('ocr-close-review')));
      expect(find.byKey(const Key('open-ocr-archive')), findsOneWidget);
      expect(api.actions, isEmpty);
      expect(api.reviewSaves, 0);
      final after = await repository.getSourceWithConcepts(id);
      expect(after.concepts.single.content, saved.concepts.single.content);
      expect(after.concepts.single.status.name, 'approved');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('자동 처리 후 동기화로 받은 자료도 로컬 작업 행 없이 OCR을 열람한다', (tester) async {
    api.jobs[id] = pdfJob(id, status: 'completed');
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await (database.delete(
      database.documentJobs,
    )..where((row) => row.id.equals(id))).go();
    await open(tester, archive: true);
    expect(
      tester
          .widget<StudyText>(find.byKey(const Key('ocr-archive-original-text')))
          .data,
      '원래 추출 텍스트',
    );
    await tap(tester, find.text('최종 추출 입력'));
    expect(
      find.descendant(
        of: find.byKey(const Key('ocr-comparison-page-1')),
        matching: find.text('이 페이지는 사용자 수정 없이 추출 내용으로 개념을 생성했습니다.'),
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(api.reviewSaves, 0);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('원본 이미지 로딩 실패를 알리고 OCR 텍스트는 계속 대조할 수 있다', (tester) async {
    api.jobs[id] = pdfJob(id, status: 'completed');
    api.previewError = const NetworkFailure('서버에 원본 PDF 파일이 없습니다.');
    await DriftSourceRepository(database)
        .saveImport(folderId: folder, result: pdfResult(id));
    await open(tester, archive: true);
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    await tap(tester, find.byKey(const Key('acknowledge-app-error')));
    expect(
      tester
          .widget<StudyText>(find.byKey(const Key('ocr-archive-original-text')))
          .data,
      '원래 추출 텍스트',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('ocr-comparison-page-1')),
        matching: find.text('서버에 원본 PDF 파일이 없습니다.'),
      ),
      findsOneWidget,
    );
    await tap(tester, find.text('최종 추출 입력'));
    expect(find.byKey(const Key('ocr-archive-final-text-0')), findsOneWidget);
    expect(api.actions, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('가져오기 화면의 중간 검토 옵션은 기본 꺼짐이며 업로드까지 전달한다', (tester) async {
    final container = await open(tester);
    await tap(tester, find.byKey(const Key('ocr-close-review')));
    container.read(routerProvider).go(AppRoutes.documentsForFolder(folder));
    await tester.pumpAndSettle();
    final option = find.byKey(const Key('review-ocr-before-concepts'));
    expect(tester.widget<SwitchListTile>(option).value, isFalse);
    await tap(tester, option);
    expect(container.read(pdfReviewPreferenceProvider), isTrue);
    expect(
      await container
          .read(documentImportControllerProvider(folder).notifier)
          .importPdf(
            PickedPdfDocument.stream(
              fileName: '검토할 자료.pdf',
              length: 5,
              openRead: () => Stream.value([37, 80, 68, 70, 45]),
            ),
          ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(api.reviewBeforeConcepts, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    '페이지 편집·독립 영역·제외를 저장하고 OCR 반복 없이 개념 추출을 재개한다',
    (tester) async {
      await open(tester);
      expect(find.byKey(const Key('ocr-review-view')), findsOneWidget);
      expect(api.previewReads, [1]);
      final firstText = find.byKey(const Key('ocr-block-text-0'));
      await tester.enterText(firstText, '연표의 수정된 학습 내용입니다. 필요한 경우 원문을 참고합니다.');
      await tap(tester, find.byKey(const Key('ocr-block-independent-0')));
      await tap(tester, find.byKey(const Key('ocr-block-excluded-1')));
      await tap(tester, find.byKey(const Key('ocr-next-page')));
      expect(api.reviewSaves, 1);
      expect(api.reviewBlocks[1]!.first.independent, isTrue);
      expect(api.reviewBlocks[1]![1].excluded, isTrue);
      expect(api.reviewBlocks[1]!.first.text, contains('수정된'));
      expect(find.text('p.2 / 2'), findsOneWidget);
      await tap(tester, find.byKey(const Key('ocr-previous-page')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('ocr-block-text-0')))
            .controller!
            .text,
        contains('수정된'),
      );
      await tap(tester, find.byKey(const Key('ocr-confirm-review')));
      expect(find.text('개념 추출 시작'), findsNWidgets(2));
      await tap(tester, find.widgetWithText(FilledButton, '개념 추출 시작'));
      expect(api.actions, contains('confirm-review'));
      expect(find.byKey(const Key('ocr-review-view')), findsNothing);
      expect(find.text('분석 대기 중'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('선택 영역 분리·합치기 및 저장 실패는 편집 내용을 보존한다', (tester) async {
    await open(tester);
    final firstText = find.byKey(const Key('ocr-block-text-0'));
    await tester.enterText(firstText, '앞의 연표 설명\n독립된 원칙 설명\n뒤의 연표 설명');
    final controller = tester.widget<TextField>(firstText).controller!;
    controller.selection = const TextSelection(baseOffset: 9, extentOffset: 19);
    await tap(tester, find.byKey(const Key('ocr-split-block-0')));
    await tap(tester, find.byKey(const Key('ocr-save-page')));
    expect(api.reviewBlocks[1], hasLength(4));
    expect(api.reviewBlocks[1]![1].independent, isTrue);
    expect(
      api.reviewBlocks[1]!.take(3).map((block) => block.kind),
      everyElement(OcrContentKind.text),
    );
    await tap(tester, find.byKey(const Key('ocr-merge-block-0')));
    expect(find.byKey(const Key('ocr-block-text-3')), findsNothing);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('ocr-block-independent-0')),
          )
          .value,
      isTrue,
    );
    api.reviewOffline = true;
    await tap(tester, find.byKey(const Key('ocr-save-page')));
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    await tap(tester, find.byKey(const Key('acknowledge-app-error')));
    expect(find.text('저장하지 않은 수정'), findsOneWidget);
    expect(
      tester.widget<TextField>(firstText).controller!.text,
      contains('독립된 원칙'),
    );
    expect(api.actions, isEmpty);
    api.reviewOffline = false;
    await tap(tester, find.byKey(const Key('ocr-save-page')));
    expect(api.reviewBlocks[1]!.first.independent, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    '영역 종류를 독립 여부와 별개로 수정하고 재진입·원문 복원한다',
    (tester) async {
      await open(tester);
      final kind = find.byKey(const Key('ocr-block-kind-0'));
      await tap(tester, kind);
      await tap(tester, find.text('표').last);
      await tap(tester, find.byKey(const Key('ocr-save-page')));
      expect(api.reviewBlocks[1]!.first.kind, OcrContentKind.table);
      expect(api.reviewBlocks[1]!.first.independent, isFalse);
      expect(api.reviewBlocks[1]![1].kind, OcrContentKind.diagram);
      await tap(tester, find.byKey(const Key('ocr-close-review')));
      await tap(tester, find.byKey(const Key('open-ocr-review')));
      if (defaultTargetPlatform != TargetPlatform.windows) {
        await tap(tester, find.text('추출 내용 편집'));
      }
      expect(
        tester
            .widget<DropdownButtonFormField<OcrContentKind>>(kind)
            .initialValue,
        OcrContentKind.table,
      );
      await tap(tester, find.byKey(const Key('ocr-merge-block-0')));
      await tap(tester, find.byKey(const Key('ocr-save-page')));
      expect(api.reviewBlocks[1]!.single.kind, OcrContentKind.uncertain);
      expect(api.reviewBlocks[1]!.single.visualRegion, isTrue);
      expect(api.reviewBlocks[1]!.single.independent, isFalse);
      await tap(tester, find.text('이 페이지 원문 복원'));
      await tap(tester, find.widgetWithText(FilledButton, '확인'));
      await tap(tester, find.byKey(const Key('ocr-save-page')));
      expect(api.reviewBlocks[1]!.map((block) => block.kind), [
        OcrContentKind.text,
        OcrContentKind.diagram,
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  test('영역 종류 JSON 왕복과 이전 기록의 미분류를 처리한다', () {
    for (final kind in OcrContentKind.values) {
      final block = OcrReviewBlock(text: '내용', kind: kind, visualRegion: true);
      final restored = OcrReviewBlock.fromJson(block.toJson());
      expect(restored.kind, kind);
      expect(restored.visualRegion, isTrue);
      expect(restored.independent, isFalse);
    }
    expect(
      OcrReviewBlock.fromJson({
        'text': '이전 기록',
        'independent': false,
        'excluded': false,
        'visualRegion': false,
      }).kind,
      OcrContentKind.uncertain,
    );
    expect(
      OcrReviewBlock.fromJson({
        'text': '새 종류',
        'kind': 'unknown',
        'independent': false,
        'excluded': false,
        'visualRegion': false,
      }).kind,
      OcrContentKind.uncertain,
    );
  });

  testWidgets('원문 복원과 페이지 직접 이동은 저장된 원본을 유지하고 범위를 검증한다', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const Key('ocr-block-text-0')),
      '수정 중인 내용입니다.',
    );
    await tap(tester, find.text('이 페이지 원문 복원'));
    await tap(tester, find.widgetWithText(FilledButton, '확인'));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ocr-block-text-0')))
          .controller!
          .text,
      api.originalReviewBlocks.first.text,
    );
    await tap(tester, find.text('페이지 이동'));
    await tester.enterText(find.byKey(const Key('ocr-jump-page-field')), '3');
    await tap(tester, find.widgetWithText(FilledButton, '이동'));
    expect(find.text('1 ~ 2 사이의 페이지를 입력해 주세요.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ocr-jump-page-field')), '2');
    await tap(tester, find.widgetWithText(FilledButton, '이동'));
    expect(find.text('p.2 / 2'), findsOneWidget);
    expect(api.reviewSaves, 1);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('수정 중 뒤로가기는 확인하고 저장한 초안은 재진입해도 유지한다', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const Key('ocr-block-text-0')),
      '다시 열어도 유지해야 하는 검토 초안입니다.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ocr-close-review')));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않은 수정이 있어요'), findsOneWidget);
    await tap(tester, find.text('저장 후 나가기'));
    expect(find.byKey(const Key('ocr-review-view')), findsNothing);
    expect(api.actions, isEmpty);
    await tap(tester, find.byKey(const Key('open-ocr-review')));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ocr-block-text-0')))
          .controller!
          .text,
      contains('검토 초안'),
    );
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}
