import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/features/settings/llm_profiles/llm_profiles_view_model.dart';
import 'package:uuid/uuid.dart';

class LlmProfilesView extends ConsumerWidget {
  const LlmProfilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(llmProfilesControllerProvider);
    return Scaffold(
      key: const Key('llm-profiles-view'),
      appBar: AppBar(title: const Text('LLM 프로필')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _LoadError(
          error: error,
          onRetry: () =>
              ref.read(llmProfilesControllerProvider.notifier).reload(),
        ),
        data: (value) => _ProfileSettingsForm(
          key: ValueKey(
            value.profiles.map((profile) => profile.updatedAt).join(','),
          ),
          initialSettings: value,
        ),
      ),
    );
  }
}

class _ProfileSettingsForm extends ConsumerStatefulWidget {
  const _ProfileSettingsForm({required this.initialSettings, super.key});

  final LlmProfileSettings initialSettings;

  @override
  ConsumerState<_ProfileSettingsForm> createState() =>
      _ProfileSettingsFormState();
}

class _ProfileSettingsFormState extends ConsumerState<_ProfileSettingsForm> {
  final _formKey = GlobalKey<FormState>();
  late final List<_ProfileDraft> _profiles;
  late final Map<LlmPurpose, String> _assignments;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _profiles = [
      for (final profile in widget.initialSettings.profiles)
        _ProfileDraft.fromProfile(profile),
    ];
    _assignments = Map.of(widget.initialSettings.assignments);
  }

  @override
  void dispose() {
    for (final profile in _profiles) {
      profile.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '용도별 활성 프로필',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '저장 후 시작되는 새 작업부터 선택한 모델이 적용됩니다. '
                    '이미 실행 중인 작업은 기존 프로필로 완료됩니다.',
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          for (final purpose in LlmPurpose.values) ...[
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'llm-purpose-${purpose.id}-'
                                '${_assignments[purpose]}-${_profiles.length}',
                              ),
                              initialValue: _assignments[purpose],
                              decoration: InputDecoration(
                                labelText: purpose.displayName,
                                border: const OutlineInputBorder(),
                              ),
                              items: [
                                for (final profile in _profiles)
                                  DropdownMenuItem(
                                    value: profile.id,
                                    child: Text(profile.name.text),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (value) {
                                      if (value == null) return;
                                      setState(
                                        () => _assignments[purpose] = value,
                                      );
                                    },
                            ),
                            if (purpose != LlmPurpose.values.last)
                              const SizedBox(height: 14),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '프로필',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key('add-llm-profile-button'),
                        onPressed: _saving ? null : _addProfile,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('프로필 추가'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (var index = 0; index < _profiles.length; index++) ...[
                    _ProfileCard(
                      draft: _profiles[index],
                      enabled: !_saving,
                      canDelete: _profiles.length > 1,
                      onChanged: () => setState(() {}),
                      onDelete: () => _deleteProfile(index),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.security_rounded),
                      title: Text('API Key는 서버에만 보관됩니다.'),
                      subtitle: Text(
                        'Android를 포함한 클라이언트에서는 Provider, 모델, '
                        'Ollama 주소와 용도 할당만 변경합니다.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('save-llm-profiles-button'),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded),
                    label: Text(_saving ? '저장 중...' : '프로필 저장'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addProfile() {
    final profile = _ProfileDraft(
      id: const Uuid().v4(),
      name: TextEditingController(text: '새 프로필'),
      provider: LlmProviderKind.ollama,
      model: TextEditingController(text: 'qwen3-vl:8b-instruct'),
      baseUrl: TextEditingController(text: 'http://127.0.0.1:11434'),
    );
    setState(() => _profiles.add(profile));
  }

  void _deleteProfile(int index) {
    if (_profiles.length == 1) return;
    final removed = _profiles.removeAt(index);
    final fallbackId = _profiles.first.id;
    for (final purpose in LlmPurpose.values) {
      if (_assignments[purpose] == removed.id) {
        _assignments[purpose] = fallbackId;
      }
    }
    removed.dispose();
    setState(() {});
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final settings = LlmProfileSettings(
        profiles: [for (final profile in _profiles) profile.toModel()],
        assignments: Map.of(_assignments),
      );
      await ref.read(llmProfilesControllerProvider.notifier).save(settings);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('LLM 프로필을 저장했어요.')));
    } catch (error) {
      if (!mounted) return;
      final message = error is AppFailure
          ? error.message
          : 'LLM 프로필을 저장하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.draft,
    required this.enabled,
    required this.canDelete,
    required this.onChanged,
    required this.onDelete,
  });

  final _ProfileDraft draft;
  final bool enabled;
  final bool canDelete;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    draft.name.text,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '프로필 삭제',
                  onPressed: enabled && canDelete ? onDelete : null,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: draft.name,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: '프로필 이름',
                border: OutlineInputBorder(),
              ),
              maxLength: 80,
              validator: (value) => value == null || value.trim().isEmpty
                  ? '프로필 이름을 입력해 주세요.'
                  : null,
              onChanged: (_) => onChanged(),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<LlmProviderKind>(
              initialValue: draft.provider,
              decoration: const InputDecoration(
                labelText: 'Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final provider in LlmProviderKind.values)
                  DropdownMenuItem(
                    value: provider,
                    child: Text(provider.displayName),
                  ),
              ],
              onChanged: !enabled
                  ? null
                  : (value) {
                      if (value == null) return;
                      draft.provider = value;
                      if (value == LlmProviderKind.ollama &&
                          draft.baseUrl.text.trim().isEmpty) {
                        draft.baseUrl.text = 'http://127.0.0.1:11434';
                      }
                      onChanged();
                    },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: draft.model,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: '모델',
                hintText: 'qwen3-vl:8b-instruct',
                border: OutlineInputBorder(),
              ),
              maxLength: 128,
              validator: (value) => value == null || value.trim().isEmpty
                  ? '모델 이름을 입력해 주세요.'
                  : null,
            ),
            if (draft.provider == LlmProviderKind.ollama) ...[
              const SizedBox(height: 8),
              TextFormField(
                controller: draft.baseUrl,
                enabled: enabled,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Ollama Base URL',
                  hintText: 'http://127.0.0.1:11434',
                  border: OutlineInputBorder(),
                ),
                validator: _validateUrl,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String? _validateUrl(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '올바른 http 또는 https 주소를 입력해 주세요.';
    }
    return null;
  }
}

class _ProfileDraft {
  _ProfileDraft({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    required this.baseUrl,
  });

  factory _ProfileDraft.fromProfile(LlmProfile profile) => _ProfileDraft(
    id: profile.id,
    name: TextEditingController(text: profile.name),
    provider: profile.provider,
    model: TextEditingController(text: profile.model),
    baseUrl: TextEditingController(text: profile.baseUrl),
  );

  final String id;
  final TextEditingController name;
  LlmProviderKind provider;
  final TextEditingController model;
  final TextEditingController baseUrl;

  LlmProfile toModel() => LlmProfile(
    id: id,
    name: name.text.trim(),
    provider: provider,
    model: model.text.trim(),
    baseUrl: provider == LlmProviderKind.ollama ? baseUrl.text.trim() : '',
    updatedAt: DateTime.now().toUtc(),
  );

  void dispose() {
    name.dispose();
    model.dispose();
    baseUrl.dispose();
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is AppFailure
        ? (error as AppFailure).message
        : 'LLM 프로필을 불러오지 못했어요.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}
