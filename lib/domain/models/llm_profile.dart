enum LlmProviderKind {
  ollama('ollama', 'Ollama · 서버 컴퓨터 로컬'),
  openAi('openai', 'OpenAI API · 서버 경유');

  const LlmProviderKind(this.id, this.displayName);

  final String id;
  final String displayName;

  static LlmProviderKind fromId(String value) => values.firstWhere(
    (provider) => provider.id == value,
    orElse: () => throw FormatException('Unknown LLM provider: $value'),
  );
}

enum LlmPurpose {
  questionGeneration('questionGeneration', '문제 생성'),
  conceptExtraction('conceptExtraction', 'PDF 개념 추출'),
  conceptRevision('conceptRevision', '개념 수정');

  const LlmPurpose(this.id, this.displayName);

  final String id;
  final String displayName;
}

enum LlmApiKeyProvider {
  openAi('openai', 'OpenAI API Key'),
  gemini('gemini', 'Gemini API Key'),
  claude('claude', 'Claude API Key');

  const LlmApiKeyProvider(this.id, this.displayName);

  final String id;
  final String displayName;
}

class LlmProfile {
  const LlmProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    required this.updatedAt,
    this.contextWindowTokens,
    this.reasoningEffort,
    this.maximumQuestionsPerRequest = 120,
  });

  final String id;
  final String name;
  final LlmProviderKind provider;
  final String model;
  final DateTime updatedAt;
  final int? contextWindowTokens;
  final String? reasoningEffort;
  final int maximumQuestionsPerRequest;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.id,
    'model': model,
    'contextWindowTokens': contextWindowTokens,
    'reasoningEffort': reasoningEffort,
    'maximumQuestionsPerRequest': maximumQuestionsPerRequest,
  };
}

class LlmModelCatalog {
  const LlmModelCatalog({
    required this.provider,
    required this.models,
    required this.refreshedAt,
    this.contextWindows = const {},
    this.modelCapabilities = const {},
    this.modelMetadata = const {},
  });

  final LlmProviderKind provider;
  final List<String> models;
  final DateTime refreshedAt;
  final Map<String, int> contextWindows;
  final Map<String, LlmModelCapabilities> modelCapabilities;
  final Map<String, LlmModelMetadata> modelMetadata;

  bool isUnregistered(String model) =>
      provider == LlmProviderKind.openAi &&
      models.contains(model) &&
      modelCapabilities[model]?.isKnown != true;
}

enum LlmModelLifecycle {
  unknown('unknown', ''),
  current('current', ''),
  legacy('legacy', '구형'),
  deprecated('deprecated', '지원 중단 예정'),
  retired('retired', '지원 종료');

  const LlmModelLifecycle(this.id, this.displayName);
  final String id;
  final String displayName;

  static LlmModelLifecycle fromId(String? value) =>
      values.firstWhere((status) => status.id == value, orElse: () => unknown);

  bool get isOld => this == legacy || this == deprecated || this == retired;
}

class LlmModelMetadata {
  const LlmModelMetadata({
    this.lifecycle = LlmModelLifecycle.unknown,
    this.isSnapshot = false,
  });

  final LlmModelLifecycle lifecycle;
  final bool isSnapshot;
}

class LlmModelCapabilities {
  const LlmModelCapabilities({
    required this.isKnown,
    required this.reasoningEfforts,
    this.defaultReasoningEffort,
    this.supportsReasoning = false,
  });

  final bool isKnown;
  final List<String> reasoningEfforts;
  final String? defaultReasoningEffort;
  final bool supportsReasoning;
}

class LlmProfileSettings {
  const LlmProfileSettings({
    required this.profiles,
    required this.assignments,
    required this.apiKeyConfigured,
  });

  final List<LlmProfile> profiles;
  final Map<LlmPurpose, String> assignments;
  final Map<LlmApiKeyProvider, bool> apiKeyConfigured;

  /// Keep the existing server contract, but give every purpose its own settings.
  /// Shared legacy profiles are copied, never reused between purpose cards.
  LlmProfileSettings forPurposes() {
    final byId = {for (final profile in profiles) profile.id: profile};
    final independent = <LlmProfile>[];
    for (final purpose in LlmPurpose.values) {
      final source = byId[assignments[purpose]];
      if (source == null) {
        throw FormatException('${purpose.displayName}의 AI 설정을 찾을 수 없습니다.');
      }
      independent.add(
        LlmProfile(
          id: 'purpose-${purpose.id}',
          name: purpose.displayName,
          provider: source.provider,
          model: source.model,
          updatedAt: source.updatedAt,
          contextWindowTokens: source.contextWindowTokens,
          reasoningEffort: source.reasoningEffort,
          maximumQuestionsPerRequest: source.maximumQuestionsPerRequest,
        ),
      );
    }
    return LlmProfileSettings(
      profiles: independent,
      assignments: {
        for (final purpose in LlmPurpose.values)
          purpose: 'purpose-${purpose.id}',
      },
      apiKeyConfigured: Map.of(apiKeyConfigured),
    );
  }

  Map<String, Object?> toJson({
    Map<LlmApiKeyProvider, String> apiKeys = const {},
  }) => {
    'profiles': [for (final profile in profiles) profile.toJson()],
    'assignments': {
      for (final assignment in assignments.entries)
        assignment.key.id: assignment.value,
    },
    'apiKeys': {
      for (final entry in apiKeys.entries)
        if (entry.value.trim().isNotEmpty) entry.key.id: entry.value.trim(),
    },
  };
}
