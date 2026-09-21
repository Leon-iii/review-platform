import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';

void main() {
  test('일반 설정 JSON에는 API Key를 저장하지 않는다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'review-platform-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = JsonLocalServerConfigStore(
      directoryProvider: () async => directory,
    );
    const config = LocalServerConfig(port: 5090, autoStart: true);

    await store.write(config);
    final restored = await store.read();
    final json = jsonDecode(
      await File(
        '${directory.path}${Platform.pathSeparator}local_server_settings.json',
      ).readAsString(),
    ) as Map<String, Object?>;

    expect(restored.port, 5090);
    expect(restored.autoStart, isTrue);
    expect(json.keys, unorderedEquals(['port', 'autoStart']));
    expect(json.toString().toLowerCase(), isNot(contains('key')));
  });

  test('손상된 설정 파일은 기본값으로 복구한다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'review-platform-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await File(
      '${directory.path}${Platform.pathSeparator}local_server_settings.json',
    ).writeAsString('{broken');
    final store = JsonLocalServerConfigStore(
      directoryProvider: () async => directory,
    );

    final restored = await store.read();

    expect(restored.port, 5080);
    expect(restored.autoStart, isTrue);
  });

  test('자동 시작 값이 없는 기존 설정 파일에는 기본값을 활성화한다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'review-platform-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await File(
      '${directory.path}${Platform.pathSeparator}local_server_settings.json',
    ).writeAsString('{"port":5091}');
    final store = JsonLocalServerConfigStore(
      directoryProvider: () async => directory,
    );

    final restored = await store.read();

    expect(restored.port, 5091);
    expect(restored.autoStart, isTrue);
  });
}
