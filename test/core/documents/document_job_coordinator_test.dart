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
import '../../support/fake_pdf_extraction.dart';
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
  final errors = <String>[];
  test('선택 대기 업로드는 앱 재시작·오프라인 조회로 실패 처리하지 않고 시작을 따로 전달한다', () async {
    coordinator.dispose();
    final extractionApi = FakePdfExtractionApi();
    coordinator = DocumentJobCoordinator(
      extractionApi,
      jobs,
      DriftSourceRepository(database),
      MemorySyncCredentialsStore(
        configuration: const SyncConfiguration(
          serverUrl: 'http://server:5080',
          accessToken: 'token',
        ),
      ),
      (_) {},
      onError: (job) => errors.add(job.error!),
    );
    final id = await coordinator.upload(
      folderId,
      PickedPdfDocument(
        fileName: '강의.pdf',
        bytes: Uint8List.fromList([37, 80, 68, 70, 45]),
      ),
    );
    await coordinator.poll();
    expect(
      DocumentJobRepository.job((await jobs.get(id))!).isAwaitingSelection,
      true,
    );
    expect(extractionApi.starts, 0);
    expect(extractionApi.results, 0);
    coordinator.dispose();
    await coordinator.poll();
    coordinator = DocumentJobCoordinator(
      extractionApi,
      jobs,
      sources,
      credentials,
      savedFolders.add,
      onError: (job) => errors.add(job.error!),
    );
    extractionApi.offline = true;
    await coordinator.poll();
    expect(errors, isEmpty);
    expect(DocumentJobRepository.job((await jobs.get(id))!).error, isNull);
    extractionApi.offline = false;
    await coordinator.startExtraction(id, {'mode': 'direct', 'revision': 0});
    await coordinator.poll();
    expect(extractionApi.starts, 1);
    expect(DocumentJobRepository.job((await jobs.get(id))!).status, 'queued');
  });
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
    errors.clear();
    coordinator = DocumentJobCoordinator(
      api,
      jobs,
      sources,
      credentials,
      savedFolders.add,
      onError: (job) => errors.add(job.error!),
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

  for (final status in [
    'uploading',
    'queued',
    'running',
    'awaiting_review',
    'failed',
    'cancelled',
    'uploadFailed',
  ]) {
    test('미완료 $status 작업은 서버 연결 없이 이동하고 상태를 보존한다', () async {
      final targetId = await DriftFolderRepository(database)
          .createFolder(name: '이동 대상');
      const id = 'moving-job';
      final job = pdfJob(
        id,
        status: status,
        completedPages: 37,
        error: '이전 버전 오류',
      );
      await jobs.add(
        folderId: folderId,
        serverUrl: 'http://server:5080',
        job: job,
      );
      credentials.configuration = null;
      api.offline = true;
      await coordinator.move(id, targetId);
      final moved = (await jobs.get(id))!;
      expect(moved.folderId, targetId);
      expect(moved.serverUrl, 'http://server:5080');
      expect(moved.applied, isFalse);
      expect(DocumentJobRepository.job(moved).data, job.data);
      expect(await jobs.watchFolder(folderId).first, isEmpty);
      expect((await jobs.watchFolder(targetId).first).single.id, id);
      expect(api.actions, isEmpty);
      expect(api.statusReads, isEmpty);
      expect(api.results, 0);
      expect(savedFolders, [folderId, targetId]);
    });
  }

  test('이동 후 완료한 결과는 이동한 폴더에 한 번만 저장한다', () async {
    final targetId = await DriftFolderRepository(database)
        .createFolder(name: '이동 대상');
    const id = 'moving-job';
    api.jobs[id] = pdfJob(id, status: 'awaiting_review');
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    await coordinator.move(id, targetId);
    api.jobs[id] = pdfJob(id, status: 'completed');
    await coordinator.poll();
    await coordinator.poll();
    expect(await sources.getSources(folderId), isEmpty);
    expect((await sources.getSources(targetId)).single.id, id);
    expect((await jobs.get(id))!.applied, isTrue);
    expect(api.results, 1);
    expect(savedFolders.last, targetId);
  });

  test('이동과 늦은 완료 결과가 겹쳐도 이전 폴더에 저장하지 않는다', () async {
    final targetId = await DriftFolderRepository(database)
        .createFolder(name: '이동 대상');
    const id = 'racing-move';
    api.jobs[id] = pdfJob(id, status: 'completed');
    api.resultGate = Completer();
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    final polling = coordinator.poll();
    while (api.results == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await coordinator.move(id, targetId);
    api.resultGate!.complete(pdfResult(id));
    await polling;
    await coordinator.poll();
    expect(await sources.getSources(folderId), isEmpty);
    expect((await sources.getSources(targetId)).single.id, id);
  });

  test('옛 목록을 조회 중 다른 작업을 이동해도 저장 시점의 목적지를 사용한다', () async {
    final targetId = await DriftFolderRepository(database)
        .createFolder(name: '이동 대상');
    api.jobs['first'] = pdfJob('first');
    api.jobs['second'] = pdfJob('second', status: 'completed');
    for (final id in ['first', 'second']) {
      await jobs.add(
        folderId: folderId,
        serverUrl: 'http://server:5080',
        job: api.jobs[id]!,
      );
    }
    api.getGate = Completer();
    final gate = api.getGate!;
    final polling = coordinator.poll();
    while (api.statusReads.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await coordinator.move('second', targetId);
    api.getGate = null;
    gate.complete(pdfJob('first'));
    await polling;
    expect(await sources.getSources(folderId), isEmpty);
    expect((await sources.getSources(targetId)).single.id, 'second');
    expect(savedFolders.last, targetId);
  });

  test('폴더 선택 중 추출이 완료되어도 개념을 유지하며 자료로 이동한다', () async {
    final targetId = await DriftFolderRepository(database)
        .createFolder(name: '이동 대상');
    const id = 'completed-move';
    api.jobs[id] = pdfJob(id, status: 'completed');
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    await coordinator.poll();
    final before = await sources.getSourceWithConcepts(id);
    final pendingBefore = await database.syncDao.getPendingCount();
    await coordinator.move(id, targetId);
    final moved = await sources.getSourceWithConcepts(id);
    expect(moved.source.folderId, targetId);
    expect(
      moved.concepts.map((concept) => concept.id),
      before.concepts.map((concept) => concept.id),
    );
    expect((await jobs.get(id))!.folderId, targetId);
    expect((await jobs.get(id))!.applied, isTrue);
    expect(await sources.getSources(folderId), isEmpty);
    expect(await database.syncDao.getPendingCount(), pendingBefore + 1);
    expect(api.results, 1);
  });

  test('동일 폴더 이동은 무시하고 없는 폴더·작업 이동은 거부한다', () async {
    const id = 'moving-job';
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: pdfJob(id),
    );
    await coordinator.move(id, folderId);
    expect(savedFolders, isEmpty);
    await expectLater(
      coordinator.move(id, 'missing'),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      coordinator.move('missing', folderId),
      throwsA(isA<ValidationFailure>()),
    );
    final deletedId = await DriftFolderRepository(database)
        .createFolder(name: '삭제된 폴더');
    await DriftFolderRepository(database).deleteFolder(deletedId);
    await expectLater(
      coordinator.move(id, deletedId),
      throwsA(isA<ValidationFailure>()),
    );
    expect((await jobs.get(id))!.folderId, folderId);
  });

  for (final status in [
    'failed',
    'awaiting_review',
    'cancelled',
    'queued',
    'uploadFailed',
  ]) {
    test('이전 PDF 작업 $status 삭제 후 로컬 목록·서버에서 제거한다', () async {
      const id = 'old-job';
      api.jobs[id] = pdfJob(
        id,
        status: status,
        error: '서버의 분석 지침 버전이 변경되었습니다.',
      );
      await jobs.add(
        folderId: folderId,
        serverUrl: 'http://server:5080',
        job: api.jobs[id]!,
      );
      await coordinator.delete(id);
      expect(api.deletedJobs, [id]);
      expect(await jobs.get(id), isNull);
      expect(await jobs.watchFolder(folderId).first, isEmpty);
      await coordinator.poll();
      expect(await sources.getSources(folderId), isEmpty);
      expect(errors, isEmpty);
    });
  }

  test('삭제 실패 시 작업을 보존하며 성공 후 다시 삭제할 수 있다', () async {
    const id = 'old-job';
    api.jobs[id] = pdfJob(id, status: 'failed');
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    api.deleteError = const NetworkFailure('삭제 실패');
    await expectLater(coordinator.delete(id), throwsA(isA<NetworkFailure>()));
    expect(await jobs.get(id), isNotNull);
    api.deleteError = null;
    await coordinator.delete(id);
    expect(await jobs.get(id), isNull);
  });

  test('삭제 중 늦게 도착한 완료 결과가 자료를 다시 만들지 않는다', () async {
    const id = 'racing-job';
    api.jobs[id] = pdfJob(id, status: 'completed');
    api.resultGate = Completer();
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    final polling = coordinator.poll();
    while (api.results == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await coordinator.delete(id);
    expect(await jobs.get(id), isNull);
    api.resultGate!.complete(pdfResult(id));
    await polling;
    expect(await jobs.get(id), isNull);
    expect(await sources.getSources(folderId), isEmpty);
    expect(savedFolders, isEmpty);
  });

  test('상태 조회가 응답하지 않아도 삭제하고 늦은 응답은 무시한다', () async {
    const id = 'racing-status';
    api.jobs[id] = pdfJob(id);
    api.getGate = Completer();
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://server:5080',
      job: api.jobs[id]!,
    );
    final polling = coordinator.poll();
    while (api.statusReads.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await coordinator.delete(id);
    expect(await jobs.get(id), isNull);
    api.getGate!.complete(pdfJob(id, status: 'completed'));
    await polling;
    expect(await sources.getSources(folderId), isEmpty);
    expect(api.results, 0);
    expect(errors, isEmpty);
  });

  test('다른 서버 또는 이미 가져온 자료는 작업 삭제로 제거하지 않는다', () async {
    const id = 'old-job';
    api.jobs[id] = pdfJob(id, status: 'failed');
    await jobs.add(
      folderId: folderId,
      serverUrl: 'http://other:5080',
      job: api.jobs[id]!,
    );
    await expectLater(
      coordinator.delete(id),
      throwsA(isA<ValidationFailure>()),
    );
    expect(await jobs.get(id), isNotNull);
    credentials.configuration = const SyncConfiguration(
      serverUrl: 'http://other:5080',
      accessToken: 'token',
    );
    await jobs.applyResult(
      id,
      (currentFolderId) =>
          sources.saveImport(folderId: currentFolderId, result: pdfResult(id)),
    );
    await expectLater(
      coordinator.delete(id),
      throwsA(isA<ValidationFailure>()),
    );
    expect(api.deletedJobs, isEmpty);
    expect((await sources.getSources(folderId)).single.id, id);
  });

  test('다른 작업 조회 중 삭제된 항목은 옛 목록 스냅샷에서 다시 조회하지 않는다', () async {
    for (final id in ['first', 'second']) {
      api.jobs[id] = pdfJob(id);
      await jobs.add(
        folderId: folderId,
        serverUrl: 'http://server:5080',
        job: api.jobs[id]!,
      );
    }
    api.getGate = Completer();
    final gate = api.getGate!;
    final polling = coordinator.poll();
    while (api.statusReads.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(api.statusReads, ['first']);
    await coordinator.delete('second');
    api.getGate = null;
    gate.complete(pdfJob('first'));
    await polling;
    expect(api.statusReads, ['first']);
    expect(await jobs.get('second'), isNull);
    expect(errors, isEmpty);
  });

  test('업로드는 빠르게 등록하고 완료 결과는 검토 필요 상태로 한 번만 저장한다', () async {
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    expect((await sources.getSources(folderId)), isEmpty);
    expect(
      DocumentJobRepository.job((await jobs.get(id))!).status,
      'awaiting_selection',
    );
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
    expect(
      DocumentJobRepository.job((await jobs.get(id))!).status,
      'awaiting_selection',
    );
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
    api.jobs[id] = pdfJob(id, status: 'queued');
    await coordinator.poll();
    api.offline = true;
    await coordinator.poll();
    final offline = DocumentJobRepository.job((await jobs.get(id))!);
    expect(offline.status, 'queued');
    expect(offline.error, '연결 실패');
    await coordinator.poll();
    expect(errors, ['연결 실패']);
    api.offline = false;
    api.jobs[id] = pdfJob(id, completedPages: 51);
    await coordinator.poll();
    final resumed = DocumentJobRepository.job((await jobs.get(id))!);
    expect(resumed.completedPages, 51);
    expect(resumed.error, isNull);
    api.offline = true;
    await coordinator.poll();
    expect(errors, ['연결 실패', '연결 실패']);
  });

  test('로컬 서버 준비 완료 전에는 상태 요청·오류 알림을 실행하지 않는다', () async {
    const id = 'starting-server-job';
    api.jobs[id] = pdfJob(id);
    await jobs.add(
      folderId: folderId,
      serverUrl: credentials.configuration!.serverUrl,
      job: api.jobs[id]!,
    );
    final entered = Completer<void>();
    final ready = Completer<bool>();
    coordinator.dispose();
    coordinator = DocumentJobCoordinator(
      api,
      jobs,
      sources,
      credentials,
      savedFolders.add,
      onError: (job) => errors.add(job.error!),
      canPoll: (_) {
        entered.complete();
        return ready.future;
      },
    );
    final polling = coordinator.poll();
    await entered.future;
    expect(api.statusReads, isEmpty);
    expect(errors, isEmpty);
    expect(DocumentJobRepository.job((await jobs.get(id))!).status, 'running');
    ready.complete(true);
    await polling;
    expect(api.statusReads, [id]);
    expect(errors, isEmpty);
  });

  test('서버가 꺼져 있으면 조회를 보류하고 켜진 후 완료 결과를 가져온다', () async {
    const id = 'stopped-server-job';
    api.jobs[id] = pdfJob(id, status: 'completed');
    await jobs.add(
      folderId: folderId,
      serverUrl: credentials.configuration!.serverUrl,
      job: pdfJob(id),
    );
    var ready = false;
    coordinator.dispose();
    coordinator = DocumentJobCoordinator(
      api,
      jobs,
      sources,
      credentials,
      savedFolders.add,
      onError: (job) => errors.add(job.error!),
      canPoll: (_) async => ready,
    );
    await coordinator.poll();
    await coordinator.poll();
    expect(api.statusReads, isEmpty);
    expect(errors, isEmpty);
    expect((await jobs.get(id))!.applied, isFalse);
    ready = true;
    await coordinator.poll();
    expect((await jobs.get(id))!.applied, isTrue);
    expect(api.results, 1);
  });

  test('이전 추출 대기는 연결이 끊겨도 조용히 유지하며 복구 후 다른 기기 확정을 감지한다', () async {
    const id = 'waiting-review-job';
    final original = pdfJob(id, status: 'awaiting_review', completedPages: 80);
    await jobs.add(
      folderId: folderId,
      serverUrl: credentials.configuration!.serverUrl,
      job: original,
    );
    api.offline = true;
    await coordinator.poll();
    await coordinator.poll();
    final waiting = DocumentJobRepository.job((await jobs.get(id))!);
    expect(waiting.isAwaitingSelection, isTrue);
    expect(waiting.completedPages, 80);
    expect(waiting.error, isNull);
    expect(waiting.data, original.data);
    expect(errors, isEmpty);
    expect(api.actions, isEmpty);
    expect(api.results, 0);
    api.offline = false;
    api.jobs[id] = pdfJob(id, status: 'completed', completedPages: 80);
    await coordinator.poll();
    expect((await jobs.get(id))!.applied, isTrue);
    expect(errors, isEmpty);
  });

  test('재시작 시 검토 대기의 기존 연결 오류는 무시하고 실제 분석 실패는 알린다', () async {
    const id = 'old-waiting-error';
    final stale = pdfJob(
      id,
      status: 'awaiting_review',
      error: 'PDF 처리 서버에 연결할 수 없어요.',
    );
    expect(stale.error, isNull);
    await jobs.add(
      folderId: folderId,
      serverUrl: credentials.configuration!.serverUrl,
      job: stale,
    );
    api.offline = true;
    await coordinator.poll();
    expect(errors, isEmpty);
    expect(DocumentJobRepository.job((await jobs.get(id))!).error, isNull);
    api.offline = false;
    api.jobs[id] = pdfJob(id, status: 'failed', error: '개념 추출 실패');
    await coordinator.poll();
    expect(errors, ['개념 추출 실패']);
  });

  test('재시작 시 진행 중 작업의 이전 조회 오류를 새 응답보다 먼저 알리지 않는다', () async {
    const id = 'old-active-error';
    await jobs.add(
      folderId: folderId,
      serverUrl: credentials.configuration!.serverUrl,
      job: pdfJob(id, error: '이전 연결 실패'),
    );
    api.jobs[id] = pdfJob(id, status: 'awaiting_review');
    await coordinator.poll();
    expect(errors, isEmpty);
    expect(
      DocumentJobRepository.job((await jobs.get(id))!).isAwaitingSelection,
      isTrue,
    );
  });

  test('백그라운드 분석 실패를 한 번 알리고 재시도 후 새 실패는 다시 알린다', () async {
    final id = await coordinator.upload(folderId, pdf());
    await coordinator.poll();
    api.jobs[id] = pdfJob(id, status: 'failed', error: 'PDF 추출 실패');
    await coordinator.poll();
    await coordinator.poll();
    expect(errors.length, 1);
    await coordinator.change(id, 'retry');
    api.jobs[id] = pdfJob(id, status: 'failed', error: 'PDF 추출 실패');
    await coordinator.poll();
    expect(errors.length, 2);
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
