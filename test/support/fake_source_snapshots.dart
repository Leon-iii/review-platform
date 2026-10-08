import 'dart:convert';
import 'dart:typed_data';

import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

import 'fake_documents.dart';

class FakeSourceSnapshotsApi extends FakeConceptRevisionApi
    implements RemoteSourceSnapshotApi {
  final calls = <(String, int)>[];
  Uint8List bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII=',
  );
  @override
  Future<Uint8List> sourceImage(
    SyncConfiguration configuration,
    String sourceId,
    int page,
  ) async {
    calls.add((sourceId, page));
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return bytes;
  }
}
