import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/sync_status.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'settings_view_model.g.dart';

@riverpod
Stream<SyncStatus> syncStatus(Ref ref) {
  return ref.watch(syncRepositoryProvider).watchStatus();
}

@riverpod
Future<SyncSettings> syncSettings(Ref ref) {
  return ref.watch(syncCredentialsStoreProvider).readSettings();
}

@riverpod
class ManualSync extends _$ManualSync {
  @override
  FutureOr<void> build() {}

  Future<void> saveSettings({
    required String serverUrl,
    required String accessToken,
  }) async {
    final normalizedUrl = _validateServerUrl(serverUrl);
    final current = await ref.read(syncSettingsProvider.future);
    if (accessToken.trim().isEmpty && !current.hasAccessToken) {
      throw const ValidationFailure('서버 접근 토큰을 입력해 주세요.');
    }
    await ref
        .read(syncCredentialsStoreProvider)
        .save(
          serverUrl: normalizedUrl,
          accessToken: accessToken.trim().isEmpty ? null : accessToken.trim(),
        );
    ref.invalidate(syncSettingsProvider);
    ref.read(automaticSyncControllerProvider).onConfigurationChanged();
  }

  Future<SyncRunResult> synchronize() async {
    state = const AsyncLoading();
    try {
      final result = await ref.read(syncCoordinatorProvider).synchronize();
      state = const AsyncData(null);
      return result;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  String _validateServerUrl(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const ValidationFailure('http 또는 https 서버 주소를 입력해 주세요.');
    }
    return normalized;
  }
}
