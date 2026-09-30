import 'dart:async';

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
  final Map<LlmProviderKind, AsyncValue<LlmModelCatalog>> _modelCatalogs = {};
  Timer? _modelRefreshTimer;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _profiles = [
      for (final profile in widget.initialSettings.profiles)
        _ProfileDraft.fromProfile(profile),
    ];
    _assignments = Map.of(widget.initialSettings.assignments);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAllModels());
    _modelRefreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _refreshAllModels(),
    );
  }

  @override
  void dispose() {
    _modelRefreshTimer?.cancel();
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
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: '모델 목록 새로고침',
                        onPressed: _saving ? null : _refreshAllModels,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (var index = 0; index < _profiles.length; index++) ...[
                    _ProfileCard(
                      draft: _profiles[index],
                      enabled: !_saving,
                      canDelete: _profiles.length > 1,
                      modelCatalog: _modelCatalogs[_profiles[index].provider],
                      onChanged: () => setState(() {}),
                      onProviderChanged: (provider) =>
                          _changeProvider(_profiles[index], provider),
                      onRefreshModels: () =>
                          _refreshModels(_profiles[index].provider),
                      onDelete: () => _deleteProfile(index),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.security_rounded),
                      title: Text('API Key는 서버에만 보관됩니다.'),
                      subtitle: Text(
                        'Ollama는 서버 컴퓨터의 로컬 인스턴스에서 실행됩니다. '
                        'Android를 포함한 클라이언트는 실행 방식, 모델, 용도 할당만 변경합니다.',
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
    final models =
        _modelCatalogs[LlmProviderKind.ollama]?.value?.models ??
        const <String>[];
    final profile = _ProfileDraft(
      id: const Uuid().v4(),
      name: TextEditingController(text: '새 프로필'),
      provider: LlmProviderKind.ollama,
      model: models.isEmpty ? '' : models.first,
    );
    setState(() => _profiles.add(profile));
  }

  void _changeProvider(_ProfileDraft draft, LlmProviderKind provider) {
    draft.provider = provider;
    final models = _modelCatalogs[provider]?.value?.models;
    draft.model = models == null || models.isEmpty ? '' : models.first;
    setState(() {});
    if (_modelCatalogs[provider] == null) {
      _refreshModels(provider);
    }
  }

  Future<void> _refreshAllModels() async {
    await Future.wait([
      for (final provider in LlmProviderKind.values) _refreshModels(provider),
    ]);
  }

  Future<void> _refreshModels(LlmProviderKind provider) async {
    if (!mounted) return;
    setState(() => _modelCatalogs[provider] = const AsyncLoading());
    final result = await AsyncValue.guard(
      () =>
          ref.read(llmProfilesControllerProvider.notifier).loadModels(provider),
    );
    if (!mounted) return;
    setState(() {
      _modelCatalogs[provider] = result;
      final models = result.value?.models ?? const <String>[];
      if (models.isEmpty) return;
      for (final draft in _profiles.where(
        (draft) => draft.provider == provider && draft.model.isEmpty,
      )) {
        draft.model = models.first;
      }
    });
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
    required this.modelCatalog,
    required this.onChanged,
    required this.onProviderChanged,
    required this.onRefreshModels,
    required this.onDelete,
  });

  final _ProfileDraft draft;
  final bool enabled;
  final bool canDelete;
  final AsyncValue<LlmModelCatalog>? modelCatalog;
  final VoidCallback onChanged;
  final ValueChanged<LlmProviderKind> onProviderChanged;
  final VoidCallback onRefreshModels;
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
                labelText: '실행 방식',
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
                      onProviderChanged(value);
                    },
            ),
            const SizedBox(height: 14),
            _ModelDropdown(
              key: ValueKey(
                '${draft.id}-${draft.provider.id}-${draft.model}-'
                '${modelCatalog?.value?.refreshedAt.toIso8601String()}',
              ),
              selectedModel: draft.model,
              catalog: modelCatalog,
              enabled: enabled,
              onChanged: (model) {
                draft.model = model;
                onChanged();
              },
              onRefresh: onRefreshModels,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  const _ModelDropdown({
    required this.selectedModel,
    required this.catalog,
    required this.enabled,
    required this.onChanged,
    required this.onRefresh,
    super.key,
  });

  final String selectedModel;
  final AsyncValue<LlmModelCatalog>? catalog;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final availableModels = catalog?.value?.models ?? const <String>[];
    final models = <String>[...availableModels];
    if (selectedModel.isNotEmpty && !models.contains(selectedModel)) {
      models.insert(0, selectedModel);
    }
    final loading = catalog == null || catalog!.isLoading;
    final error = catalog?.error;
    final selectedModelUnavailable =
        catalog?.hasValue == true &&
        selectedModel.isNotEmpty &&
        !availableModels.contains(selectedModel);
    final helperText = loading
        ? '서버에서 모델 목록을 불러오는 중입니다.'
        : error != null
        ? '모델 목록을 불러오지 못했습니다.'
        : selectedModelUnavailable
        ? '현재 모델을 사용할 수 없습니다. 목록에서 다시 선택해 주세요.'
        : availableModels.isEmpty
        ? '사용 가능한 모델이 없습니다.'
        : '목록은 화면 진입 시와 5분마다 자동 갱신됩니다.';

    return DropdownButtonFormField<String>(
      initialValue: selectedModel.isEmpty ? null : selectedModel,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '모델',
        helperText: helperText,
        border: const OutlineInputBorder(),
        suffixIcon: loading
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : error != null
            ? IconButton(
                tooltip: '다시 불러오기',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              )
            : null,
      ),
      items: [
        for (final model in models)
          DropdownMenuItem(
            value: model,
            enabled: availableModels.contains(model) || error != null,
            child: Text(
              availableModels.contains(model) || error != null
                  ? model
                  : '$model (사용할 수 없음)',
            ),
          ),
      ],
      onChanged: !enabled || loading || availableModels.isEmpty
          ? null
          : (value) {
              if (value != null) onChanged(value);
            },
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return '사용할 모델을 선택해 주세요.';
        }
        if (catalog?.hasValue == true && !availableModels.contains(value)) {
          return '서버에서 사용할 수 있는 모델을 선택해 주세요.';
        }
        return null;
      },
    );
  }
}

class _ProfileDraft {
  _ProfileDraft({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
  });

  factory _ProfileDraft.fromProfile(LlmProfile profile) => _ProfileDraft(
    id: profile.id,
    name: TextEditingController(text: profile.name),
    provider: profile.provider,
    model: profile.model,
  );

  final String id;
  final TextEditingController name;
  LlmProviderKind provider;
  String model;

  LlmProfile toModel() => LlmProfile(
    id: id,
    name: name.text.trim(),
    provider: provider,
    model: model,
    updatedAt: DateTime.now().toUtc(),
  );

  void dispose() {
    name.dispose();
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
