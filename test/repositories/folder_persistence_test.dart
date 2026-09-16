import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/repositories/folder_repository.dart';

void main() {
  test('앱을 재시작해도 파일 DB의 폴더가 유지된다', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'review_platform_persistence_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final databaseFile = File('${tempDirectory.path}/folders.sqlite');

    final firstDatabase = AppDatabase(NativeDatabase(databaseFile));
    final firstRepository = DriftFolderRepository(firstDatabase);
    await firstRepository.createFolder(name: '전자기학');
    await firstDatabase.close();

    final reopenedDatabase = AppDatabase(NativeDatabase(databaseFile));
    addTearDown(reopenedDatabase.close);
    final reopenedRepository = DriftFolderRepository(reopenedDatabase);

    final tree = await reopenedRepository.watchFolderTree().first;
    expect(tree.single.folder.name, '전자기학');
    expect(tree.single.folder.createdAt.isUtc, isTrue);
  });
}
