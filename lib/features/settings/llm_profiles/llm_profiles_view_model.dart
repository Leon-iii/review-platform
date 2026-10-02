import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'llm_profiles_view_model.g.dart';

@riverpod
class LlmProfilesController extends _$LlmProfilesController {
  Future<bool> Function()? _exitHandler;
  Future<bool>? _pendingExit;

  void attachExitHandler(Future<bool> Function() handler) {
    _exitHandler = handler;
  }

  void detachExitHandler(Future<bool> Function() handler) {
    if (_exitHandler == handler) _exitHandler = null;
  }

  Future<bool> prepareToLeave() {
    final handler = _exitHandler;
    if (handler == null) return Future.value(true);
    return _pendingExit ??= _prepareToLeave(handler);
  }

  Future<bool> _prepareToLeave(Future<bool> Function() handler) async {
    try {
      return await handler();
    } finally {
      _pendingExit = null;
    }
  }

  @override
  Future<LlmProfileSettings> build() => _load();

  Future<LlmProfileSettings> _load() async {
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('먼저 설정 화면에서 개인 서버 주소와 접근 토큰을 저장해 주세요.');
    }
    final settings = await ref
        .read(llmProfileApiProvider)
        .getSettings(configuration);
    return settings.forPurposes();
  }

  Future<LlmProfileSettings> save(
    LlmProfileSettings settings, {
    Map<LlmApiKeyProvider, String> apiKeys = const {},
  }) async {
    // Navigation may dispose the form before its final debounced write finishes.
    final keepAlive = ref.keepAlive();
    final credentials = ref.read(syncCredentialsStoreProvider);
    final api = ref.read(llmProfileApiProvider);
    try {
      final configuration = await credentials.readConfiguration();
      if (configuration == null) {
        throw const ValidationFailure('먼저 설정 화면에서 개인 서버 주소와 접근 토큰을 저장해 주세요.');
      }
      final response = await api.updateSettings(
        configuration: configuration,
        settings: settings,
        apiKeys: apiKeys,
      );
      final updated = response.forPurposes();
      if (ref.mounted) state = AsyncData(updated);
      return updated;
    } finally {
      keepAlive.close();
    }
  }

  Future<LlmModelCatalog> loadModels(LlmProviderKind provider) async {
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('먼저 설정 화면에서 개인 서버 주소와 접근 토큰을 저장해 주세요.');
    }
    return ref
        .read(llmProfileApiProvider)
        .getModels(configuration: configuration, provider: provider);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_load);
  }
}
