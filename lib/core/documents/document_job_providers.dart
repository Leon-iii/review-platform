import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_job_coordinator.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/features/documents/document_import_view_model.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'document_job_providers.g.dart';

@Riverpod(keepAlive: true)
DocumentJobRepository documentJobRepository(Ref ref) {
  final repository = DocumentJobRepository(ref.watch(appDatabaseProvider));
  ref.onDispose(repository.dispose);
  return repository;
}

@riverpod
Stream<List<TrackedPdfImportJob>> folderDocumentJobs(
  Ref ref,
  String folderId,
) => ref.watch(documentJobRepositoryProvider).watchFolder(folderId);
@riverpod
Stream<TrackedPdfImportJob?> documentJob(Ref ref, String id) =>
    ref.watch(documentJobRepositoryProvider).watchJob(id);
@Riverpod(keepAlive: true)
DocumentJobCoordinator? documentJobCoordinator(Ref ref) {
  final api = ref.watch(remoteDocumentApiProvider);
  if (api is! RemoteDocumentJobApi) {
    return null; // Legacy API adapters still work.
  }
  final coordinator = DocumentJobCoordinator(
    api as RemoteDocumentJobApi,
    ref.watch(documentJobRepositoryProvider),
    ref.watch(sourceRepositoryProvider),
    ref.watch(syncCredentialsStoreProvider),
    (folderId) {
      if (ref.mounted) ref.invalidate(documentSourcesProvider(folderId));
    },
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
}
