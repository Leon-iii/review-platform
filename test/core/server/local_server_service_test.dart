import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';

void main() {
  const config = LocalServerConfig(port: 5080, autoStart: false);

  test('health check 성공 후에만 running 상태가 된다', () async {
    final process = _FakeProcess();
    late Map<String, String> capturedEnvironment;
    late String capturedWorkingDirectory;
    var healthCalls = 0;
    final service = LocalServerService(
      secretStore: _MemorySecretStore('secret-value'),
      isWindows: true,
      directoryResolver: () async => r'C:\project\server',
      processLauncher:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            expect(executable, 'dotnet');
            expect(arguments, ['run']);
            capturedWorkingDirectory = workingDirectory;
            capturedEnvironment = environment;
            return process;
          },
      healthCheck: (uri) async {
        healthCalls += 1;
        expect(uri.toString(), 'http://127.0.0.1:5080/health');
        return healthCalls > 1;
      },
      accessTokenReader: () async => 'sync-token',
      portAvailabilityCheck: (_) async => true,
    );
    addTearDown(service.dispose);

    await service.start(config);

    expect(healthCalls, 2);
    expect(service.currentState.status, LocalServerStatus.running);
    expect(capturedWorkingDirectory, r'C:\project\server');
    expect(capturedEnvironment, isNot(contains('Llm__Provider')));
    expect(capturedEnvironment, isNot(contains('Llm__Model')));
    expect(capturedEnvironment['OPENAI_API_KEY'], 'secret-value');
    expect(capturedEnvironment['Sync__AccessToken'], 'sync-token');
    expect(capturedEnvironment['ASPNETCORE_URLS'], 'http://0.0.0.0:5080');
    expect(
      service.currentState.logs.join('\n'),
      isNot(contains('secret-value')),
    );
  });

  test('stop은 프로세스를 종료하고 stopped 상태로 전환한다', () async {
    final process = _FakeProcess();
    final service = _serviceFor(process);
    addTearDown(service.dispose);
    await service.start(config);

    await service.stop();

    expect(process.wasKilled, isTrue);
    expect(service.currentState.status, LocalServerStatus.stopped);
  });

  test('사용자 요청 없이 프로세스가 종료되면 error 상태가 된다', () async {
    final process = _FakeProcess();
    final service = _serviceFor(process);
    addTearDown(service.dispose);
    await service.start(config);

    process.exit(17);
    await Future<void>.delayed(Duration.zero);

    expect(service.currentState.status, LocalServerStatus.error);
    expect(service.currentState.processExitCode, 17);
    expect(service.currentState.lastError, contains('예기치 않게'));
  });

  test('로그는 최근 1000줄만 유지한다', () async {
    final process = _FakeProcess();
    final service = _serviceFor(process);
    addTearDown(service.dispose);
    await service.start(config);

    for (var index = 0; index < 1005; index += 1) {
      process.writeStdout('line-$index\n');
    }
    await Future<void>.delayed(Duration.zero);

    expect(service.currentState.logs, hasLength(1000));
    expect(service.currentState.logs.first, 'line-5');
    expect(service.currentState.logs.last, 'line-1004');
  });

  test('사용 중인 port는 프로세스를 실행하기 전에 안내한다', () async {
    final service = LocalServerService(
      secretStore: _MemorySecretStore('secret-value'),
      isWindows: true,
      healthCheck: (_) async => false,
      accessTokenReader: () async => 'sync-token',
      portAvailabilityCheck: (_) async => false,
    );
    addTearDown(service.dispose);

    await expectLater(service.start(config), throwsA(isA<ValidationFailure>()));

    expect(service.currentState.status, LocalServerStatus.error);
    expect(service.currentState.lastError, contains('Port 5080'));
    expect(service.currentState.lastError, contains('이미 사용 중'));
  });

  test('이미 응답하는 외부 서버는 실행하지 않고 별도 상태로 표시한다', () async {
    var launchCount = 0;
    final service = LocalServerService(
      secretStore: _MemorySecretStore(null),
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

    await service.start(config);
    await service.stop();

    expect(launchCount, 0);
    expect(service.currentState.status, LocalServerStatus.externalRunning);
  });

  test('관리 서버 시작 전 접근 토큰이 없으면 명확한 오류를 표시한다', () async {
    final service = LocalServerService(
      secretStore: _MemorySecretStore(null),
      isWindows: true,
      healthCheck: (_) async => false,
      accessTokenReader: () async => null,
      portAvailabilityCheck: (_) async => true,
    );
    addTearDown(service.dispose);

    await expectLater(service.start(config), throwsA(isA<ValidationFailure>()));

    expect(service.currentState.status, LocalServerStatus.error);
    expect(service.currentState.lastError, contains('접근 토큰'));
  });
}

LocalServerService _serviceFor(_FakeProcess process) {
  return LocalServerService(
    secretStore: _MemorySecretStore('secret-value'),
    isWindows: true,
    directoryResolver: () async => r'C:\project\server',
    processLauncher: (
      executable,
      arguments, {
      required workingDirectory,
      required environment,
    }) async => process,
    healthCheck: (() {
      var calls = 0;
      return (_) async => ++calls > 1;
    })(),
    accessTokenReader: () async => 'sync-token',
    portAvailabilityCheck: (_) async => true,
  );
}

class _MemorySecretStore implements LocalServerSecretStore {
  _MemorySecretStore(this.value);

  String? value;

  @override
  Future<String?> read(LocalLlmProvider provider) async => value;

  @override
  Future<void> write(LocalLlmProvider provider, String value) async {
    this.value = value;
  }
}

class _FakeProcess implements ManagedServerProcess {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exitCode = Completer<int>();
  bool wasKilled = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill() {
    wasKilled = true;
    exit(0);
    return true;
  }

  void writeStdout(String value) => _stdout.add(value.codeUnits);

  void exit(int code) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}
