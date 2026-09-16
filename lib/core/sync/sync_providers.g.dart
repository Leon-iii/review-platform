// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(syncCredentialsStore)
final syncCredentialsStoreProvider = SyncCredentialsStoreProvider._();

final class SyncCredentialsStoreProvider
    extends
        $FunctionalProvider<
          SyncCredentialsStore,
          SyncCredentialsStore,
          SyncCredentialsStore
        >
    with $Provider<SyncCredentialsStore> {
  SyncCredentialsStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncCredentialsStoreProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncCredentialsStoreHash();

  @$internal
  @override
  $ProviderElement<SyncCredentialsStore> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  SyncCredentialsStore create(Ref ref) {
    return syncCredentialsStore(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SyncCredentialsStore value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SyncCredentialsStore>(value),
    );
  }
}

String _$syncCredentialsStoreHash() =>
    r'cd6e4342b963ed8fb725d09712712fbbcb5f305f';

@ProviderFor(syncHttpClient)
final syncHttpClientProvider = SyncHttpClientProvider._();

final class SyncHttpClientProvider
    extends $FunctionalProvider<http.Client, http.Client, http.Client>
    with $Provider<http.Client> {
  SyncHttpClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncHttpClientProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncHttpClientHash();

  @$internal
  @override
  $ProviderElement<http.Client> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  http.Client create(Ref ref) {
    return syncHttpClient(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(http.Client value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<http.Client>(value),
    );
  }
}

String _$syncHttpClientHash() => r'9319ce6510d7fb63340bfff300e907ef87bcfc0e';

@ProviderFor(remoteSyncApi)
final remoteSyncApiProvider = RemoteSyncApiProvider._();

final class RemoteSyncApiProvider
    extends $FunctionalProvider<RemoteSyncApi, RemoteSyncApi, RemoteSyncApi>
    with $Provider<RemoteSyncApi> {
  RemoteSyncApiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'remoteSyncApiProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$remoteSyncApiHash();

  @$internal
  @override
  $ProviderElement<RemoteSyncApi> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  RemoteSyncApi create(Ref ref) {
    return remoteSyncApi(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(RemoteSyncApi value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<RemoteSyncApi>(value),
    );
  }
}

String _$remoteSyncApiHash() => r'ccabda50886b4db13be67bde80b8daf3b6639189';

@ProviderFor(syncCoordinator)
final syncCoordinatorProvider = SyncCoordinatorProvider._();

final class SyncCoordinatorProvider
    extends
        $FunctionalProvider<SyncCoordinator, SyncCoordinator, SyncCoordinator>
    with $Provider<SyncCoordinator> {
  SyncCoordinatorProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncCoordinatorProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncCoordinatorHash();

  @$internal
  @override
  $ProviderElement<SyncCoordinator> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  SyncCoordinator create(Ref ref) {
    return syncCoordinator(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SyncCoordinator value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SyncCoordinator>(value),
    );
  }
}

String _$syncCoordinatorHash() => r'0466e18719f90ae69080ddf5767350b8dfd5ef52';

@ProviderFor(automaticSyncController)
final automaticSyncControllerProvider = AutomaticSyncControllerProvider._();

final class AutomaticSyncControllerProvider
    extends
        $FunctionalProvider<
          AutomaticSyncController,
          AutomaticSyncController,
          AutomaticSyncController
        >
    with $Provider<AutomaticSyncController> {
  AutomaticSyncControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'automaticSyncControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$automaticSyncControllerHash();

  @$internal
  @override
  $ProviderElement<AutomaticSyncController> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AutomaticSyncController create(Ref ref) {
    return automaticSyncController(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AutomaticSyncController value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AutomaticSyncController>(value),
    );
  }
}

String _$automaticSyncControllerHash() =>
    r'803f1c48d8d843134416565f8f97900e3d9b3d85';
