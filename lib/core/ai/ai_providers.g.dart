// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(remoteAiApi)
final remoteAiApiProvider = RemoteAiApiProvider._();

final class RemoteAiApiProvider
    extends $FunctionalProvider<RemoteAiApi, RemoteAiApi, RemoteAiApi>
    with $Provider<RemoteAiApi> {
  RemoteAiApiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'remoteAiApiProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$remoteAiApiHash();

  @$internal
  @override
  $ProviderElement<RemoteAiApi> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  RemoteAiApi create(Ref ref) {
    return remoteAiApi(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(RemoteAiApi value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<RemoteAiApi>(value),
    );
  }
}

String _$remoteAiApiHash() => r'8f524327bc6591d6b2c01c20d6ad58fe1db3f15c';
