import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/models/llm_profile.dart';

void main() {
  final legacy = LlmProfileSettings(
    profiles: [
      LlmProfile(
        id: 'shared',
        name: '기존 프로필',
        provider: LlmProviderKind.openAi,
        model: 'gpt-6-luna',
        reasoningEffort: 'max',
        updatedAt: DateTime.utc(2026),
      ),
    ],
    assignments: {for (final purpose in LlmPurpose.values) purpose: 'shared'},
    apiKeyConfigured: {LlmApiKeyProvider.openAi: true},
  );

  test('shared legacy settings become four independent purpose records', () {
    final settings = legacy.forPurposes();
    expect(settings.profiles, hasLength(4));
    expect(settings.assignments.values.toSet(), hasLength(4));
    for (final purpose in LlmPurpose.values) {
      final profile = settings.profiles.singleWhere(
        (profile) => profile.id == settings.assignments[purpose],
      );
      expect(profile.name, purpose.displayName);
      expect(profile.model, 'gpt-6-luna');
      expect(profile.reasoningEffort, 'max');
      expect(identical(profile, legacy.profiles.single), isFalse);
    }
    expect(settings.apiKeyConfigured[LlmApiKeyProvider.openAi], isTrue);
    expect(legacy.assignments.values.toSet(), {'shared'});
  });

  test('normalizing already independent settings is idempotent', () {
    final settings = legacy.forPurposes();
    expect(settings.forPurposes().toJson(), settings.toJson());
  });

  test(
    'missing assignment fails without silently substituting another model',
    () {
      final broken = LlmProfileSettings(
        profiles: legacy.profiles,
        assignments: {...legacy.assignments}..remove(LlmPurpose.documentVision),
        apiKeyConfigured: legacy.apiKeyConfigured,
      );
      expect(broken.forPurposes, throwsFormatException);
    },
  );
}
