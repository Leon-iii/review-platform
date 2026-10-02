// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'llm_profiles_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(LlmProfilesController)
final llmProfilesControllerProvider = LlmProfilesControllerProvider._();

final class LlmProfilesControllerProvider
    extends $AsyncNotifierProvider<LlmProfilesController, LlmProfileSettings> {
  LlmProfilesControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'llmProfilesControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$llmProfilesControllerHash();

  @$internal
  @override
  LlmProfilesController create() => LlmProfilesController();
}

String _$llmProfilesControllerHash() =>
    r'8a1c7f9be279801b4e67fe942ccb3cfa28dadd64';

abstract class _$LlmProfilesController
    extends $AsyncNotifier<LlmProfileSettings> {
  FutureOr<LlmProfileSettings> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<LlmProfileSettings>, LlmProfileSettings>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<LlmProfileSettings>, LlmProfileSettings>,
              AsyncValue<LlmProfileSettings>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
