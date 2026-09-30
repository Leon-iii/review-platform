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
  documentVision('documentVision', 'PDF 이미지 OCR');

  const LlmPurpose(this.id, this.displayName);

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
  });

  final String id;
  final String name;
  final LlmProviderKind provider;
  final String model;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.id,
    'model': model,
  };
}

class LlmModelCatalog {
  const LlmModelCatalog({
    required this.provider,
    required this.models,
    required this.refreshedAt,
  });

  final LlmProviderKind provider;
  final List<String> models;
  final DateTime refreshedAt;
}

class LlmProfileSettings {
  const LlmProfileSettings({required this.profiles, required this.assignments});

  final List<LlmProfile> profiles;
  final Map<LlmPurpose, String> assignments;

  Map<String, Object?> toJson() => {
    'profiles': [for (final profile in profiles) profile.toJson()],
    'assignments': {
      for (final assignment in assignments.entries)
        assignment.key.id: assignment.value,
    },
  };
}
