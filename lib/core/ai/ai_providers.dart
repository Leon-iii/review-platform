import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ai_providers.g.dart';

@Riverpod(keepAlive: true)
RemoteAiApi remoteAiApi(Ref ref) {
  return HttpRemoteAiApi(ref.watch(syncHttpClientProvider));
}
