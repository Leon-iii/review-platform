// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_server_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(isWindowsPlatform)
final isWindowsPlatformProvider = IsWindowsPlatformProvider._();

final class IsWindowsPlatformProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  IsWindowsPlatformProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isWindowsPlatformProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isWindowsPlatformHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return isWindowsPlatform(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isWindowsPlatformHash() => r'e51799e719194c868dbdc3b28e1156f9d922c5dd';

@ProviderFor(localServerConfigStore)
final localServerConfigStoreProvider = LocalServerConfigStoreProvider._();

final class LocalServerConfigStoreProvider
    extends
        $FunctionalProvider<
          LocalServerConfigStore,
          LocalServerConfigStore,
          LocalServerConfigStore
        >
    with $Provider<LocalServerConfigStore> {
  LocalServerConfigStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localServerConfigStoreProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localServerConfigStoreHash();

  @$internal
  @override
  $ProviderElement<LocalServerConfigStore> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LocalServerConfigStore create(Ref ref) {
    return localServerConfigStore(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalServerConfigStore value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalServerConfigStore>(value),
    );
  }
}

String _$localServerConfigStoreHash() =>
    r'a05360baeb4d5711c924f1dc3dbd16d6e79ba983';

@ProviderFor(localServerSecretStore)
final localServerSecretStoreProvider = LocalServerSecretStoreProvider._();

final class LocalServerSecretStoreProvider
    extends
        $FunctionalProvider<
          LocalServerSecretStore,
          LocalServerSecretStore,
          LocalServerSecretStore
        >
    with $Provider<LocalServerSecretStore> {
  LocalServerSecretStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localServerSecretStoreProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localServerSecretStoreHash();

  @$internal
  @override
  $ProviderElement<LocalServerSecretStore> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LocalServerSecretStore create(Ref ref) {
    return localServerSecretStore(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalServerSecretStore value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalServerSecretStore>(value),
    );
  }
}

String _$localServerSecretStoreHash() =>
    r'03501cb796654b26df2191ad9e6abf2fcfabbc33';

@ProviderFor(localServerService)
final localServerServiceProvider = LocalServerServiceProvider._();

final class LocalServerServiceProvider
    extends
        $FunctionalProvider<
          LocalServerService,
          LocalServerService,
          LocalServerService
        >
    with $Provider<LocalServerService> {
  LocalServerServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localServerServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localServerServiceHash();

  @$internal
  @override
  $ProviderElement<LocalServerService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LocalServerService create(Ref ref) {
    return localServerService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalServerService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalServerService>(value),
    );
  }
}

String _$localServerServiceHash() =>
    r'48328f654c388b517c11a9300e3bf725b186fa8e';
