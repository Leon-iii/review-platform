import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/core/server/local_server_startup_coordinator.dart';

void main() {
  test('자동 시작이 활성화되면 Windows 앱 초기화에서 서버를 한 번 시작한다', () async {
    final process = _FakeProcess();
    var launchCount = 0;
    final service = LocalServerService(
      secretStore: _MemorySecretStore(),
      isWindows: true,
      healthCheck: (_) async => launchCount > 0,
      directoryResolver: () async => r'C:\project\server',
      processLauncher:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            launchCount += 1;
            return process;
          },
      accessTokenReader: () async => 'sync-token',
      portAvailabilityCheck: (_) async => true,
    );
    addTearDown(service.dispose);
    final coordinator = LocalServerStartupCoordinator(
      configStore: _MemoryConfigStore(
        const LocalServerConfig(port: 5080, autoStart: true),
      ),
      service: service,
      isWindows: true,
    );

    await coordinator.initialize();
    await coordinator.initialize();

    expect(launchCount, 1);
    expect(service.currentState.status, LocalServerStatus.running);
  });

  test('자동 시작이 꺼져 있으면 상태만 확인하고 프로세스를 실행하지 않는다', () async {
    var launchCount = 0;
    final service = LocalServerService(
      secretStore: _MemorySecretStore(),
      isWindows: true,
      healthCheck: (_) async => false,
      processLauncher:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            launchCount += 1;
            return _FakeProcess();
          },
    );
    addTearDown(service.dispose);
    final coordinator = LocalServerStartupCoordinator(
      configStore: _MemoryConfigStore(
        const LocalServerConfig(port: 5080, autoStart: false),
      ),
      service: service,
      isWindows: true,
    );

    await coordinator.initialize();

    expect(launchCount, 0);
    expect(service.currentState.status, LocalServerStatus.stopped);
  });

  test('외부 서버가 이미 실행 중이면 자동 시작 프로세스를 추가하지 않는다', () async {
    var launchCount = 0;
    final service = LocalServerService(
      secretStore: _MemorySecretStore(),
      isWindows: true,
      healthCheck: (_) async => true,
      processLauncher:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            launchCount += 1;
            return _FakeProcess();
          },
    );
    addTearDown(service.dispose);
    final coordinator = LocalServerStartupCoordinator(
      configStore: _MemoryConfigStore(
        const LocalServerConfig(port: 5080, autoStart: true),
      ),
      service: service,
      isWindows: true,
    );

    await coordinator.initialize();

    expect(launchCount, 0);
    expect(service.currentState.status, LocalServerStatus.externalRunning);
  });

  test('Windows가 아니면 설정을 읽거나 서버를 확인하지 않는다', () async {
    final store = _MemoryConfigStore(
      const LocalServerConfig(port: 5080, autoStart: true),
    );
    final service = LocalServerService(
      secretStore: _MemorySecretStore(),
      isWindows: false,
    );
    addTearDown(service.dispose);
    final coordinator = LocalServerStartupCoordinator(
      configStore: store,
      service: service,
      isWindows: false,
    );

    await coordinator.initialize();

    expect(store.readCount, 0);
    expect(service.currentState.status, LocalServerStatus.stopped);
  });
}

class _MemoryConfigStore implements LocalServerConfigStore {
  _MemoryConfigStore(this.value);

  final LocalServerConfig value;
  int readCount = 0;

  @override
  Future<LocalServerConfig> read() async {
    readCount += 1;
    return value;
  }

  @override
  Future<void> write(LocalServerConfig config) async {}
}

class _MemorySecretStore implements LocalServerSecretStore {
  @override
  Future<String?> read(LocalLlmProvider provider) async => null;

  @override
  Future<void> write(LocalLlmProvider provider, String value) async {}
}

class _FakeProcess implements ManagedServerProcess {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exitCode = Completer<int>();

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill() {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    return true;
  }
}
