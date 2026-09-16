// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'folder_browser_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(FolderBrowserViewModel)
final folderBrowserViewModelProvider = FolderBrowserViewModelFamily._();

final class FolderBrowserViewModelProvider
    extends
        $StreamNotifierProvider<FolderBrowserViewModel, FolderBrowserState> {
  FolderBrowserViewModelProvider._({
    required FolderBrowserViewModelFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'folderBrowserViewModelProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$folderBrowserViewModelHash();

  @override
  String toString() {
    return r'folderBrowserViewModelProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  FolderBrowserViewModel create() => FolderBrowserViewModel();

  @override
  bool operator ==(Object other) {
    return other is FolderBrowserViewModelProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$folderBrowserViewModelHash() =>
    r'7ee9748bde5a5cbbec439a48b254e6e4d0bf8095';

final class FolderBrowserViewModelFamily extends $Family
    with
        $ClassFamilyOverride<
          FolderBrowserViewModel,
          AsyncValue<FolderBrowserState>,
          FolderBrowserState,
          Stream<FolderBrowserState>,
          String?
        > {
  FolderBrowserViewModelFamily._()
    : super(
        retry: null,
        name: r'folderBrowserViewModelProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  FolderBrowserViewModelProvider call(String? folderId) =>
      FolderBrowserViewModelProvider._(argument: folderId, from: this);

  @override
  String toString() => r'folderBrowserViewModelProvider';
}

abstract class _$FolderBrowserViewModel
    extends $StreamNotifier<FolderBrowserState> {
  late final _$args = ref.$arg as String?;
  String? get folderId => _$args;

  Stream<FolderBrowserState> build(String? folderId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<FolderBrowserState>, FolderBrowserState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<FolderBrowserState>, FolderBrowserState>,
              AsyncValue<FolderBrowserState>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
