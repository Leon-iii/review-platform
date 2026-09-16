import 'dart:async';

import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/domain/models/sync_status.dart';
import 'package:review_platform/domain/services/sync_coordinator.dart';

/// Runs best-effort synchronization for application lifecycle and local changes.
///
/// The local database remains the source of truth. Automatic failures are saved
/// by [SyncCoordinator] and deliberately do not escape into the Flutter zone.
class AutomaticSyncController {
  AutomaticSyncController(
    this._credentialsStore,
    this._syncCoordinator,
    this._statusStream, {
    this.debounceDuration = const Duration(seconds: 3),
    this.periodicInterval = const Duration(minutes: 15),
  });

  final SyncCredentialsStore _credentialsStore;
  final SyncCoordinator _syncCoordinator;
  final Stream<SyncStatus> _statusStream;
  final Duration debounceDuration;
  final Duration periodicInterval;

  StreamSubscription<SyncStatus>? _statusSubscription;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  Future<void>? _activeRun;
  bool _started = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _statusSubscription = _statusStream.listen(_handleStatus, onError: (_) {});
    _periodicTimer = Timer.periodic(periodicInterval, (_) => _runBestEffort());
    await _runBestEffort();
  }

  Future<void> onForeground() => _runBestEffort();

  void onConfigurationChanged() {
    _schedule(const Duration(milliseconds: 1));
  }

  void _handleStatus(SyncStatus status) {
    if (status.pendingCount == 0) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      return;
    }
    _schedule(debounceDuration);
  }

  void _schedule(Duration delay) {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, _runBestEffort);
  }

  Future<void> _runBestEffort() {
    if (_disposed) return Future.value();
    final activeRun = _activeRun;
    if (activeRun != null) return activeRun;

    late final Future<void> guardedRun;
    guardedRun = _performBestEffort().whenComplete(() {
      if (identical(_activeRun, guardedRun)) {
        _activeRun = null;
      }
    });
    _activeRun = guardedRun;
    return guardedRun;
  }

  Future<void> _performBestEffort() async {
    try {
      final configuration = await _credentialsStore.readConfiguration();
      if (configuration == null || _disposed) return;
      await _syncCoordinator.synchronize();
    } catch (_) {
      // The coordinator persists a user-visible error. Automatic sync should
      // never surface an unhandled asynchronous exception.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    final cancellation = _statusSubscription?.cancel();
    _statusSubscription = null;
    if (cancellation != null) {
      unawaited(cancellation.catchError((Object _) {}));
    }
    await _activeRun;
  }
}
