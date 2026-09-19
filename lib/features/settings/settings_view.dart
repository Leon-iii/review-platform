import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/sync_status.dart';
import 'package:review_platform/features/settings/settings_view_model.dart';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncStatus = ref.watch(syncStatusProvider);
    final settings = ref.watch(syncSettingsProvider);
    final isWindows = ref.watch(isWindowsPlatformProvider);

    return Scaffold(
      key: const Key('settings-view'),
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('동기화', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: settings.when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, stackTrace) => _ErrorText(error: error),
                        data: (value) => syncStatus.when(
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (error, stackTrace) =>
                              _ErrorText(error: error),
                          data: (status) => _SyncForm(
                            key: ValueKey(
                              '${value.serverUrl}:${value.hasAccessToken}',
                            ),
                            initialSettings: value,
                            status: status,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isWindows) ...[
                    const SizedBox(height: 28),
                    Text(
                      '로컬 서버',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: ListTile(
                        key: const Key('local-server-settings-tile'),
                        leading: const Icon(Icons.dns_rounded),
                        title: const Text('Local Server'),
                        subtitle: const Text(
                          '이 Windows PC에서 개인 서버를 시작하고 관리합니다.',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.go(AppRoutes.localServer),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Text('화면', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.brightness_auto_rounded),
                      title: Text('테마'),
                      subtitle: Text('시스템 설정을 따릅니다.'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncForm extends ConsumerStatefulWidget {
  const _SyncForm({
    required this.initialSettings,
    required this.status,
    super.key,
  });

  final SyncSettings initialSettings;
  final SyncStatus status;

  @override
  ConsumerState<_SyncForm> createState() => _SyncFormState();
}

class _SyncFormState extends ConsumerState<_SyncForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: widget.initialSettings.serverUrl,
    );
    _tokenController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(manualSyncProvider);
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_queue_rounded),
            title: Text(
              widget.initialSettings.serverUrl.isEmpty
                  ? '개인 서버 설정 필요'
                  : '개인 서버 연결 설정됨',
            ),
            subtitle: Text(_statusText(widget.status)),
            trailing: Chip(label: Text('대기 ${widget.status.pendingCount}건')),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('sync-server-url-field'),
            controller: _urlController,
            enabled: !sync.isLoading,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '서버 주소',
              hintText: 'http://192.168.0.10:5080',
              border: OutlineInputBorder(),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? '서버 주소를 입력해 주세요.'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('sync-token-field'),
            controller: _tokenController,
            enabled: !sync.isLoading,
            obscureText: _obscureToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '접근 토큰',
              hintText: widget.initialSettings.hasAccessToken
                  ? '비워 두면 저장된 토큰 유지'
                  : '서버와 동일한 토큰',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscureToken ? '토큰 표시' : '토큰 숨기기',
                onPressed: () => setState(() => _obscureToken = !_obscureToken),
                icon: Icon(
                  _obscureToken
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          if (_urlController.text.trim().startsWith('http://')) ...[
            const SizedBox(height: 10),
            Text(
              'HTTP는 신뢰할 수 있는 개인 네트워크나 VPN에서만 사용하세요.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (widget.status.lastError case final error?) ...[
            const SizedBox(height: 12),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: sync.isLoading ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('설정 저장'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('manual-sync-button'),
                  onPressed: sync.isLoading ? null : _synchronize,
                  icon: sync.isLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                  label: Text(sync.isLoading ? '동기화 중...' : '수동 동기화'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusText(SyncStatus status) {
    final lastSyncedAt = status.lastSyncedAt;
    if (lastSyncedAt == null) return '아직 동기화하지 않았어요.';
    final local = lastSyncedAt.toLocal();
    final date =
        '${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '마지막 동기화 $date $time · revision ${status.lastPulledRevision}';
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      await ref
          .read(manualSyncProvider.notifier)
          .saveSettings(
            serverUrl: _urlController.text,
            accessToken: _tokenController.text,
          );
      if (!mounted) return;
      _tokenController.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('동기화 설정을 저장했어요.')));
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _synchronize() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      await ref
          .read(manualSyncProvider.notifier)
          .saveSettings(
            serverUrl: _urlController.text,
            accessToken: _tokenController.text,
          );
      final result = await ref.read(manualSyncProvider.notifier).synchronize();
      if (!mounted) return;
      _tokenController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '동기화 완료: 업로드 ${result.pushedCount}건, 다운로드 ${result.pulledCount}건',
          ),
        ),
      );
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = error is AppFailure ? error.message : '작업을 완료하지 못했어요.';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Text(
      error is AppFailure ? (error as AppFailure).message : '설정을 불러오지 못했어요.',
    );
  }
}
