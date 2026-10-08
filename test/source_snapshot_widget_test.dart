import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/shared/widgets/concept_source_badge.dart';

import 'support/fake_source_snapshots.dart';
import 'support/fake_sync.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeSourceSnapshotsApi api, {
    double width = 1000,
    double scale = 1,
    bool dark = false,
  }) async {
    final database = AppDatabase(NativeDatabase.memory());
    final folder = await DriftFolderRepository(database)
        .createFolder(name: '자료');
    await DriftSourceRepository(database).saveImport(
      folderId: folder,
      result: DocumentImportResult(
        source: ImportedSource(
          id: 'source',
          fileName: '원본 대조를 위한 아주 긴 강의자료 이름.pdf',
          contentHash: 'hash',
          pageCount: 60,
          extractionMethod: 'directPdf',
          importedAt: DateTime.utc(2026),
        ),
        concepts: const [
          ImportedConcept(
            title: '개념',
            content: '내용',
            pageNumbers: [47, 50, 51],
          ),
        ],
      ),
    );
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await database.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          remoteDocumentApiProvider.overrideWithValue(api),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(
              configuration: const SyncConfiguration(
                serverUrl: 'http://server:5080',
                accessToken: 'token',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: Center(
              child: ConceptSourceBadge(
                key: Key('badge'),
                sourceId: 'source',
                pages: [51, 47, 50, 47],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('실제 출처 목록만 이동하며 재방문과 팝업 재열기에서 캐시를 사용한다', (tester) async {
    final api = FakeSourceSnapshotsApi();
    await mount(tester, api);
    expect(api.calls, isEmpty);
    await tester.tap(find.byKey(const Key('badge')));
    await tester.pumpAndSettle();
    expect(find.text('p.47 · 출처 1/3'), findsOneWidget);
    expect(api.calls, [('source', 47)]);
    await tester.tap(find.byKey(const Key('source-snapshot-next')));
    await tester.pumpAndSettle();
    expect(find.text('p.50 · 출처 2/3'), findsOneWidget);
    final position = tester.getCenter(
      find.byKey(const Key('source-snapshot-wheel')),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('p.51 · 출처 3/3'), findsOneWidget);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 20)),
    );
    await tester.pumpAndSettle();
    expect(api.calls.length, 3);
    await tester.tap(find.byKey(const Key('source-snapshot-previous')));
    await tester.pumpAndSettle();
    expect(api.calls.length, 3);
    await tester.tap(find.byTooltip('확대'));
    await tester.pumpAndSettle();
    final transform = find.descendant(
      of: find.byKey(const Key('source-snapshot-wheel')),
      matching: find.byType(Transform),
    );
    expect(
      tester.widget<Transform>(transform).transform.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await tester.tap(find.byTooltip('원래 크기로'));
    await tester.pumpAndSettle();
    final pinchCenter = tester.getCenter(
      find.byKey(const Key('source-snapshot-wheel')),
    );
    final left = await tester.startGesture(
      pinchCenter - const Offset(40, 0),
      pointer: 7,
    );
    final right = await tester.startGesture(
      pinchCenter + const Offset(40, 0),
      pointer: 8,
    );
    await left.moveTo(pinchCenter - const Offset(80, 0));
    await right.moveTo(pinchCenter + const Offset(80, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Transform>(transform).transform.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await tester.tap(find.byKey(const Key('source-snapshot-next')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Transform>(transform).transform.getMaxScaleOnAxis(),
      1,
    );
    await tester.tap(find.byKey(const Key('source-snapshot-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('badge')));
    await tester.pumpAndSettle();
    expect(api.calls.length, 3);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '360dp·글자200%·${dark ? 'dark' : 'light'}에서 원본 보기와 오류 재시도가 가능하다',
      (tester) async {
        final api = FakeSourceSnapshotsApi()
          ..error = const NetworkFailure(
            '원본 PDF를 찾을 수 없어요. 개념은 계속 열람할 수 있습니다.',
          );
        await mount(tester, api, width: 360, scale: 2, dark: dark);
        await tester.tap(find.byKey(const Key('badge')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('source-snapshot-dialog')), findsOneWidget);
        expect(find.text('다시 시도'), findsOneWidget);
        api.error = null;
        await tester.ensureVisible(find.text('다시 시도'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('다시 시도'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('PDF 원본 47페이지'), findsOneWidget);
        expect(api.calls.length, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('로딩 중 닫기를 허용하고 응답 도착 후 닫힌 팝업을 갱신하지 않는다', (tester) async {
    final api = FakeSourceSnapshotsApi()..gate = Completer<void>();
    await mount(tester, api);
    await tester.tap(find.byKey(const Key('badge')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-snapshot-close')));
    await tester.pump(const Duration(milliseconds: 300));
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-snapshot-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
