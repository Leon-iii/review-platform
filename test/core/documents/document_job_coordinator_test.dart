import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/documents/document_job_coordinator.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import '../../support/fake_pdf_jobs.dart';
import '../../support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late String folderId;
  late DocumentJobRepository jobs;
  late DriftSourceRepository sources;
  late FakePdfJobsApi api;
  late MemorySyncCredentialsStore credentials;
  late DocumentJobCoordinator coordinator;
  final savedFolders = <String>[];
  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    folderId = await DriftFolderRepository(database).createFolder(name: '자료');
    jobs = DocumentJobRepository(database);
    sources = DriftSourceRepository(database);
    api = FakePdfJobsApi();
    credentials = MemorySyncCredentialsStore(
      configuration: const SyncConfiguration(
        serverUrl: 'http://server:5080',
        accessToken: 'token',
      ),
    );
    savedFolders.clear();
    coordinator = DocumentJobCoordinator(
      api,
      jobs,
      sources,
      credentials,
      savedFolders.add,
    );
  });
  tearDown(() async {
    coordinator.dispose();
    await coordinator.poll();
    await database.close();
  });
  PickedPdfDocument pdf() => PickedPdfDocument(
    fileName: '긴 강의.pdf',
    bytes: Uint8List.fromList([37, 80, 68, 70, 45]),
  );

  test('업로드는 빠르게 등록하고 완료 결과는 검토 필요 상태로 한 번만 저장한다', () async {
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    expect((await sources.getSources(folderId)), isEmpty);
    expect(DocumentJobRepository.job((await jobs.get(id))!).status, 'queued');
    api.jobs[id] = pdfJob(id, status: 'completed');
    await coordinator.poll();
    expect((await jobs.get(id))!.applied, isTrue);
    final source = await sources.getSourceWithConcepts(id);
    expect(source.concepts.single.status, ConceptStatus.held);
    expect(source.source.pageCount, 80);
    await coordinator.poll();
    expect(api.results, 1);
    expect(savedFolders, [folderId]);
  });

  test('업로드 응답 유실은 저장된 ID로 복구하고 앱 재시작도 이어서 확인한다', () async {
    api.loseReceipt = true;
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    expect(DocumentJobRepository.job((await jobs.get(id))!).status, 'queued');
    coordinator.dispose();
    coordinator = DocumentJobCoordinator(
      api,
      jobs,
      sources,
      credentials,
      savedFolders.add,
    );
    api.jobs[id] = pdfJob(id, status: 'completed');
    await coordinator.poll();
    expect((await sources.getSources(folderId)).single.id, id);
    expect((await jobs.get(id))!.applied, isTrue);
  });

  test('서버 연결이 끊겨도 진행 상태를 보존하고 복구 후 계속 확인한다', () async {
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    api.offline = true;
    await coordinator.poll();
    final offline = DocumentJobRepository.job((await jobs.get(id))!);
    expect(offline.status, 'queued');
    expect(offline.error, '연결 실패');
    api.offline = false;
    api.jobs[id] = pdfJob(id, completedPages: 51);
    await coordinator.poll();
    final resumed = DocumentJobRepository.job((await jobs.get(id))!);
    expect(resumed.completedPages, 51);
    expect(resumed.error, isNull);
  });

  test('서버 용량 제한은 파일을 읽기 전에 확인한다', () async {
    api.maximumBytes = 1;
    var opened = false;
    final picked = PickedPdfDocument.stream(
      fileName: '큰 자료.pdf',
      length: 2,
      openRead: () {
        opened = true;
        return Stream.value([1, 2]);
      },
    );
    await expectLater(
      coordinator.upload(folderId, picked),
      throwsA(isA<ValidationFailure>()),
    );
    expect(opened, isFalse);
    expect(await jobs.pending(), isEmpty);
  });

  test('다른 서버로 설정을 바꾸면 기존 서버 작업을 잘못 조회하지 않는다', () async {
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    api.jobs[id] = pdfJob(id, status: 'completed');
    credentials.configuration = const SyncConfiguration(
      serverUrl: 'http://other:5080',
      accessToken: 'other',
    );
    await coordinator.poll();
    expect((await jobs.get(id))!.applied, isFalse);
    expect(api.results, 0);
  });

  test('취소 후 늦게 들어온 진행 응답이 취소 상태를 덮어쓰지 않는다', () async {
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    api.getGate = Completer();
    final polling = coordinator.poll();
    await Future<void>.delayed(Duration.zero);
    await coordinator.change(id, 'cancel');
    api.getGate!.complete(pdfJob(id));
    await polling;
    expect(
      DocumentJobRepository.job((await jobs.get(id))!).status,
      'cancelled',
    );
    api.getGate = null;
    await coordinator.change(id, 'retry');
    expect(DocumentJobRepository.job((await jobs.get(id))!).status, 'queued');
    expect(api.actions, ['cancel', 'retry']);
  });

  test('동일 결과를 다시 적용해도 기존 편집과 검토 상태 및 개념 ID를 보존한다', () async {
    final first = await sources.saveImport(
      folderId: folderId,
      result: pdfResult('source'),
    );
    final concept = first.concepts.single;
    await sources.updateConcept(
      id: concept.id,
      title: '직접 수정',
      content: '사용자 편집',
      importance: concept.importance,
    );
    await sources.setConceptApproval(id: concept.id, approved: true);
    final second = await sources.saveImport(
      folderId: folderId,
      result: pdfResult('source'),
    );
    expect(second.concepts.single.id, concept.id);
    expect(second.concepts.single.content, '사용자 편집');
    expect(second.concepts.single.status, ConceptStatus.approved);
    expect((await sources.getSources(folderId)).length, 1);
  });
}
