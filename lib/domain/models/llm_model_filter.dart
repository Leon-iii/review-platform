import 'package:review_platform/domain/models/llm_profile.dart';

class LlmModelFilter {
  const LlmModelFilter({this.hideOld = true, this.hideSnapshots = true});

  final bool hideOld;
  final bool hideSnapshots;

  factory LlmModelFilter.fromJson(Map<String, Object?> json) => LlmModelFilter(
    hideOld: json['hideOld'] is bool ? json['hideOld']! as bool : true,
    hideSnapshots: json['hideSnapshots'] is bool
        ? json['hideSnapshots']! as bool
        : true,
  );

  Map<String, Object?> toJson() => {
    'hideOld': hideOld,
    'hideSnapshots': hideSnapshots,
  };

  bool hides(LlmModelMetadata? metadata) =>
      metadata != null &&
      ((hideOld && metadata.lifecycle.isOld) ||
          (hideSnapshots && metadata.isSnapshot));

  List<String> visibleModels(LlmModelCatalog catalog, String selectedModel) => [
    for (final model in catalog.models)
      if (model == selectedModel || !hides(catalog.modelMetadata[model])) model,
  ];
}

// String keys retain preferences for providers not yet supported by this client.
class LlmModelFilterPreferences {
  const LlmModelFilterPreferences({this.providers = const {}});
  final Map<String, LlmModelFilter> providers;

  LlmModelFilter forProvider(String provider) =>
      providers[provider] ?? const LlmModelFilter();

  LlmModelFilterPreferences withProvider(
    String provider,
    LlmModelFilter filter,
  ) => LlmModelFilterPreferences(providers: {...providers, provider: filter});

  factory LlmModelFilterPreferences.fromJson(Map<String, Object?> json) {
    final raw = json['providers'];
    return LlmModelFilterPreferences(
      providers: {
        if (raw is Map)
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is Map)
              entry.key as String: LlmModelFilter.fromJson(
                Map<String, Object?>.from(entry.value as Map),
              ),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'providers': {
      for (final entry in providers.entries) entry.key: entry.value.toJson(),
    },
  };
}
