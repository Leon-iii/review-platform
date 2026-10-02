import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import '../../support/fake_pdf_jobs.dart';

void main() {
  test('v10 기존 자료를 보존하며 작업 테이블을 추가하고 재시작 후 진행 상태를 유지한다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'review_pdf_job_migration_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/app.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    final folderId = await DriftFolderRepository(original)
        .createFolder(name: '기존 폴더');
    final source = await DriftSourceRepository(original)
        .createSource(folderId: folderId, name: '기존 자료');
    await original.customStatement('DROP TABLE document_jobs');
    await original.customStatement('PRAGMA user_version = 10');
    await original.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    final jobs = DocumentJobRepository(upgraded);
    expect(
      (await DriftSourceRepository(upgraded).getSources(folderId)).single.id,
      source.source.id,
    );
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: pdfJob('job', completedPages: 51),
    );
    jobs.dispose();
    await upgraded.close();

    final restarted = AppDatabase(NativeDatabase(file));
    addTearDown(restarted.close);
    final restoredJobs = DocumentJobRepository(restarted);
    addTearDown(restoredJobs.dispose);
    final restored = (await restoredJobs.pending()).single;
    expect(restored.folderId, folderId);
    expect(restored.serverUrl, 'http://server:5080');
    expect(DocumentJobRepository.job(restored).completedPages, 51);
    expect(restored.applied, isFalse);
    expect(
      (await DriftSourceRepository(restarted).getSources(folderId))
          .single
          .fileName,
      '기존 자료',
    );
  });
}
