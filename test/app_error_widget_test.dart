import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/errors/app_error_reporter.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

void main() {
  testWidgets(
    '공통 오류는 확인까지 유지되고 복사 가능하며 중복 없이 순서대로 표시한다',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            navigatorKey: key,
            builder: (_, child) =>
                AppErrorHost(navigatorKey: key, child: child!),
            home: const Scaffold(body: Text('화면')),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.text('화면')),
      );
      final reporter = container.read(appErrorReporterProvider.notifier);
      reporter.report(const NetworkFailure('서버 연결 실패'));
      reporter.report(const NetworkFailure('서버 연결 실패'));
      reporter.report('두 번째 오류');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
      expect(find.text('서버 연결 실패'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('오류 복사'));
      expect(copied, contains('서버 연결 실패'));
      await tester.tap(find.byKey(const Key('acknowledge-app-error')));
      await tester.pumpAndSettle();
      expect(find.text('두 번째 오류'), findsOneWidget);
      expect(find.text('서버 연결 실패'), findsNothing);
      await tester.tap(find.byKey(const Key('acknowledge-app-error')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-error-dialog')), findsNothing);
      expect(container.read(appErrorReporterProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('알 수 없는 오류의 내부 내용은 사용자에게 노출하지 않는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppErrorNotice(
            error: Exception('private internals'),
            fallback: '자료를 불러오지 못했어요.',
          ),
        ),
      ),
    );
    expect(find.text('오류가 발생했어요'), findsOneWidget);
    expect(find.text('자료를 불러오지 못했어요.'), findsOneWidget);
    expect(find.textContaining('private internals'), findsNothing);
  });
}
