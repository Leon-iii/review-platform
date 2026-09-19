import 'dart:async';

import 'package:flutter/material.dart';
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
  final _modelController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _portController = TextEditingController();
  final _logScrollController = ScrollController();
  LocalLlmProvider _provider = LocalLlmProvider.ollama;
  bool _obscureApiKey = true;
  bool _settingsApplied = false;

  @override
  void dispose() {
    _modelController.dispose();
    _apiKeyController.dispose();
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
        _provider = state.config.provider;
        _modelController.text = state.config.model;
        _portController.text = state.config.port.toString();
        setState(() {});
      });
    }

    final status = state.runtime.status;
    final isBusy =
        state.isSavingSettings ||
        status == LocalServerStatus.starting ||
        status == LocalServerStatus.stopping;
    final canStart =
        !state.isLoadingSettings &&
        !isBusy &&
        status != LocalServerStatus.running;
    final canStop =
        status == LocalServerStatus.running ||
        status == LocalServerStatus.starting;

    return Scaffold(
      key: const Key('local-server-view'),
      appBar: AppBar(title: const Text('Local Server')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
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
                        padding: const EdgeInsets.all(20),
                        child: state.isLoadingSettings
                            ? const Center(child: CircularProgressIndicator())
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  DropdownButtonFormField<LocalLlmProvider>(
                                    key: const Key(
                                      'local-server-provider-field',
                                    ),
                                    initialValue: _provider,
                                    decoration: const InputDecoration(
                                      labelText: 'LLM Provider',
                                      border: OutlineInputBorder(),
                                    ),
                                    items:
                                        const [
                                              LocalLlmProvider.ollama,
                                              LocalLlmProvider.openAi,
                                            ]
                                            .map(
                                              (provider) => DropdownMenuItem(
                                                value: provider,
                                                child: Text(
                                                  provider.displayName,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                    onChanged: isBusy
                                        ? null
                                        : (value) {
                                            if (value == null) return;
                                            setState(() {
                                              final previous = _provider;
                                              _provider = value;
                                              if (previous != value) {
                                                _modelController.text =
                                                    value ==
                                                        LocalLlmProvider.ollama
                                                    ? 'qwen3:8b'
                                                    : 'gpt-4o-mini';
                                              }
                                            });
                                            unawaited(
                                              ref
                                                  .read(
                                                    localServerControllerProvider
                                                        .notifier,
                                                  )
                                                  .selectProvider(value),
                                            );
                                          },
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    key: const Key('local-server-model-field'),
                                    controller: _modelController,
                                    enabled:
                                        !isBusy && _provider.requiresApiKey,
                                    decoration: InputDecoration(
                                      labelText: 'Model',
                                      hintText:
                                          _provider == LocalLlmProvider.ollama
                                          ? 'qwen3:8b'
                                          : 'gpt-4o-mini',
                                      border: const OutlineInputBorder(),
                                    ),
                                    validator: (value) =>
                                        value == null || value.trim().isEmpty
                                        ? 'Model을 입력해 주세요.'
                                        : null,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    key: const Key(
                                      'local-server-api-key-field',
                                    ),
                                    controller: _apiKeyController,
                                    enabled: !isBusy,
                                    obscureText: _obscureApiKey,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: InputDecoration(
                                      labelText: 'API Key',
                                      hintText: !_provider.requiresApiKey
                                          ? 'Ollama에는 API Key가 필요하지 않습니다.'
                                          : state.hasApiKey
                                          ? '비워 두면 저장된 키 유지'
                                          : 'Provider API Key',
                                      border: const OutlineInputBorder(),
                                      suffixIcon: IconButton(
                                        tooltip: _obscureApiKey
                                            ? 'API Key 표시'
                                            : 'API Key 숨기기',
                                        onPressed: _provider.requiresApiKey
                                            ? () => setState(
                                                () => _obscureApiKey =
                                                    !_obscureApiKey,
                                              )
                                            : null,
                                        icon: Icon(
                                          _obscureApiKey
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                      ),
                                    ),
                                    validator: (value) {
                                      if (_provider.requiresApiKey &&
                                          (value ?? '').trim().isEmpty &&
                                          !state.hasApiKey) {
                                        return 'API Key를 입력해 주세요.';
                                      }
                                      return null;
                                    },
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
                                      border: OutlineInputBorder(),
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
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
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
                                        icon:
                                            status == LocalServerStatus.starting
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
                                        label: const Text('Start Server'),
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
                            style: Theme.of(context).textTheme.titleLarge,
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
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
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
      provider: _provider,
      model: _modelController.text.trim(),
      port: int.parse(_portController.text.trim()),
    );
  }

  Future<void> _save() async {
    final config = _readConfig();
    if (config == null) return;
    try {
      await ref
          .read(localServerControllerProvider.notifier)
          .saveSettings(config: config, apiKey: _apiKeyController.text);
      if (!mounted) return;
      _apiKeyController.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('로컬 서버 설정을 저장했어요.')));
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _start() async {
    final config = _readConfig();
    if (config == null) return;
    try {
      await ref
          .read(localServerControllerProvider.notifier)
          .start(config: config, apiKey: _apiKeyController.text);
      if (!mounted) return;
      _apiKeyController.clear();
    } catch (error) {
      _showError(error);
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      LocalServerStatus.running => Colors.green,
      LocalServerStatus.starting || LocalServerStatus.stopping => Colors.orange,
      LocalServerStatus.error => Theme.of(context).colorScheme.error,
      LocalServerStatus.stopped => Theme.of(context).colorScheme.outline,
    };
    final label = switch (status) {
      LocalServerStatus.stopped => 'Stopped',
      LocalServerStatus.starting => 'Starting...',
      LocalServerStatus.running => 'Running',
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
                Text(
                  label,
                  key: const Key('local-server-status'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText('Local: $address'),
            if (error case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (exitCode case final code?) Text('Exit code: $code'),
          ],
        ),
      ),
    );
  }
}
