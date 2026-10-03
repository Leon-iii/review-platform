import 'dart:io';

import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';

class LocalServerStartupCoordinator {
  LocalServerStartupCoordinator({
    required this.configStore,
    required this.service,
    required this.isWindows,
    Future<bool> Function(String host)? isLocalHost,
  }) : _isLocalHost = isLocalHost ?? _isComputerHost;

  final LocalServerConfigStore configStore;
  final LocalServerService service;
  final bool isWindows;
  final Future<bool> Function(String host) _isLocalHost;
  Future<void>? _initialization;
  bool _canceled = false;

  Future<void> initialize() => _initialization ??= _initialize();

  // Background document polling and sync must not race our own server startup. Remote
  // servers and Android are independent of the Windows process lifecycle.
  Future<bool> canPoll(String serverUrl) async {
    if (!isWindows) return true;
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.scheme != 'http' || !await _isLocalHost(uri.host)) {
      return true;
    }
    final config = await configStore.read();
    if (uri.port != config.port) return true;
    await initialize();
    if (_canceled) return false;
    final status = service.currentState.status;
    if (status == LocalServerStatus.starting ||
        status == LocalServerStatus.stopping) {
      return false;
    }
    if (status == LocalServerStatus.running ||
        status == LocalServerStatus.externalRunning) {
      return true;
    }
    // Also discover a server started externally after app initialization, or
    // one that has since recovered. Do not launch a process on every poll.
    await service.refreshStatus(config);
    return service.currentState.status == LocalServerStatus.running ||
        service.currentState.status == LocalServerStatus.externalRunning;
  }

  void cancel() => _canceled = true;

  static Future<bool> _isComputerHost(String host) async {
    if (host == 'localhost' ||
        host.toLowerCase() == Platform.localHostname.toLowerCase()) {
      return true;
    }
    final address = InternetAddress.tryParse(host);
    if (address == null) return false; // Do not resolve unrelated remote hosts.
    if (address.isLoopback) return true;
    try {
      final interfaces = await NetworkInterface.list(
        type: address.type,
        includeLoopback: true,
      );
      return interfaces.any(
        (network) =>
            network.addresses.any((local) => local.address == address.address),
      );
    } on SocketException {
      return false;
    }
  }

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
