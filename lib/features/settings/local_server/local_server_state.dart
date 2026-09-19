import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';

class LocalServerState {
  const LocalServerState({
    this.config = const LocalServerConfig.defaults(),
    this.runtime = const LocalServerRuntimeState(),
    this.isLoadingSettings = true,
    this.isSavingSettings = false,
    this.hasApiKey = false,
    this.settingsError,
  });

  final LocalServerConfig config;
  final LocalServerRuntimeState runtime;
  final bool isLoadingSettings;
  final bool isSavingSettings;
  final bool hasApiKey;
  final String? settingsError;

  LocalServerState copyWith({
    LocalServerConfig? config,
    LocalServerRuntimeState? runtime,
    bool? isLoadingSettings,
    bool? isSavingSettings,
    bool? hasApiKey,
    String? settingsError,
    bool clearSettingsError = false,
  }) {
    return LocalServerState(
      config: config ?? this.config,
      runtime: runtime ?? this.runtime,
      isLoadingSettings: isLoadingSettings ?? this.isLoadingSettings,
      isSavingSettings: isSavingSettings ?? this.isSavingSettings,
      hasApiKey: hasApiKey ?? this.hasApiKey,
      settingsError: clearSettingsError
          ? null
          : settingsError ?? this.settingsError,
    );
  }
}
