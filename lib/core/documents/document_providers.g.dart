// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'document_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(documentHttpClient)
final documentHttpClientProvider = DocumentHttpClientProvider._();

final class DocumentHttpClientProvider
    extends $FunctionalProvider<http.Client, http.Client, http.Client>
    with $Provider<http.Client> {
  DocumentHttpClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'documentHttpClientProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$documentHttpClientHash();

  @$internal
  @override
  $ProviderElement<http.Client> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  http.Client create(Ref ref) {
    return documentHttpClient(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(http.Client value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<http.Client>(value),
    );
  }
}

String _$documentHttpClientHash() =>
    r'd664b35cecef65188c82db23ee03b61922dfb64a';

@ProviderFor(remoteDocumentApi)
final remoteDocumentApiProvider = RemoteDocumentApiProvider._();

final class RemoteDocumentApiProvider
    extends
        $FunctionalProvider<
          RemoteDocumentApi,
          RemoteDocumentApi,
          RemoteDocumentApi
        >
    with $Provider<RemoteDocumentApi> {
  RemoteDocumentApiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'remoteDocumentApiProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$remoteDocumentApiHash();

  @$internal
  @override
  $ProviderElement<RemoteDocumentApi> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  RemoteDocumentApi create(Ref ref) {
    return remoteDocumentApi(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(RemoteDocumentApi value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<RemoteDocumentApi>(value),
    );
  }
}

String _$remoteDocumentApiHash() => r'32592df0ee88f3f756d5207d6ff27c0276d5a8a2';

@ProviderFor(documentPicker)
final documentPickerProvider = DocumentPickerProvider._();

final class DocumentPickerProvider
    extends $FunctionalProvider<DocumentPicker, DocumentPicker, DocumentPicker>
    with $Provider<DocumentPicker> {
  DocumentPickerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'documentPickerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$documentPickerHash();

  @$internal
  @override
  $ProviderElement<DocumentPicker> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  DocumentPicker create(Ref ref) {
    return documentPicker(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DocumentPicker value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DocumentPicker>(value),
    );
  }
}

String _$documentPickerHash() => r'739d31fc7762608163abd9f987b8d3d61c61600a';
