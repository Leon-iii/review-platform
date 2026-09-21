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
  const LocalServerConfig({required this.port, required this.autoStart});

  const LocalServerConfig.defaults() : port = 5080, autoStart = true;

  final int port;
  final bool autoStart;

  String get localAddress => 'http://127.0.0.1:$port';

  Map<String, Object> toJson() => {'port': port, 'autoStart': autoStart};

  factory LocalServerConfig.fromJson(Map<String, Object?> json) {
    final port = json['port'];
    final autoStart = json['autoStart'];
    return LocalServerConfig(
      port: port is int && port >= 1 && port <= 65535
          ? port
          : const LocalServerConfig.defaults().port,
      autoStart: autoStart is bool
          ? autoStart
          : const LocalServerConfig.defaults().autoStart,
    );
  }
}
