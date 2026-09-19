import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';

enum LocalServerStatus { stopped, starting, running, stopping, error }

class LocalServerRuntimeState {
  const LocalServerRuntimeState({
    this.status = LocalServerStatus.stopped,
    this.logs = const [],
    this.lastError,
    this.processExitCode,
  });

  final LocalServerStatus status;
  final List<String> logs;
  final String? lastError;
  final int? processExitCode;
}

abstract interface class ManagedServerProcess {
  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  Future<int> get exitCode;

  bool kill();
}

class IoManagedServerProcess implements ManagedServerProcess {
  IoManagedServerProcess(this._process);

  final Process _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill();
}

typedef ServerProcessLauncher = Future<ManagedServerProcess> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
});
typedef ServerHealthCheck = Future<bool> Function(Uri uri);
typedef ServerDirectoryResolver = Future<String> Function();
typedef ServerAccessTokenReader = Future<String?> Function();
typedef ServerPortAvailabilityCheck = Future<bool> Function(int port);

class LocalServerService {
  LocalServerService({
    required this.secretStore,
    ServerProcessLauncher? processLauncher,
    ServerHealthCheck? healthCheck,
    ServerDirectoryResolver? directoryResolver,
    this.accessTokenReader,
    ServerPortAvailabilityCheck? portAvailabilityCheck,
    bool? isWindows,
    this.healthTimeout = const Duration(seconds: 20),
    this.healthInterval = const Duration(milliseconds: 300),
  }) : _processLauncher = processLauncher ?? _startIoProcess,
       _healthCheck = healthCheck ?? _checkHealth,
       _directoryResolver =
           directoryResolver ?? _resolveDevelopmentServerDirectory,
       _portAvailabilityCheck = portAvailabilityCheck ?? _isPortAvailable,
       _isWindows = isWindows ?? Platform.isWindows;

  static const maxLogLines = 1000;

  final LocalServerSecretStore secretStore;
  final ServerProcessLauncher _processLauncher;
  final ServerHealthCheck _healthCheck;
  final ServerDirectoryResolver _directoryResolver;
  final ServerPortAvailabilityCheck _portAvailabilityCheck;
  final ServerAccessTokenReader? accessTokenReader;
  final bool _isWindows;
  final Duration healthTimeout;
  final Duration healthInterval;
  final _states = StreamController<LocalServerRuntimeState>.broadcast();
  final List<String> _logs = [];

  ManagedServerProcess? _process;
  LocalServerStatus _status = LocalServerStatus.stopped;
  String? _lastError;
  int? _processExitCode;
  bool _stopRequested = false;
  bool _disposed = false;
  int _runGeneration = 0;
  int? _activePort;

  Stream<LocalServerRuntimeState> get states => _states.stream;

  LocalServerRuntimeState get currentState => _snapshot();

  Future<void> start(LocalServerConfig config) async {
    if (!_isWindows) {
      throw const ValidationFailure('로컬 서버는 Windows에서만 실행할 수 있어요.');
    }
    if (_process != null ||
        _status == LocalServerStatus.starting ||
        _status == LocalServerStatus.running) {
      throw const ValidationFailure('로컬 서버가 이미 실행 중이에요.');
    }
    _validate(config);

    final apiKey = (await secretStore.read(config.provider))?.trim() ?? '';
    if (config.provider.requiresApiKey && apiKey.isEmpty) {
      throw const ValidationFailure('선택한 Provider의 API Key를 입력해 주세요.');
    }
    if (!await _portAvailabilityCheck(config.port)) {
      final message =
          'Port ${config.port}가 이미 사용 중이에요. 다른 Port를 선택하거나 사용 중인 프로세스를 종료해 주세요.';
      _setError(message);
      throw ValidationFailure(message);
    }

    _stopRequested = false;
    final runGeneration = ++_runGeneration;
    _activePort = config.port;
    _lastError = null;
    _processExitCode = null;
    _setStatus(LocalServerStatus.starting);

    try {
      final serverDirectory = await _directoryResolver();
      final environment = <String, String>{
        ...Platform.environment,
        'Llm__Provider': config.provider.id,
        'Llm__Model': config.model.trim(),
        'ASPNETCORE_URLS': 'http://0.0.0.0:${config.port}',
      };
      if (config.provider.requiresApiKey) {
        environment[config.provider.secretEnvironmentKey] = apiKey;
      }
      final accessToken = (await accessTokenReader?.call())?.trim();
      if (accessToken != null && accessToken.isNotEmpty) {
        environment['Sync__AccessToken'] = accessToken;
      }

      final process = await _processLauncher(
        'dotnet',
        const ['run'],
        workingDirectory: serverDirectory,
        environment: environment,
      );
      if (_stopRequested || runGeneration != _runGeneration) {
        process.kill();
        return;
      }
      _process = process;
      _listenToOutput(process.stdout, isError: false);
      _listenToOutput(process.stderr, isError: true);
      unawaited(_watchExit(process));

      final healthUri = Uri.parse('${config.localAddress}/health');
      final deadline = DateTime.now().add(healthTimeout);
      while (identical(_process, process) &&
          runGeneration == _runGeneration &&
          DateTime.now().isBefore(deadline)) {
        if (await _healthCheck(healthUri)) {
          if (identical(_process, process)) {
            _setStatus(LocalServerStatus.running);
          }
          return;
        }
        await Future<void>.delayed(healthInterval);
      }

      if (_stopRequested || runGeneration != _runGeneration) return;
      if (identical(_process, process)) {
        _stopRequested = true;
        process.kill();
        _process = null;
        _setError(_portAwareMessage(config.port, '서버가 준비 시간 내에 응답하지 않았어요.'));
      } else if (_status != LocalServerStatus.error) {
        _setError(_portAwareMessage(config.port, '서버가 시작 중 종료되었어요.'));
      }
    } on AppFailure {
      rethrow;
    } on ProcessException catch (error) {
      _process = null;
      _setError('dotnet 서버를 시작하지 못했어요: ${error.message}');
      throw LocalServerFailure(_lastError!, cause: error);
    } on FileSystemException catch (error) {
      _process = null;
      _setError('서버 프로젝트를 찾지 못했어요. 개발 프로젝트 위치를 확인해 주세요.');
      throw LocalServerFailure(_lastError!, cause: error);
    } catch (error) {
      _process = null;
      _setError('로컬 서버를 시작하지 못했어요.');
      throw LocalServerFailure(_lastError!, cause: error);
    }
  }

  Future<void> stop() async {
    _runGeneration += 1;
    _stopRequested = true;
    final process = _process;
    if (process == null) {
      if (_status != LocalServerStatus.error) {
        _setStatus(LocalServerStatus.stopped);
      }
      return;
    }

    _setStatus(LocalServerStatus.stopping);
    final killed = process.kill();
    if (!killed) {
      _process = null;
      _setError('서버 프로세스를 종료하지 못했어요.');
      return;
    }

    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (identical(_process, process)) {
        _process = null;
        _setError('서버 종료를 확인하지 못했어요.');
      }
    }
  }

  void clearLogs() {
    _logs.clear();
    _emit();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _states.close();
  }

  void _listenToOutput(Stream<List<int>> stream, {required bool isError}) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog(isError ? '[stderr] $line' : line));
  }

  Future<void> _watchExit(ManagedServerProcess process) async {
    final exitCode = await process.exitCode;
    if (!identical(_process, process)) return;
    _process = null;
    _processExitCode = exitCode;
    if (_stopRequested) {
      _lastError = null;
      _setStatus(LocalServerStatus.stopped);
      return;
    }
    _setError(
      _portAwareMessage(
        _activePort ?? 0,
        '서버가 예기치 않게 종료되었어요. (Exit code: $exitCode)',
      ),
    );
  }

  void _appendLog(String line) {
    if (line.isEmpty) return;
    _logs.add(line);
    if (_logs.length > maxLogLines) {
      _logs.removeRange(0, _logs.length - maxLogLines);
    }
    _emit();
  }

  void _setStatus(LocalServerStatus value) {
    _status = value;
    _emit();
  }

  void _setError(String message) {
    _lastError = message;
    _status = LocalServerStatus.error;
    _emit();
  }

  String _portAwareMessage(int port, String fallback) {
    final recent = _logs
        .skip(_logs.length > 40 ? _logs.length - 40 : 0)
        .join(' ')
        .toLowerCase();
    if (recent.contains('address already in use') ||
        recent.contains('failed to bind') ||
        recent.contains('only one usage of each socket address')) {
      return 'Port $port가 이미 사용 중이에요. 다른 Port를 선택하거나 사용 중인 프로세스를 종료해 주세요.';
    }
    return fallback;
  }

  LocalServerRuntimeState _snapshot() => LocalServerRuntimeState(
    status: _status,
    logs: List.unmodifiable(_logs),
    lastError: _lastError,
    processExitCode: _processExitCode,
  );

  void _emit() {
    if (!_disposed && !_states.isClosed) _states.add(_snapshot());
  }

  static void _validate(LocalServerConfig config) {
    if (config.provider.id.trim().isEmpty) {
      throw const ValidationFailure('LLM Provider를 선택해 주세요.');
    }
    if (config.model.trim().isEmpty) {
      throw const ValidationFailure('LLM Model을 입력해 주세요.');
    }
    if (config.port < 1 || config.port > 65535) {
      throw const ValidationFailure('Port는 1~65535 사이여야 해요.');
    }
  }

  static Future<ManagedServerProcess> _startIoProcess(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
    return IoManagedServerProcess(process);
  }

  static Future<bool> _checkHealth(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _isPortAvailable(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      await socket.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  static Future<String> _resolveDevelopmentServerDirectory() async {
    final roots = <Directory>{
      Directory.current.absolute,
      File(Platform.resolvedExecutable).parent.absolute,
    };
    for (final root in roots) {
      Directory? current = root;
      while (current != null) {
        final candidate = Directory(
          '${current.path}${Platform.pathSeparator}server${Platform.pathSeparator}ReviewPlatform.Server',
        );
        final projectFile = File(
          '${candidate.path}${Platform.pathSeparator}ReviewPlatform.Server.csproj',
        );
        if (await projectFile.exists()) return candidate.path;
        final parent = current.parent;
        current = parent.path == current.path ? null : parent;
      }
    }
    throw const FileSystemException('ReviewPlatform.Server.csproj not found');
  }
}
