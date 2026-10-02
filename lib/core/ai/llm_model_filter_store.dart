import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:review_platform/domain/models/llm_model_filter.dart';

final llmModelFilterStoreProvider = Provider<LlmModelFilterStore>(
  (ref) => JsonLlmModelFilterStore(),
);

abstract interface class LlmModelFilterStore {
  Future<LlmModelFilterPreferences> read();
  Future<void> write(LlmModelFilterPreferences preferences);
}

class JsonLlmModelFilterStore implements LlmModelFilterStore {
  JsonLlmModelFilterStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;

  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}llm_model_filters.json',
    );
  }

  @override
  Future<LlmModelFilterPreferences> read() async {
    final file = await _file();
    if (!await file.exists()) return const LlmModelFilterPreferences();
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?>) {
        return const LlmModelFilterPreferences();
      }
      return LlmModelFilterPreferences.fromJson(json);
    } on FormatException {
      return const LlmModelFilterPreferences();
    }
  }

  @override
  Future<void> write(LlmModelFilterPreferences preferences) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(preferences.toJson()), flush: true);
  }
}
