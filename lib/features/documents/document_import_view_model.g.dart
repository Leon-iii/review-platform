// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'document_import_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(documentSources)
final documentSourcesProvider = DocumentSourcesFamily._();

final class DocumentSourcesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<StudySource>>,
          List<StudySource>,
          Stream<List<StudySource>>
        >
    with
        $FutureModifier<List<StudySource>>,
        $StreamProvider<List<StudySource>> {
  DocumentSourcesProvider._({
    required DocumentSourcesFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'documentSourcesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$documentSourcesHash();

  @override
  String toString() {
    return r'documentSourcesProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<StudySource>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<StudySource>> create(Ref ref) {
    final argument = this.argument as String;
    return documentSources(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is DocumentSourcesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$documentSourcesHash() => r'1b5595fadd590ec1eeabdf211aeb1be8f7175e88';

final class DocumentSourcesFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<StudySource>>, String> {
  DocumentSourcesFamily._()
    : super(
        retry: null,
        name: r'documentSourcesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DocumentSourcesProvider call(String folderId) =>
      DocumentSourcesProvider._(argument: folderId, from: this);

  @override
  String toString() => r'documentSourcesProvider';
}

@ProviderFor(DocumentImportController)
final documentImportControllerProvider = DocumentImportControllerFamily._();

final class DocumentImportControllerProvider
    extends
        $AsyncNotifierProvider<
          DocumentImportController,
          StudySourceWithConcepts?
        > {
  DocumentImportControllerProvider._({
    required DocumentImportControllerFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'documentImportControllerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$documentImportControllerHash();

  @override
  String toString() {
    return r'documentImportControllerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  DocumentImportController create() => DocumentImportController();

  @override
  bool operator ==(Object other) {
    return other is DocumentImportControllerProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$documentImportControllerHash() =>
    r'894aac184bdf23fe5ff06828f592727f36ff0db9';

final class DocumentImportControllerFamily extends $Family
    with
        $ClassFamilyOverride<
          DocumentImportController,
          AsyncValue<StudySourceWithConcepts?>,
          StudySourceWithConcepts?,
          FutureOr<StudySourceWithConcepts?>,
          String
        > {
  DocumentImportControllerFamily._()
    : super(
        retry: null,
        name: r'documentImportControllerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DocumentImportControllerProvider call(String folderId) =>
      DocumentImportControllerProvider._(argument: folderId, from: this);

  @override
  String toString() => r'documentImportControllerProvider';
}

abstract class _$DocumentImportController
    extends $AsyncNotifier<StudySourceWithConcepts?> {
  late final _$args = ref.$arg as String;
  String get folderId => _$args;

  FutureOr<StudySourceWithConcepts?> build(String folderId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<
              AsyncValue<StudySourceWithConcepts?>,
              StudySourceWithConcepts?
            >;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<StudySourceWithConcepts?>,
                StudySourceWithConcepts?
              >,
              AsyncValue<StudySourceWithConcepts?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
