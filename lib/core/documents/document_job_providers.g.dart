// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'document_job_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(documentJobRepository)
final documentJobRepositoryProvider = DocumentJobRepositoryProvider._();

final class DocumentJobRepositoryProvider
    extends
        $FunctionalProvider<
          DocumentJobRepository,
          DocumentJobRepository,
          DocumentJobRepository
        >
    with $Provider<DocumentJobRepository> {
  DocumentJobRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'documentJobRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$documentJobRepositoryHash();

  @$internal
  @override
  $ProviderElement<DocumentJobRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  DocumentJobRepository create(Ref ref) {
    return documentJobRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DocumentJobRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DocumentJobRepository>(value),
    );
  }
}

String _$documentJobRepositoryHash() =>
    r'1ea67c678f9855e963f4ac7eee1421cbf75982b9';

@ProviderFor(folderDocumentJobs)
final folderDocumentJobsProvider = FolderDocumentJobsFamily._();

final class FolderDocumentJobsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<TrackedPdfImportJob>>,
          List<TrackedPdfImportJob>,
          Stream<List<TrackedPdfImportJob>>
        >
    with
        $FutureModifier<List<TrackedPdfImportJob>>,
        $StreamProvider<List<TrackedPdfImportJob>> {
  FolderDocumentJobsProvider._({
    required FolderDocumentJobsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'folderDocumentJobsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$folderDocumentJobsHash();

  @override
  String toString() {
    return r'folderDocumentJobsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<TrackedPdfImportJob>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<TrackedPdfImportJob>> create(Ref ref) {
    final argument = this.argument as String;
    return folderDocumentJobs(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is FolderDocumentJobsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$folderDocumentJobsHash() =>
    r'1e138fbd45e21ded7886b6805d84f386cd3303ba';

final class FolderDocumentJobsFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<TrackedPdfImportJob>>, String> {
  FolderDocumentJobsFamily._()
    : super(
        retry: null,
        name: r'folderDocumentJobsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  FolderDocumentJobsProvider call(String folderId) =>
      FolderDocumentJobsProvider._(argument: folderId, from: this);

  @override
  String toString() => r'folderDocumentJobsProvider';
}

@ProviderFor(documentJob)
final documentJobProvider = DocumentJobFamily._();

final class DocumentJobProvider
    extends
        $FunctionalProvider<
          AsyncValue<TrackedPdfImportJob?>,
          TrackedPdfImportJob?,
          Stream<TrackedPdfImportJob?>
        >
    with
        $FutureModifier<TrackedPdfImportJob?>,
        $StreamProvider<TrackedPdfImportJob?> {
  DocumentJobProvider._({
    required DocumentJobFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'documentJobProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$documentJobHash();

  @override
  String toString() {
    return r'documentJobProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<TrackedPdfImportJob?> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<TrackedPdfImportJob?> create(Ref ref) {
    final argument = this.argument as String;
    return documentJob(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is DocumentJobProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$documentJobHash() => r'72211395f3997e56e3eda5968ed3d5b81f6dff9c';

final class DocumentJobFamily extends $Family
    with $FunctionalFamilyOverride<Stream<TrackedPdfImportJob?>, String> {
  DocumentJobFamily._()
    : super(
        retry: null,
        name: r'documentJobProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DocumentJobProvider call(String id) =>
      DocumentJobProvider._(argument: id, from: this);

  @override
  String toString() => r'documentJobProvider';
}

@ProviderFor(documentJobCoordinator)
final documentJobCoordinatorProvider = DocumentJobCoordinatorProvider._();

final class DocumentJobCoordinatorProvider
    extends
        $FunctionalProvider<
          DocumentJobCoordinator?,
          DocumentJobCoordinator?,
          DocumentJobCoordinator?
        >
    with $Provider<DocumentJobCoordinator?> {
  DocumentJobCoordinatorProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'documentJobCoordinatorProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$documentJobCoordinatorHash();

  @$internal
  @override
  $ProviderElement<DocumentJobCoordinator?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  DocumentJobCoordinator? create(Ref ref) {
    return documentJobCoordinator(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DocumentJobCoordinator? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DocumentJobCoordinator?>(value),
    );
  }
}

String _$documentJobCoordinatorHash() =>
    r'a1acab6381575185bdee170a78b4c70704784f52';
