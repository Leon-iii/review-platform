// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_server_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(LocalServerController)
final localServerControllerProvider = LocalServerControllerProvider._();

final class LocalServerControllerProvider
    extends $NotifierProvider<LocalServerController, LocalServerState> {
  LocalServerControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localServerControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localServerControllerHash();

  @$internal
  @override
  LocalServerController create() => LocalServerController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalServerState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalServerState>(value),
    );
  }
}

String _$localServerControllerHash() =>
    r'cf379c8fc7d29ba40ce42dc534dd3be604b6c0b9';

abstract class _$LocalServerController extends $Notifier<LocalServerState> {
  LocalServerState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<LocalServerState, LocalServerState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LocalServerState, LocalServerState>,
              LocalServerState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
