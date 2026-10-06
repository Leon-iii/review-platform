import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';
import 'package:review_platform/shared/widgets/app_action_group.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/features/settings/local_server/local_server_view_model.dart';

class LocalServerView extends ConsumerStatefulWidget {
  const LocalServerView({super.key});

  @override
  ConsumerState<LocalServerView> createState() => _LocalServerViewState();
}

class _LocalServerViewState extends ConsumerState<LocalServerView> {
  final _formKey = GlobalKey<FormState>();
  final _portController = TextEditingController();
  final _logScrollController = ScrollController();
  bool _autoStart = true;
  bool _startRequested = false;
  bool _settingsApplied = false;

  @override
  void dispose() {
    _portController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localServerControllerProvider);
    ref.listen(
      localServerControllerProvider.select(
        (value) => value.runtime.logs.length,
      ),
      (_, _) => _scrollLogsToBottom(),
    );
    if (!state.isLoadingSettings && !_settingsApplied) {
      _settingsApplied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _portController.text = state.config.port.toString();
        _autoStart = state.config.autoStart;
        setState(() {});
      });
    }

    final status = state.runtime.status;
    final isStarting = _startRequested || status == LocalServerStatus.starting;
    final isBusy =
        _startRequested ||
        state.isSavingSettings ||
        status == LocalServerStatus.starting ||
        status == LocalServerStatus.stopping;
    final canStart =
        !state.isLoadingSettings &&
        !isBusy &&
        status != LocalServerStatus.running &&
        status != LocalServerStatus.externalRunning;
    final canStop =
        status == LocalServerStatus.running ||
        status == LocalServerStatus.starting;

    return Scaffold(
      key: const Key('local-server-view'),
      appBar: AppPageBar(
        fallback: '/settings',
        title: const Text('Local Server'),
      ),
      body: ListView(
        padding: AppLayout.pagePadding(context),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.readingWidth,
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Review Platform Server',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Windows 앱에서 개인용 ASP.NET 서버를 실행합니다.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: state.isLoadingSettings
                            ? const Center(child: CircularProgressIndicator())
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    'Provider, 모델, API Key는 용도별 AI 설정 화면에서 '
                                    '서버 실행 중에도 변경할 수 있습니다.',
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    key: const Key('local-server-port-field'),
                                    controller: _portController,
                                    enabled: !isBusy,
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) => setState(() {}),
                                    decoration: const InputDecoration(
                                      labelText: 'Server Port',
                                      hintText: '5080',
                                    ),
                                    validator: (value) {
                                      final port = int.tryParse(
                                        (value ?? '').trim(),
                                      );
                                      if (port == null ||
                                          port < 1 ||
                                          port > 65535) {
                                        return '1~65535 사이의 Port를 입력해 주세요.';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  SwitchListTile(
                                    key: const Key(
                                      'local-server-auto-start-switch',
                                    ),
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('앱 실행 시 서버 자동 시작'),
                                    subtitle: const Text(
                                      '다음 Windows 앱 실행부터 적용됩니다.',
                                    ),
                                    value: _autoStart,
                                    onChanged: state.isSavingSettings
                                        ? null
                                        : (value) => setState(
                                            () => _autoStart = value,
                                          ),
                                  ),
                                  const SizedBox(height: 22),
                                  _StatusPanel(
                                    status: status,
                                    address:
                                        'http://127.0.0.1:${_portController.text.trim().isEmpty ? state.config.port : _portController.text.trim()}',
                                    error:
                                        state.runtime.lastError ??
                                        state.settingsError,
                                    exitCode: state.runtime.processExitCode,
                                  ),
                                  const SizedBox(height: 18),
                                  AppActionGroup(
                                    children: [
                                      OutlinedButton.icon(
                                        key: const Key(
                                          'save-local-server-settings-button',
                                        ),
                                        onPressed: isBusy ? null : _save,
                                        icon: const Icon(Icons.save_outlined),
                                        label: const Text('설정 저장'),
                                      ),
                                      FilledButton.icon(
                                        key: const Key(
                                          'start-local-server-button',
                                        ),
                                        onPressed: canStart ? _start : null,
                                        icon: isStarting
                                            ? const SizedBox.square(
                                                dimension: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.play_arrow_rounded,
                                              ),
                                        label: Text(
                                          isStarting
                                              ? 'Starting...'
                                              : 'Start Server',
                                        ),
                                      ),
                                      OutlinedButton.icon(
                                        key: const Key(
                                          'stop-local-server-button',
                                        ),
                                        onPressed: canStop ? _stop : null,
                                        icon: const Icon(Icons.stop_rounded),
                                        label: const Text('Stop Server'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Server Logs',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: state.runtime.logs.isEmpty
                              ? null
                              : () => ref
                                    .read(
                                      localServerControllerProvider.notifier,
                                    )
                                    .clearLogs(),
                          icon: const Icon(Icons.clear_all_rounded),
                          label: const Text('Clear'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      key: const Key('local-server-log-view'),
                      height: 300,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Scrollbar(
                        controller: _logScrollController,
                        child: SingleChildScrollView(
                          controller: _logScrollController,
                          child: SelectableText(
                            state.runtime.logs.isEmpty
                                ? '서버 로그가 여기에 표시됩니다.'
                                : state.runtime.logs.join('\n'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  LocalServerConfig? _readConfig() {
    if (!(_formKey.currentState?.validate() ?? false)) return null;
    return LocalServerConfig(
      port: int.parse(_portController.text.trim()),
      autoStart: _autoStart,
    );
  }

  Future<void> _save() async {
    final config = _readConfig();
    if (config == null) return;
    try {
      await ref
          .read(localServerControllerProvider.notifier)
          .saveSettings(config: config, apiKey: '');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('로컬 서버 설정을 저장했어요.')));
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _start() async {
    if (_startRequested) return;
    final config = _readConfig();
    if (config == null) return;
    setState(() => _startRequested = true);
    try {
      await ref
          .read(localServerControllerProvider.notifier)
          .start(config: config, apiKey: '');
      if (!mounted) return;
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() => _startRequested = false);
      }
    }
  }

  Future<void> _stop() async {
    try {
      await ref.read(localServerControllerProvider.notifier).stop();
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = error is AppFailure
        ? error.message
        : '로컬 서버 작업을 완료하지 못했어요.';
    showAppError(context, message);
  }

  void _scrollLogsToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_logScrollController.hasClients) return;
      _logScrollController.animateTo(
        _logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.status,
    required this.address,
    required this.error,
    required this.exitCode,
  });

  final LocalServerStatus status;
  final String address;
  final String? error;
  final int? exitCode;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      LocalServerStatus.running ||
      LocalServerStatus.externalRunning => Colors.green,
      LocalServerStatus.starting || LocalServerStatus.stopping => Colors.orange,
      LocalServerStatus.error => Theme.of(context).colorScheme.error,
      LocalServerStatus.stopped => Theme.of(context).colorScheme.outline,
    };
    final label = switch (status) {
      LocalServerStatus.stopped => 'Stopped',
      LocalServerStatus.starting => 'Starting...',
      LocalServerStatus.running => 'Running',
      LocalServerStatus.externalRunning => 'Running (external)',
      LocalServerStatus.stopping => 'Stopping...',
      LocalServerStatus.error => 'Error',
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, color: color, size: 13),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    key: const Key('local-server-status'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText('Local: $address'),
            if (status == LocalServerStatus.externalRunning) ...[
              const SizedBox(height: 6),
              const Text('외부에서 실행한 서버입니다. 이 앱에서는 종료하지 않습니다.'),
            ],
            if (error case final message?) ...[
              const SizedBox(height: 8),
              AppErrorNotice(error: message),
            ],
            if (exitCode case final code?) Text('Exit code: $code'),
          ],
        ),
      ),
    );
  }
}
