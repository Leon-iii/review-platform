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

@ProviderFor(llmProfileApi)
final llmProfileApiProvider = LlmProfileApiProvider._();

final class LlmProfileApiProvider
    extends $FunctionalProvider<LlmProfileApi, LlmProfileApi, LlmProfileApi>
    with $Provider<LlmProfileApi> {
  LlmProfileApiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'llmProfileApiProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$llmProfileApiHash();

  @$internal
  @override
  $ProviderElement<LlmProfileApi> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  LlmProfileApi create(Ref ref) {
    return llmProfileApi(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LlmProfileApi value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LlmProfileApi>(value),
    );
  }
}

String _$llmProfileApiHash() => r'2b40cee92b3f2b518823ea3ada28617e18ea7b94';
