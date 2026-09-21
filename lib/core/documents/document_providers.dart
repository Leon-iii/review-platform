import 'package:http/http.dart' as http;
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'document_providers.g.dart';

@Riverpod(keepAlive: true)
http.Client documentHttpClient(Ref ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
}

@Riverpod(keepAlive: true)
RemoteDocumentApi remoteDocumentApi(Ref ref) {
  return HttpRemoteDocumentApi(ref.watch(documentHttpClientProvider));
}

@Riverpod(keepAlive: true)
DocumentPicker documentPicker(Ref ref) => FilePickerDocumentPicker();
