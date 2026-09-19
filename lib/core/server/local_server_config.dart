enum LocalLlmProvider {
  openAi(
    id: 'openai',
    displayName: 'OpenAI',
    secretStorageKey: 'review_platform.openai_api_key',
    secretEnvironmentKey: 'OPENAI_API_KEY',
  ),
  gemini(
    id: 'gemini',
    displayName: 'Gemini',
    secretStorageKey: 'review_platform.gemini_api_key',
    secretEnvironmentKey: 'GEMINI_API_KEY',
  ),
  ollama(
    id: 'ollama',
    displayName: 'Ollama',
    secretStorageKey: '',
    secretEnvironmentKey: '',
    requiresApiKey: false,
  );

  const LocalLlmProvider({
    required this.id,
    required this.displayName,
    required this.secretStorageKey,
    required this.secretEnvironmentKey,
    this.requiresApiKey = true,
  });

  final String id;
  final String displayName;
  final String secretStorageKey;
  final String secretEnvironmentKey;
  final bool requiresApiKey;

  static LocalLlmProvider fromId(String? value) {
    return LocalLlmProvider.values.firstWhere(
      (provider) => provider.id == value,
      orElse: () => LocalLlmProvider.ollama,
    );
  }
}

class LocalServerConfig {
  const LocalServerConfig({
    required this.provider,
    required this.model,
    required this.port,
  });

  const LocalServerConfig.defaults()
    : provider = LocalLlmProvider.ollama,
      model = 'qwen3:8b',
      port = 5080;

  final LocalLlmProvider provider;
  final String model;
  final int port;

  String get localAddress => 'http://127.0.0.1:$port';

  Map<String, Object> toJson() => {
    'provider': provider.id,
    'model': model,
    'port': port,
  };

  factory LocalServerConfig.fromJson(Map<String, Object?> json) {
    final model = json['model'];
    final port = json['port'];
    return LocalServerConfig(
      provider: LocalLlmProvider.fromId(json['provider'] as String?),
      model: model is String && model.trim().isNotEmpty
          ? model.trim()
          : const LocalServerConfig.defaults().model,
      port: port is int && port >= 1 && port <= 65535
          ? port
          : const LocalServerConfig.defaults().port,
    );
  }
}
