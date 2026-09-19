import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';

void main() {
  testWidgets('좁은 화면에서는 바텀시트에서 최상위 폴더를 선택한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.utc(2026, 9, 18);
    final folders = [
      Folder(id: 'root', name: '물리학', createdAt: now, updatedAt: now),
      Folder(
        id: 'child',
        parentId: 'root',
        name: '전자기학',
        createdAt: now,
        updatedAt: now,
      ),
    ];
    String? selectedFolderId = 'child';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(20),
              child: FolderPickerField(
                key: const Key('test-folder-field'),
                folders: folders,
                selectedFolderId: selectedFolderId,
                labelText: '새 상위 폴더',
                allowRoot: true,
                onChanged: (value) => setState(() => selectedFolderId = value),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('물리학 › 전자기학'), findsOneWidget);
    await tester.tap(find.byKey(const Key('test-folder-field')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const Key('folder-picker-search-field')), findsOneWidget);
    await tester.tap(find.byKey(const Key('folder-picker-root-item')));
    await tester.pumpAndSettle();

    expect(selectedFolderId, isNull);
    expect(find.text('최상위'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows에서는 폴더 선택기를 다이얼로그로 연다', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final now = DateTime.utc(2026, 9, 18);
    final folders = [
      Folder(id: 'windows-root', name: '물리학', createdAt: now, updatedAt: now),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FolderPickerField(
            key: const Key('windows-folder-field'),
            folders: folders,
            selectedFolderId: 'windows-root',
            labelText: '폴더',
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('windows-folder-field')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byKey(const Key('folder-picker-search-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
