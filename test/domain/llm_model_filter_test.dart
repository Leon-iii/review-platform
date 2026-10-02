import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/models/llm_model_filter.dart';
import 'package:review_platform/domain/models/llm_profile.dart';

void main() {
  LlmModelCatalog catalog(LlmProviderKind provider) => LlmModelCatalog(
    provider: provider,
    models: const [
      'current',
      'old',
      'deprecated',
      'retired',
      'snapshot',
      'unknown-2020-01-01',
    ],
    refreshedAt: DateTime.utc(2026),
    modelMetadata: const {
      'current': LlmModelMetadata(lifecycle: LlmModelLifecycle.current),
      'old': LlmModelMetadata(lifecycle: LlmModelLifecycle.legacy),
      'deprecated': LlmModelMetadata(lifecycle: LlmModelLifecycle.deprecated),
      'retired': LlmModelMetadata(lifecycle: LlmModelLifecycle.retired),
      'snapshot': LlmModelMetadata(
        lifecycle: LlmModelLifecycle.current,
        isSnapshot: true,
      ),
    },
  );

  test('기본 필터는 구형과 스냅샷을 숨기지만 미확인 모델과 현재 선택은 유지한다', () {
    const filter = LlmModelFilter();
    expect(filter.visibleModels(catalog(LlmProviderKind.openAi), 'old'), [
      'current',
      'old',
      'unknown-2020-01-01',
    ]);
    expect(filter.visibleModels(catalog(LlmProviderKind.openAi), 'snapshot'), [
      'current',
      'snapshot',
      'unknown-2020-01-01',
    ]);
  });

  test('구형과 날짜별 버전 필터는 독립적이며 Provider에 종속되지 않는다', () {
    for (final provider in LlmProviderKind.values) {
      final value = catalog(provider);
      expect(const LlmModelFilter(hideOld: false).visibleModels(value, ''), [
        'current',
        'old',
        'deprecated',
        'retired',
        'unknown-2020-01-01',
      ]);
      expect(
        const LlmModelFilter(hideSnapshots: false).visibleModels(value, ''),
        ['current', 'snapshot', 'unknown-2020-01-01'],
      );
      expect(
        const LlmModelFilter(
          hideOld: false,
          hideSnapshots: false,
        ).visibleModels(value, ''),
        value.models,
      );
    }
  });

  test('향후 Provider 설정을 보존하며 실행 방식별 설정은 서로 영향을 주지 않는다', () {
    final initial = LlmModelFilterPreferences.fromJson({
      'providers': {
        'gemini': {'hideOld': false, 'hideSnapshots': true},
      },
    });
    final updated = initial.withProvider(
      'openai',
      const LlmModelFilter(hideSnapshots: false),
    );
    final restored = LlmModelFilterPreferences.fromJson(updated.toJson());
    expect(restored.forProvider('gemini').hideOld, isFalse);
    expect(restored.forProvider('openai').hideOld, isTrue);
    expect(restored.forProvider('openai').hideSnapshots, isFalse);
    expect(restored.forProvider('claude').hideOld, isTrue);
    expect(
      LlmModelLifecycle.fromId('future-status'),
      LlmModelLifecycle.unknown,
    );
  });
}
