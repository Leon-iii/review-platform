import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'llm_profiles_view_model.g.dart';

@riverpod
class LlmProfilesController extends _$LlmProfilesController {
  @override
  Future<LlmProfileSettings> build() => _load();

  Future<LlmProfileSettings> _load() async {
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('먼저 설정 화면에서 개인 서버 주소와 접근 토큰을 저장해 주세요.');
    }
    return ref.read(llmProfileApiProvider).getSettings(configuration);
  }

  Future<void> save(LlmProfileSettings settings) async {
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('먼저 설정 화면에서 개인 서버 주소와 접근 토큰을 저장해 주세요.');
    }
    final updated = await ref
        .read(llmProfileApiProvider)
        .updateSettings(configuration: configuration, settings: settings);
    state = AsyncData(updated);
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
