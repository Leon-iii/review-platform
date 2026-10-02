import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/ai/llm_model_filter_store.dart';
import 'package:review_platform/domain/models/llm_model_filter.dart';

void main() {
  late Directory directory;
  late JsonLlmModelFilterStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('llm-model-filters-');
    store = JsonLlmModelFilterStore(directoryProvider: () async => directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('필터는 기본 활성화되며 별도 저장소 인스턴스로 재실행 후 복구한다', () async {
    expect((await store.read()).forProvider('openai').hideOld, isTrue);
    await store.write(
      const LlmModelFilterPreferences(
        providers: {
          'openai': LlmModelFilter(hideOld: false),
          'gemini': LlmModelFilter(hideSnapshots: false),
        },
      ),
    );
    final restored = await JsonLlmModelFilterStore(
      directoryProvider: () async => directory,
    ).read();
    expect(restored.forProvider('openai').hideOld, isFalse);
    expect(restored.forProvider('gemini').hideSnapshots, isFalse);
    expect(restored.forProvider('ollama').hideOld, isTrue);
  });

  test('손상되거나 잘못된 필터 설정은 기본값으로 복구한다', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}llm_model_filters.json',
    );
    for (final contents in [
      '{broken',
      '[]',
      '{"providers": {"openai": {"hideOld": "bad"}}}',
    ]) {
      await file.writeAsString(contents);
      expect((await store.read()).forProvider('openai').hideOld, isTrue);
    }
  });
}
