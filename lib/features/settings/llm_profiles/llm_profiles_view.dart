import 'dart:async';

import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/ai/llm_model_filter_store.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/errors/app_error_reporter.dart';
import 'package:review_platform/domain/models/llm_model_filter.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/features/settings/llm_profiles/llm_profiles_view_model.dart';

class LlmProfilesView extends ConsumerWidget {
  const LlmProfilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(llmProfilesControllerProvider);
    return Scaffold(
      key: const Key('llm-profiles-view'),
      appBar: AppBar(title: const Text('용도별 AI 설정')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _LoadError(
          error: error,
          onRetry: () =>
              ref.read(llmProfilesControllerProvider.notifier).reload(),
        ),
        data: (value) => _ProfileSettingsForm(
          // Server timestamps must not recreate the form after every autosave.
          key: const Key('llm-profile-settings-form'),
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

class _ProfileSettingsFormState extends ConsumerState<_ProfileSettingsForm>
    with WidgetsBindingObserver {
  static const _saveDelay = Duration(milliseconds: 700);
  static const _purposeDisplayOrder = [
    LlmPurpose.documentVision,
    LlmPurpose.conceptExtraction,
    LlmPurpose.conceptRevision,
    LlmPurpose.questionGeneration,
  ];
  final _formKey = GlobalKey<FormState>();
  late final LlmProfilesController _controller;
  late final AppErrorReporter _errorReporter;
  late final List<_ProfileDraft> _profiles;
  late final Map<LlmPurpose, String> _assignments;
  late final Map<LlmApiKeyProvider, TextEditingController> _apiKeyControllers;
  final Set<LlmApiKeyProvider> _visibleApiKeys = {};
  final Map<LlmProviderKind, AsyncValue<LlmModelCatalog>> _modelCatalogs = {};
  Timer? _modelRefreshTimer;
  Timer? _autoSaveTimer;
  Future<bool>? _activeSave;
  ScaffoldMessengerState? _messenger;
  bool _saving = false;
  bool _dirty = false;
  bool _saved = false;
  bool _allowExit = false;
  bool _leaving = false;
  String? _saveError;
  final Map<LlmProviderKind, String> _reportedModelErrors = {};
  LlmModelFilterPreferences _filterPreferences =
      const LlmModelFilterPreferences();
  bool _filtersLoaded = false;
  bool _savingFilters = false;

  // Presentation order must not change purpose assignments or saved profiles.
  List<_ProfileDraft> get _displayProfiles => [
    for (final purpose in _purposeDisplayOrder)
      _profiles.firstWhere((draft) => draft.id == _assignments[purpose]),
  ];

  @override
  void initState() {
    super.initState();
    _controller = ref.read(llmProfilesControllerProvider.notifier);
    _errorReporter = ref.read(appErrorReporterProvider.notifier);
    _controller.attachExitHandler(_confirmLeave);
    WidgetsBinding.instance.addObserver(this);
    _profiles = [
      for (final profile in widget.initialSettings.profiles)
        _ProfileDraft.fromProfile(profile),
    ];
    _assignments = Map.of(widget.initialSettings.assignments);
    _apiKeyControllers = {
      for (final provider in LlmApiKeyProvider.values)
        provider: TextEditingController(),
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAllModels();
      _loadFilters();
    });
    _modelRefreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _refreshAllModels(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_flushChanges());
    }
  }

  @override
  void dispose() {
    _controller.detachExitHandler(_confirmLeave);
    WidgetsBinding.instance.removeObserver(this);
    _modelRefreshTimer?.cancel();
    _autoSaveTimer?.cancel();
    // Forced route disposal can bypass normal exit guards. Capture a final
    // valid draft before disposing its controllers and finish the write.
    if (_dirty && !_saving && _draftIsValid) {
      unawaited(
        _controller
            .save(_settingsSnapshot(), apiKeys: _apiKeysSnapshot())
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace _) {
                _showSaveFailure(error);
              },
            ),
      );
    }
    for (final controller in _apiKeyControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowExit || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            _saveStatus(),
            Expanded(
              // This is a single form, not a lazy list. Avoid ListView's
              // synthetic two-pane semantics node: tooltip overlays can leave
              // dangling Windows AXTree children (flutter/flutter#182444).
              child: SingleChildScrollView(
                key: const Key('llm-profile-scroll-view'),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '작업별 모델 설정',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton.outlined(
                              tooltip: '모델 목록 새로고침',
                              onPressed: _saving ? null : _refreshAllModels,
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '변경사항은 자동으로 저장되며, 저장 완료 후 시작되는 새 작업부터 적용됩니다. '
                          '이미 실행 중인 작업은 기존 설정으로 완료됩니다.',
                        ),
                        const SizedBox(height: 12),
                        for (final draft in _displayProfiles) ...[
                          _ProfileCard(
                            draft: draft,
                            enabled: !_saving,
                            modelCatalog: _modelCatalogs[draft.provider],
                            modelFilter: _filterPreferences.forProvider(
                              draft.provider.id,
                            ),
                            filterEnabled:
                                _filtersLoaded && !_savingFilters && !_saving,
                            onFilterChanged: (filter) =>
                                _saveFilter(draft.provider, filter),
                            onChanged: _markChanged,
                            onProviderChanged: (provider) =>
                                _changeProvider(draft, provider),
                            onRefreshModels: () =>
                                _refreshModels(draft.provider),
                          ),
                          const SizedBox(height: 12),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'API Key',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              children: [
                                for (
                                  var index = 0;
                                  index < LlmApiKeyProvider.values.length;
                                  index++
                                ) ...[
                                  Builder(
                                    builder: (context) {
                                      final provider =
                                          LlmApiKeyProvider.values[index];
                                      final configured =
                                          widget
                                              .initialSettings
                                              .apiKeyConfigured[provider] ??
                                          false;
                                      return TextFormField(
                                        key: ValueKey(
                                          'llm-api-key-${provider.id}',
                                        ),
                                        controller:
                                            _apiKeyControllers[provider],
                                        enabled: !_saving,
                                        obscureText: !_visibleApiKeys.contains(
                                          provider,
                                        ),
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        onChanged: (_) => _markChanged(),
                                        maxLength: 2000,
                                        decoration: InputDecoration(
                                          labelText: provider.displayName,
                                          hintText: configured
                                              ? '비워 두면 저장된 키 유지'
                                              : 'API Key 입력',
                                          helperText: configured
                                              ? '서버에 저장된 키가 있습니다.'
                                              : '아직 저장된 키가 없습니다.',
                                          border: const OutlineInputBorder(),
                                          suffixIcon: IconButton(
                                            tooltip:
                                                _visibleApiKeys.contains(
                                                  provider,
                                                )
                                                ? 'API Key 숨기기'
                                                : 'API Key 표시',
                                            onPressed: _saving
                                                ? null
                                                : () => setState(() {
                                                    if (!_visibleApiKeys.add(
                                                      provider,
                                                    )) {
                                                      _visibleApiKeys.remove(
                                                        provider,
                                                      );
                                                    }
                                                  }),
                                            icon: Icon(
                                              _visibleApiKeys.contains(provider)
                                                  ? Icons
                                                        .visibility_off_outlined
                                                  : Icons.visibility_outlined,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  if (index !=
                                      LlmApiKeyProvider.values.length - 1)
                                    const SizedBox(height: 14),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Card(
                          child: ListTile(
                            leading: Icon(Icons.security_rounded),
                            title: Text('API Key는 서버에만 보관됩니다.'),
                            subtitle: Text(
                              '키 원문은 다시 클라이언트로 전송되지 않으며 서버에서 암호화해 저장합니다. '
                              'Ollama는 서버 컴퓨터의 로컬 인스턴스에서 실행됩니다.',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _saveStatus() {
    final message =
        _saveError ??
        (_saving
            ? '자동 저장 중...'
            : _dirty
            ? '변경사항 저장 대기 중...'
            : _saved
            ? '자동 저장됨'
            : '변경사항은 자동으로 저장됩니다.');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          if (_saving)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              _saveError != null
                  ? Icons.error_outline_rounded
                  : _dirty
                  ? Icons.cloud_upload_outlined
                  : Icons.cloud_done_outlined,
              size: 20,
              color: _saveError != null
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(message, key: const Key('llm-profile-save-status')),
            ),
          ),
          if (_saveError != null)
            IconButton(
              key: const Key('retry-llm-profile-save'),
              tooltip: '자동 저장 재시도',
              onPressed: () => _flushChanges(),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
    );
  }

  void _markChanged() {
    setState(() {
      _dirty = true;
      _saved = false;
      _saveError = null;
    });
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_saveDelay, () => unawaited(_flushChanges()));
  }

  void _changeProvider(_ProfileDraft draft, LlmProviderKind provider) {
    draft.provider = provider;
    draft.reasoningEffort = null;
    if (provider != LlmProviderKind.ollama) draft.contextWindowTokens = null;
    final models = _modelCatalogs[provider]?.value?.models;
    draft.model = models == null || models.isEmpty ? '' : models.first;
    setState(() {});
    _markChanged();
    if (_modelCatalogs[provider] == null) {
      _refreshModels(provider);
    }
  }

  Future<void> _loadFilters() async {
    try {
      final preferences = await ref.read(llmModelFilterStoreProvider).read();
      if (!mounted) return;
      setState(() => _filterPreferences = preferences);
    } catch (error) {
      if (!mounted) return;
      showAppError(context, error, fallback: '모델 필터 설정을 불러오지 못해 기본값을 사용합니다.');
    } finally {
      if (mounted) setState(() => _filtersLoaded = true);
    }
  }

  Future<void> _saveFilter(
    LlmProviderKind provider,
    LlmModelFilter filter,
  ) async {
    if (_savingFilters || !_filtersLoaded) return;
    final previous = _filterPreferences;
    final updated = previous.withProvider(provider.id, filter);
    setState(() {
      _filterPreferences = updated;
      _savingFilters = true;
    });
    try {
      await ref.read(llmModelFilterStoreProvider).write(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() => _filterPreferences = previous);
      showAppError(
        context,
        error,
        fallback: '모델 필터 설정을 저장하지 못했습니다. 다시 시도해 주세요.',
      );
    } finally {
      if (mounted) setState(() => _savingFilters = false);
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
    var filledModel = false;
    setState(() {
      _modelCatalogs[provider] = result;
      final models = result.value?.models ?? const <String>[];
      if (models.isEmpty) return;
      for (final draft in _profiles.where(
        (draft) => draft.provider == provider && draft.model.isEmpty,
      )) {
        draft.model = models.first;
        filledModel = true;
      }
      if (provider == LlmProviderKind.openAi) {
        for (final draft in _profiles.where((d) => d.provider == provider)) {
          final efforts =
              result.value?.modelCapabilities[draft.model]?.reasoningEfforts ??
              const <String>[];
          if (!efforts.contains(draft.reasoningEffort)) {
            draft.reasoningEffort = null;
          }
        }
      }
    });
    if (filledModel && _dirty && !_saving) _markChanged();
    if (result.hasError &&
        _profiles.any((draft) => draft.provider == provider)) {
      final message = appErrorMessage(
        result.error!,
        fallback: '모델 목록을 불러오지 못했습니다.',
      );
      if (_reportedModelErrors[provider] != message) {
        _reportedModelErrors[provider] = message;
        showAppError(context, message);
      }
    } else if (!result.hasError) {
      _reportedModelErrors.remove(provider);
    }
  }

  bool get _draftIsValid =>
      _profiles.every((draft) {
        final name = draft.name;
        final available = _modelCatalogs[draft.provider]?.value?.models;
        return name.isNotEmpty &&
            name.length <= 80 &&
            draft.model.isNotEmpty &&
            draft.model.length <= 128 &&
            _validQuestionLimit(draft.maximumQuestionsText) &&
            (available == null || available.contains(draft.model));
      }) &&
      _apiKeyControllers.values.every((key) => key.text.trim().length <= 2000);

  LlmProfileSettings _settingsSnapshot() => LlmProfileSettings(
    profiles: [for (final profile in _profiles) profile.toModel()],
    assignments: Map.of(_assignments),
    apiKeyConfigured: Map.of(widget.initialSettings.apiKeyConfigured),
  );

  Map<LlmApiKeyProvider, String> _apiKeysSnapshot() => {
    for (final entry in _apiKeyControllers.entries)
      if (entry.value.text.trim().isNotEmpty)
        entry.key: entry.value.text.trim(),
  };

  Future<bool> _flushChanges() {
    _autoSaveTimer?.cancel();
    if (_activeSave != null) return _activeSave!;
    if (!_dirty || !mounted) return Future.value(!_dirty);
    if (!(_formKey.currentState?.validate() ?? false) || !_draftIsValid) {
      setState(() => _saveError = '입력을 완성하면 자동으로 저장됩니다.');
      return Future.value(false);
    }
    final future = _save();
    _activeSave = future;
    unawaited(future.then((_) => _activeSave = null));
    return future;
  }

  Future<bool> _save() async {
    setState(() => _saving = true);
    try {
      final apiKeys = _apiKeysSnapshot();
      final updated = await _controller.save(
        _settingsSnapshot(),
        apiKeys: apiKeys,
      );
      if (!mounted) return true;
      for (final profile in updated.profiles) {
        final draft = _profiles
            .where((draft) => draft.id == profile.id)
            .firstOrNull;
        if (draft == null) {
          _profiles.add(_ProfileDraft.fromProfile(profile));
        } else {
          draft.provider = profile.provider;
          draft.model = profile.model;
          draft.contextWindowTokens = profile.contextWindowTokens;
          draft.reasoningEffort = profile.reasoningEffort;
          draft.maximumQuestionsText = profile.maximumQuestionsPerRequest
              .toString();
        }
      }
      _assignments
        ..clear()
        ..addAll(updated.assignments);
      for (final controller in _apiKeyControllers.values) {
        controller.clear();
      }
      _dirty = false;
      _saved = true;
      _saveError = null;
      if (apiKeys.isNotEmpty) unawaited(_refreshAllModels());
      return true;
    } catch (error) {
      if (mounted) {
        _saveError = _failureMessage(error);
        showAppError(context, _saveError!);
      } else {
        _showSaveFailure(error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _failureMessage(Object error) =>
      error is AppFailure ? error.message : 'AI 설정을 자동 저장하지 못했어요. 다시 시도해 주세요.';

  void _showSaveFailure(Object error) {
    final messenger = _messenger;
    if (messenger != null && messenger.mounted) {
      _errorReporter.report(_failureMessage(error));
    }
  }

  Future<bool> _confirmLeave() async {
    if (_allowExit) return true;
    final saved = await _flushChanges();
    if (!mounted) return true;
    if (!saved) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장하지 않고 나갈까요?'),
          content: const Text('변경사항이 아직 저장되지 않았어요. 계속 편집하거나 변경사항을 버릴 수 있습니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('계속 편집'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('변경사항 버리기'),
            ),
          ],
        ),
      );
      if (!mounted) return true;
      if (discard != true) {
        return false;
      }
      _dirty = false;
    }
    return true;
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    final canLeave = await _controller.prepareToLeave();
    if (!mounted) return;
    if (!canLeave) {
      _leaving = false;
      return;
    }
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.draft,
    required this.enabled,
    required this.modelCatalog,
    required this.modelFilter,
    required this.filterEnabled,
    required this.onFilterChanged,
    required this.onChanged,
    required this.onProviderChanged,
    required this.onRefreshModels,
  });

  final _ProfileDraft draft;
  final bool enabled;
  final AsyncValue<LlmModelCatalog>? modelCatalog;
  final LlmModelFilter modelFilter;
  final bool filterEnabled;
  final ValueChanged<LlmModelFilter> onFilterChanged;
  final VoidCallback onChanged;
  final ValueChanged<LlmProviderKind> onProviderChanged;
  final VoidCallback onRefreshModels;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              draft.name,
              key: ValueKey('llm-purpose-title-${draft.id}'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (draft.id == 'purpose-documentVision') ...[
              const SizedBox(height: 6),
              const Text(
                'PDF의 이미지와 스캔 페이지를 읽는 용도입니다. 이미지 입력을 지원하는 모델을 선택해 주세요.',
              ),
            ],
            const SizedBox(height: 8),
            DropdownButtonFormField<LlmProviderKind>(
              key: ValueKey('llm-provider-${draft.id}'),
              initialValue: draft.provider,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '실행 방식',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final provider in LlmProviderKind.values)
                  DropdownMenuItem(
                    value: provider,
                    child: Text(
                      provider.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
            LayoutBuilder(
              builder: (context, constraints) {
                final modelField = _ModelDropdown(
                  // Loading/refresh timestamps and selected values are data,
                  // not widget identity. Form fields update initialValue in
                  // didUpdateWidget without replacing their semantics nodes.
                  key: ValueKey('llm-model-field-${draft.id}'),
                  selectedModel: draft.model,
                  profileId: draft.id,
                  catalog: modelCatalog,
                  filter: modelFilter,
                  enabled: enabled,
                  onChanged: (model) {
                    draft.model = model;
                    final efforts =
                        modelCatalog
                            ?.value
                            ?.modelCapabilities[model]
                            ?.reasoningEfforts ??
                        const <String>[];
                    if (!efforts.contains(draft.reasoningEffort)) {
                      draft.reasoningEffort = null;
                    }
                    final maximum = modelCatalog?.value?.contextWindows[model];
                    if (draft.contextWindowTokens != null &&
                        maximum != null &&
                        draft.contextWindowTokens! > maximum) {
                      draft.contextWindowTokens = null;
                    }
                    onChanged();
                  },
                  onRefresh: onRefreshModels,
                );
                final filterButton = _ModelFilterMenu(
                  profileId: draft.id,
                  filter: modelFilter,
                  enabled: filterEnabled,
                  onChanged: onFilterChanged,
                );
                final reasoningField = draft.provider == LlmProviderKind.openAi
                    ? _ReasoningEffortSlider(
                        profileId: draft.id,
                        selectedEffort: draft.reasoningEffort,
                        capabilities:
                            modelCatalog?.value?.modelCapabilities[draft.model],
                        loading:
                            modelCatalog == null || modelCatalog!.isLoading,
                        enabled: enabled,
                        onChanged: (effort) {
                          draft.reasoningEffort = effort;
                          onChanged();
                        },
                      )
                    : null;
                final inline =
                    reasoningField != null &&
                    constraints.maxWidth >= 600 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 18.2;
                final modelRow = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: modelField),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: filterButton,
                    ),
                    if (inline) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: constraints.maxWidth * 0.5,
                        child: reasoningField,
                      ),
                    ],
                  ],
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    modelRow,
                    if (reasoningField != null && !inline) ...[
                      const SizedBox(height: 14),
                      reasoningField,
                    ],
                  ],
                );
              },
            ),
            if (modelCatalog?.error case final error?) ...[
              const SizedBox(height: 12),
              AppErrorNotice(
                error: error,
                fallback: '모델 목록을 불러오지 못했습니다.',
                onRetry: onRefreshModels,
              ),
            ],
            if (draft.provider == LlmProviderKind.ollama) ...[
              const SizedBox(height: 14),
              _ContextWindowDropdown(
                key: ValueKey('llm-context-field-${draft.id}'),
                profileId: draft.id,
                provider: draft.provider,
                selectedTokens: draft.contextWindowTokens,
                maximumTokens: modelCatalog?.value?.contextWindows[draft.model],
                enabled: enabled,
                onChanged: (tokens) {
                  draft.contextWindowTokens = tokens;
                  onChanged();
                },
              ),
            ],
            if (draft.id == 'purpose-questionGeneration') ...[
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('llm-maximum-questions-per-request'),
                initialValue: draft.maximumQuestionsText,
                enabled: enabled,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '요청 1회당 문제 생성 상한',
                  suffixText: '개',
                  border: OutlineInputBorder(),
                  helperText:
                      '개념 기반 생성은 개념 하나의 요청에 적용합니다. 자유 텍스트 생성은 전체 응답에 적용합니다.',
                  helperMaxLines: 3,
                ),
                validator: (value) => _validQuestionLimit(value ?? '')
                    ? null
                    : '1 이상인 유효한 정수를 입력해 주세요.',
                onChanged: (value) {
                  draft.maximumQuestionsText = value;
                  onChanged();
                },
              ),
              if ((int.tryParse(draft.maximumQuestionsText.trim()) ?? 0) >
                  100) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('llm-question-limit-warning'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.orange.shade900.withValues(alpha: 0.3)
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '100개를 초과하면 생성 시간이 길어지고 응답 잘림·실패 위험이 높아질 수 있어요. 경고와 관계없이 저장됩니다.',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                '상한은 생성 목표 개수가 아닙니다. 모델의 출력·컨텍스트 한도와 요청 제한 시간은 별도로 적용됩니다.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasoningEffortSlider extends StatelessWidget {
  const _ReasoningEffortSlider({
    required this.profileId,
    required this.selectedEffort,
    required this.capabilities,
    required this.loading,
    required this.enabled,
    required this.onChanged,
  });

  final String profileId;
  final String? selectedEffort;
  final LlmModelCapabilities? capabilities;
  final bool loading;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final efforts = capabilities?.reasoningEfforts ?? const <String>[];
    // Keep a saved value while metadata loads/fails; do not silently discard it.
    final options = <String>{
      'auto',
      ...efforts,
      if (loading || capabilities == null) ?selectedEffort,
    }.toList();
    final unknown = capabilities?.isKnown != true;
    final index = options.indexOf(selectedEffort ?? 'auto');
    final selectedIndex = index < 0 ? 0 : index;
    String label(int index) => options[index] == 'auto' ? '자동' : options[index];
    final textStyle = MediaQuery.boldTextOf(context)
        ? DefaultTextStyle.of(context).style
              .copyWith(fontWeight: FontWeight.bold)
        : DefaultTextStyle.of(context).style;
    var labelWidth = 0.0;
    // Reserve the widest supported label so the slider does not jump as its value changes.
    for (var index = 0; index < options.length; index++) {
      final painter = TextPainter(
        text: TextSpan(text: label(index), style: textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > labelWidth) labelWidth = painter.width;
      painter.dispose();
    }
    return InputDecorator(
      key: ValueKey('llm-reasoning-$profileId'),
      decoration: InputDecoration(
        labelText: 'Reasoning Effort',
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: const OutlineInputBorder(),
        helperMaxLines: 5,
        helperText: loading
            ? '모델의 추론 지원 정보를 확인하는 중입니다.'
            : unknown
            ? '지원 정보가 등록되지 않은 모델은 자동 모드만 제공합니다. 모델 사용은 가능하지만 API 호환성은 확인이 필요합니다.'
            : efforts.isEmpty
            ? capabilities?.supportsReasoning == true
                  ? '추론 모델이며 자동 모드로 사용할 수 있습니다. 공식 문서에서 확인한 수동 설정 값이 없어 자동만 제공합니다.'
                  : '이 모델에는 확인된 수동 추론 설정이 없습니다. 자동 모드를 사용합니다.'
            : '자동은 API 기본값${capabilities?.defaultReasoningEffort == null ? '' : ' (${capabilities!.defaultReasoningEffort})'}을 사용합니다. '
                  '높은 수준은 응답 시간과 토큰 비용을 늘릴 수 있습니다.',
      ),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 3),
                child: Slider(
                  key: ValueKey('llm-reasoning-slider-$profileId'),
                  min: 0,
                  max: options.length > 1 ? (options.length - 1).toDouble() : 1,
                  divisions: options.length > 1 ? options.length - 1 : 1,
                  value: selectedIndex.toDouble(),
                  label: label(selectedIndex),
                  semanticFormatterCallback: (value) =>
                      label(value.round().clamp(0, options.length - 1)),
                  onChanged:
                      enabled && !loading && !unknown && efforts.isNotEmpty
                      ? (value) {
                          final effort = options[value.round()];
                          onChanged(effort == 'auto' ? null : effort);
                        }
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: labelWidth.ceilToDouble() + 2,
              child: Text(
                key: ValueKey('llm-reasoning-value-$profileId'),
                label(selectedIndex),
                style: textStyle,
                textAlign: TextAlign.end,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextWindowDropdown extends StatelessWidget {
  const _ContextWindowDropdown({
    required this.profileId,
    required this.provider,
    required this.selectedTokens,
    required this.maximumTokens,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final String profileId;
  final LlmProviderKind provider;
  final int? selectedTokens;
  final int? maximumTokens;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final isLocal = provider == LlmProviderKind.ollama;
    final options = <int>{
      0,
      if (isLocal && maximumTokens != null) ...[
        for (final tokens in [
          4096,
          8192,
          16384,
          32768,
          40960,
          65536,
          131072,
          262144,
        ])
          if (tokens <= maximumTokens!) tokens,
        maximumTokens!,
      ],
      if (isLocal && selectedTokens != null) selectedTokens!,
    }.toList()..sort();
    return DropdownButtonFormField<int>(
      key: ValueKey('llm-context-$profileId'),
      initialValue: isLocal ? selectedTokens ?? 0 : 0,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '컨텍스트 크기',
        border: const OutlineInputBorder(),
        helperMaxLines: 5,
        helperText: !isLocal
            ? '자동: API 모델의 컨텍스트 한도를 사용합니다. 로컬 모델용 크기 제한과 PDF 분할 튜닝은 적용하지 않습니다.'
            : '${maximumTokens == null ? '최대 크기를 확인하지 못했습니다. 자동 모드를 사용하거나 모델 목록을 새로고침해 주세요.' : '모델 최대: ${_tokenLabel(maximumTokens!)}.'} '
                  '자동은 작업별 기존 설정을 사용합니다. 입력과 출력이 함께 쓰는 공간이며, 크게 설정할수록 메모리 사용량이 증가합니다.',
      ),
      items: [
        for (final tokens in options)
          DropdownMenuItem(
            value: tokens,
            enabled:
                tokens == 0 ||
                (maximumTokens != null && tokens <= maximumTokens!),
            child: Text(
              tokens == 0 ? '자동' : _tokenLabel(tokens),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: enabled && isLocal
          ? (value) => onChanged(value == 0 ? null : value)
          : null,
      validator: (value) {
        if (isLocal &&
            value != null &&
            value > 0 &&
            maximumTokens != null &&
            value > maximumTokens!) {
          return '모델 최대 크기 이하로 선택해 주세요.';
        }
        return null;
      },
    );
  }

  static String _tokenLabel(int tokens) => tokens % 1024 == 0
      ? '${tokens ~/ 1024}K (${tokens.toString()} 토큰)'
      : '$tokens 토큰';
}

enum _ModelFilterAction { old, snapshots }

class _ModelFilterMenu extends StatelessWidget {
  const _ModelFilterMenu({
    required this.profileId,
    required this.filter,
    required this.enabled,
    required this.onChanged,
  });

  final String profileId;
  final LlmModelFilter filter;
  final bool enabled;
  final ValueChanged<LlmModelFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final active = filter.hideOld || filter.hideSnapshots;
    return PopupMenuButton<_ModelFilterAction>(
      key: ValueKey('llm-model-filter-$profileId'),
      enabled: enabled,
      tooltip: active ? '모델 목록 필터 (적용 중)' : '모델 목록 필터',
      position: PopupMenuPosition.under,
      icon: Icon(
        active ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
        color: enabled && active ? Theme.of(context).colorScheme.primary : null,
      ),
      onSelected: (action) => onChanged(
        LlmModelFilter(
          hideOld: action == _ModelFilterAction.old
              ? !filter.hideOld
              : filter.hideOld,
          hideSnapshots: action == _ModelFilterAction.snapshots
              ? !filter.hideSnapshots
              : filter.hideSnapshots,
        ),
      ),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          key: ValueKey('llm-hide-old-$profileId'),
          value: _ModelFilterAction.old,
          checked: filter.hideOld,
          child: const Text('구형 모델 숨기기'),
        ),
        CheckedPopupMenuItem(
          key: ValueKey('llm-hide-snapshots-$profileId'),
          value: _ModelFilterAction.snapshots,
          checked: filter.hideSnapshots,
          child: const Text('날짜별 버전 숨기기'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          enabled: false,
          child: Text(
            '현재 선택한 모델과 분류 미확인 모델은 유지합니다. '
            '필터는 이 기기에 실행 방식별로 자동 저장됩니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  const _ModelDropdown({
    required this.profileId,
    required this.selectedModel,
    required this.catalog,
    required this.filter,
    required this.enabled,
    required this.onChanged,
    required this.onRefresh,
    super.key,
  });

  final String selectedModel;
  final String profileId;
  final AsyncValue<LlmModelCatalog>? catalog;
  final LlmModelFilter filter;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final availableModels = catalog?.value?.models ?? const <String>[];
    final models = catalog?.value == null
        ? <String>[]
        : filter.visibleModels(catalog!.value!, selectedModel);
    final hiddenCount = availableModels.length - models.length;
    if (selectedModel.isNotEmpty && !models.contains(selectedModel)) {
      models.insert(0, selectedModel);
    }
    final loading = catalog == null || catalog!.isLoading;
    final error = catalog?.error;
    final selectedModelUnavailable =
        catalog?.hasValue == true &&
        selectedModel.isNotEmpty &&
        !availableModels.contains(selectedModel);
    final selectedModelUnregistered =
        catalog?.value?.isUnregistered(selectedModel) == true;
    final metadata = catalog?.value?.modelMetadata[selectedModel];
    final statusNote = metadata?.lifecycle.isOld == true
        ? '현재 선택한 모델은 ${metadata!.lifecycle.displayName} 모델입니다. '
        : metadata?.isSnapshot == true
        ? '현재 선택한 날짜별 버전은 계속 표시합니다. '
        : '';
    final helperText = loading
        ? '서버에서 모델 목록을 불러오는 중입니다.'
        : error != null
        ? '목록을 불러오지 못했습니다. 아래 오류 안내를 확인해 주세요.'
        : selectedModelUnavailable
        ? '현재 모델을 사용할 수 없습니다. 목록에서 다시 선택해 주세요.'
        : availableModels.isEmpty
        ? '사용 가능한 모델이 없습니다.'
        : models.isEmpty
        ? '필터 조건에 맞는 모델이 없습니다. 숨기기 옵션을 꺼 주세요.'
        : selectedModelUnregistered
        ? '주황색: 추론 지원 정보 미등록. 모델은 선택할 수 있으며 추론 수준은 자동으로 처리됩니다.'
        : '$statusNote${hiddenCount > 0 ? '$hiddenCount개 모델을 숨겼습니다. ' : ''}'
              '목록은 화면 진입 시와 5분마다 자동 갱신됩니다.';

    return DropdownButtonFormField<String>(
      key: ValueKey('llm-model-$profileId'),
      initialValue: selectedModel.isEmpty ? null : selectedModel,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '모델',
        helperText: helperText,
        helperMaxLines: 4,
        border: const OutlineInputBorder(),
        suffixIcon: !loading && error == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (!loading && error != null)
                    IconButton(
                      tooltip: '다시 불러오기',
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
      ),
      items: [
        for (final model in models)
          DropdownMenuItem(
            value: model,
            enabled: availableModels.contains(model) || error != null,
            child: Text(
              availableModels.contains(model) || error != null
                  ? catalog?.value?.isUnregistered(model) == true
                        ? '$model · 지원 정보 미등록'
                        : model
                  : '$model (사용할 수 없음)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: catalog?.value?.isUnregistered(model) == true
                  ? TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.orange.shade300
                          : Colors.orange.shade800,
                      fontWeight: FontWeight.w600,
                    )
                  : null,
            ),
          ),
      ],
      onChanged: !enabled || loading || models.isEmpty
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
    this.contextWindowTokens,
    this.reasoningEffort,
    this.maximumQuestionsText = '120',
  });

  factory _ProfileDraft.fromProfile(LlmProfile profile) => _ProfileDraft(
    id: profile.id,
    name: profile.name,
    provider: profile.provider,
    model: profile.model,
    contextWindowTokens: profile.contextWindowTokens,
    reasoningEffort: profile.reasoningEffort,
    maximumQuestionsText: profile.maximumQuestionsPerRequest.toString(),
  );

  final String id;
  final String name;
  LlmProviderKind provider;
  String model;
  int? contextWindowTokens;
  String? reasoningEffort;
  String maximumQuestionsText;

  LlmProfile toModel() => LlmProfile(
    id: id,
    name: name,
    provider: provider,
    model: model,
    updatedAt: DateTime.now().toUtc(),
    maximumQuestionsPerRequest: int.parse(maximumQuestionsText.trim()),
    contextWindowTokens: provider == LlmProviderKind.ollama
        ? contextWindowTokens
        : null,
    reasoningEffort: provider == LlmProviderKind.openAi
        ? reasoningEffort
        : null,
  );
}

bool _validQuestionLimit(String value) {
  final trimmed = value.trim();
  if (!RegExp(r'^[0-9]+$').hasMatch(trimmed)) return false;
  final count = int.tryParse(trimmed);
  return count != null && count >= 1 && count <= 2147483647;
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is AppFailure
        ? (error as AppFailure).message
        : 'AI 설정을 불러오지 못했어요.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AppErrorNotice(error: message, onRetry: onRetry),
      ),
    );
  }
}
