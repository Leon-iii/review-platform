import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:review_platform/core/errors/app_failure.dart';

String appErrorMessage(
  Object error, {
  String fallback = '요청을 처리하지 못했어요. 다시 시도해 주세요.',
}) => switch (error) {
  AppFailure failure => failure.message,
  String message => message,
  _ => fallback,
};

class AppErrorEvent {
  const AppErrorEvent(this.message, this.title);
  final String message;
  final String title;
}

final appErrorReporterProvider =
    NotifierProvider<AppErrorReporter, List<AppErrorEvent>>(
      AppErrorReporter.new,
    );

class AppErrorReporter extends Notifier<List<AppErrorEvent>> {
  bool _active = false;
  @override
  List<AppErrorEvent> build() {
    _active = true;
    ref.onDispose(() => _active = false);
    return [];
  }

  void report(Object error, {String title = '오류가 발생했어요', String? fallback}) {
    if (!_active) return;
    final message = appErrorMessage(
      error,
      fallback: fallback ?? '요청을 처리하지 못했어요. 다시 시도해 주세요.',
    );
    if (state.any(
      (event) => event.message == message && event.title == title,
    )) {
      return;
    }
    state = [...state, AppErrorEvent(message, title)];
  }

  void acknowledge(AppErrorEvent event) {
    state = state.where((item) => !identical(item, event)).toList();
  }
}
