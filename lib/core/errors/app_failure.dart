sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message);
}

final class DatabaseFailure extends AppFailure {
  const DatabaseFailure(super.message, {super.cause});
}

final class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message, {super.cause});
}

final class SyncFailure extends AppFailure {
  const SyncFailure(super.message, {super.cause});
}

final class LocalServerFailure extends AppFailure {
  const LocalServerFailure(super.message, {super.cause});
}
