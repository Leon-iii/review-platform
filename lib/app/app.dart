import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/domain/services/automatic_sync_controller.dart';

class ReviewApp extends ConsumerStatefulWidget {
  const ReviewApp({super.key});

  @override
  ConsumerState<ReviewApp> createState() => _ReviewAppState();
}

class _ReviewAppState extends ConsumerState<ReviewApp>
    with WidgetsBindingObserver {
  late final AutomaticSyncController _automaticSyncController;
  LocalServerService? _localServerService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _automaticSyncController = ref.read(automaticSyncControllerProvider);
    unawaited(_automaticSyncController.start());
    if (ref.read(isWindowsPlatformProvider)) {
      _localServerService = ref.read(localServerServiceProvider);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_automaticSyncController.onForeground());
    } else if (state == AppLifecycleState.detached) {
      unawaited(_localServerService?.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_localServerService?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: '복습 노트',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
