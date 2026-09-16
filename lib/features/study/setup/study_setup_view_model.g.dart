// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'study_setup_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(studyFolderOptions)
final studyFolderOptionsProvider = StudyFolderOptionsProvider._();

final class StudyFolderOptionsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<StudyFolderOption>>,
          List<StudyFolderOption>,
          Stream<List<StudyFolderOption>>
        >
    with
        $FutureModifier<List<StudyFolderOption>>,
        $StreamProvider<List<StudyFolderOption>> {
  StudyFolderOptionsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'studyFolderOptionsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$studyFolderOptionsHash();

  @$internal
  @override
  $StreamProviderElement<List<StudyFolderOption>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<StudyFolderOption>> create(Ref ref) {
    return studyFolderOptions(ref);
  }
}

String _$studyFolderOptionsHash() =>
    r'845692bd138a8ba86d8ad9f7cb55232bcea9949a';

@ProviderFor(StudySetupViewModel)
final studySetupViewModelProvider = StudySetupViewModelProvider._();

final class StudySetupViewModelProvider
    extends $AsyncNotifierProvider<StudySetupViewModel, void> {
  StudySetupViewModelProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'studySetupViewModelProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$studySetupViewModelHash();

  @$internal
  @override
  StudySetupViewModel create() => StudySetupViewModel();
}

String _$studySetupViewModelHash() =>
    r'0e0bc86eccc4b1954b769132dc556f9594ac9f09';

abstract class _$StudySetupViewModel extends $AsyncNotifier<void> {
  FutureOr<void> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<void>, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<void>, void>,
              AsyncValue<void>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
