import 'dart:async';

import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/features/settings/local_server/local_server_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'local_server_view_model.g.dart';

@Riverpod(keepAlive: true)
class LocalServerController extends _$LocalServerController {
  StreamSubscription<LocalServerRuntimeState>? _runtimeSubscription;
  bool _disposed = false;

  @override
  LocalServerState build() {
    final service = ref.watch(localServerServiceProvider);
    _runtimeSubscription = service.states.listen(_onRuntimeState);
    ref.onDispose(() {
      _disposed = true;
      unawaited(_runtimeSubscription?.cancel());
    });
    unawaited(_loadSettings());
    return LocalServerState(runtime: service.currentState);
  }

  Future<void> _loadSettings() async {
    try {
      final config = await ref.read(localServerConfigStoreProvider).read();
      final apiKey = await ref
          .read(localServerSecretStoreProvider)
          .read(config.provider);
      if (_disposed) return;
      state = state.copyWith(
        config: config,
        hasApiKey: (apiKey ?? '').trim().isNotEmpty,
        isLoadingSettings: false,
        clearSettingsError: true,
      );
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(
        isLoadingSettings: false,
        settingsError: '로컬 서버 설정을 불러오지 못했어요.',
      );
    }
  }

  Future<void> saveSettings({
    required LocalServerConfig config,
    required String apiKey,
  }) async {
    _validate(config, apiKey);
    state = state.copyWith(isSavingSettings: true, clearSettingsError: true);
    try {
      await ref.read(localServerConfigStoreProvider).write(config);
      final normalizedKey = apiKey.trim();
      if (normalizedKey.isNotEmpty) {
        await ref
            .read(localServerSecretStoreProvider)
            .write(config.provider, normalizedKey);
      }
      if (_disposed) return;
      state = state.copyWith(
        config: config,
        hasApiKey:
            config.provider.requiresApiKey &&
            (normalizedKey.isNotEmpty ||
                (state.config.provider == config.provider && state.hasApiKey)),
        isSavingSettings: false,
        clearSettingsError: true,
      );
    } catch (error) {
      if (!_disposed) {
        state = state.copyWith(
          isSavingSettings: false,
          settingsError: '로컬 서버 설정을 저장하지 못했어요.',
        );
      }
      rethrow;
    }
  }

  Future<void> start({
    required LocalServerConfig config,
    required String apiKey,
  }) async {
    await saveSettings(config: config, apiKey: apiKey);
    await ref.read(localServerServiceProvider).start(config);
  }

  Future<void> stop() => ref.read(localServerServiceProvider).stop();

  Future<void> selectProvider(LocalLlmProvider provider) async {
    final apiKey = await ref
        .read(localServerSecretStoreProvider)
        .read(provider);
    if (_disposed) return;
    state = state.copyWith(
      hasApiKey: provider.requiresApiKey && (apiKey ?? '').trim().isNotEmpty,
    );
  }

  void clearLogs() => ref.read(localServerServiceProvider).clearLogs();

  void _onRuntimeState(LocalServerRuntimeState runtime) {
    if (_disposed) return;
    state = state.copyWith(runtime: runtime);
  }

  void _validate(LocalServerConfig config, String apiKey) {
    if (config.model.trim().isEmpty) {
      throw const ValidationFailure('LLM Model을 입력해 주세요.');
    }
    if (config.port < 1 || config.port > 65535) {
      throw const ValidationFailure('Port는 1~65535 사이여야 해요.');
    }
    if (config.provider.requiresApiKey &&
        apiKey.trim().isEmpty &&
        !state.hasApiKey) {
      throw const ValidationFailure('선택한 Provider의 API Key를 입력해 주세요.');
    }
  }
}
