import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';

class LocalServerStartupCoordinator {
  LocalServerStartupCoordinator({
    required this.configStore,
    required this.service,
    required this.isWindows,
  });

  final LocalServerConfigStore configStore;
  final LocalServerService service;
  final bool isWindows;
  Future<void>? _initialization;
  bool _canceled = false;

  Future<void> initialize() => _initialization ??= _initialize();

  void cancel() => _canceled = true;

  Future<void> _initialize() async {
    if (!isWindows) return;
    try {
      final config = await configStore.read();
      if (_canceled) return;
      final alreadyRunning = await service.refreshStatus(config);
      if (_canceled) return;
      if (config.autoStart && !alreadyRunning) {
        await service.start(config);
      }
    } on AppFailure {
      // LocalServerService already exposes an actionable runtime error.
    } catch (_) {
      // Startup must never prevent the Flutter client from opening.
    }
  }
}
