import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import '../../support/fake_pdf_jobs.dart';

void main() {
  test('삭제된 작업의 늦은 결과를 저장하지 않으며 반영된 작업은 제거하지 않는다', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final jobs = DocumentJobRepository(database);
    addTearDown(jobs.dispose);
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '자료');
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: pdfJob('removed'),
    );
    await jobs.remove('removed');
    var saves = 0;
    await jobs.applyResult('removed', (_) async {
      saves++;
    });
    expect(saves, 0);
    expect(await jobs.get('removed'), isNull);
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: pdfJob('applied'),
    );
    await jobs.applyResult('applied', (_) async {
      saves++;
    });
    await jobs.applyResult('applied', (_) async {
      saves++;
    });
    await jobs.remove('applied');
    expect(saves, 1);
    expect((await jobs.get('applied'))!.applied, isTrue);
  });

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
    await original.customStatement(
      'ALTER TABLE questions DROP COLUMN importance',
    );
    await original.customStatement(
      'ALTER TABLE quiz_session_items DROP COLUMN skipped_for_review',
    );
    await original.customStatement('PRAGMA user_version = 10');
    await original.customStatement(
      'ALTER TABLE questions DROP COLUMN case_sensitive',
    );
    await original.customStatement(
      'ALTER TABLE questions DROP COLUMN whitespace_sensitive',
    );
    await original.customStatement(
      'ALTER TABLE questions DROP COLUMN correct_choice_ids_json',
    );
    await original.customStatement(
      'ALTER TABLE quiz_session_items DROP COLUMN pending_essay_response_json',
    );
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
    final destinationId = await DriftFolderRepository(upgraded)
        .createFolder(name: '이동 목적지');
    await jobs.move(
      'job',
      destinationId,
      moveAppliedSource: () async {
        fail('미완료 작업은 자료 이동 파이프라인을 호출하지 않습니다.');
      },
    );
    jobs.dispose();
    await upgraded.close();

    final restarted = AppDatabase(NativeDatabase(file));
    addTearDown(restarted.close);
    final restoredJobs = DocumentJobRepository(restarted);
    addTearDown(restoredJobs.dispose);
    final restored = (await restoredJobs.pending()).single;
    expect(restored.folderId, destinationId);
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
