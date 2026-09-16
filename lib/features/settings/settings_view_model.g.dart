// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(syncStatus)
final syncStatusProvider = SyncStatusProvider._();

final class SyncStatusProvider
    extends
        $FunctionalProvider<
          AsyncValue<SyncStatus>,
          SyncStatus,
          Stream<SyncStatus>
        >
    with $FutureModifier<SyncStatus>, $StreamProvider<SyncStatus> {
  SyncStatusProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncStatusProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncStatusHash();

  @$internal
  @override
  $StreamProviderElement<SyncStatus> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<SyncStatus> create(Ref ref) {
    return syncStatus(ref);
  }
}

String _$syncStatusHash() => r'88143257bc80d185ba7a272674e94a20c7bba5b4';

@ProviderFor(syncSettings)
final syncSettingsProvider = SyncSettingsProvider._();

final class SyncSettingsProvider
    extends
        $FunctionalProvider<
          AsyncValue<SyncSettings>,
          SyncSettings,
          FutureOr<SyncSettings>
        >
    with $FutureModifier<SyncSettings>, $FutureProvider<SyncSettings> {
  SyncSettingsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncSettingsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncSettingsHash();

  @$internal
  @override
  $FutureProviderElement<SyncSettings> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<SyncSettings> create(Ref ref) {
    return syncSettings(ref);
  }
}

String _$syncSettingsHash() => r'84e6c77ebf2cd47658367c1a654131a0cc943e01';

@ProviderFor(ManualSync)
final manualSyncProvider = ManualSyncProvider._();

final class ManualSyncProvider
    extends $AsyncNotifierProvider<ManualSync, void> {
  ManualSyncProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'manualSyncProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$manualSyncHash();

  @$internal
  @override
  ManualSync create() => ManualSync();
}

String _$manualSyncHash() => r'157429830e0aebf388cc348acf21e49fa41bc5f5';

abstract class _$ManualSync extends $AsyncNotifier<void> {
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
