// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_question_generation_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(aiGenerationFolders)
final aiGenerationFoldersProvider = AiGenerationFoldersProvider._();

final class AiGenerationFoldersProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Folder>>,
          List<Folder>,
          Stream<List<Folder>>
        >
    with $FutureModifier<List<Folder>>, $StreamProvider<List<Folder>> {
  AiGenerationFoldersProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'aiGenerationFoldersProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$aiGenerationFoldersHash();

  @$internal
  @override
  $StreamProviderElement<List<Folder>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Folder>> create(Ref ref) {
    return aiGenerationFolders(ref);
  }
}

String _$aiGenerationFoldersHash() =>
    r'1e0ff79d7a4bbc9bc4a5849fff67f7d4a939b64c';

@ProviderFor(AiQuestionGenerationController)
final aiQuestionGenerationControllerProvider =
    AiQuestionGenerationControllerFamily._();

final class AiQuestionGenerationControllerProvider
    extends
        $AsyncNotifierProvider<
          AiQuestionGenerationController,
          AiQuestionReviewState?
        > {
  AiQuestionGenerationControllerProvider._({
    required AiQuestionGenerationControllerFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'aiQuestionGenerationControllerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiQuestionGenerationControllerHash();

  @override
  String toString() {
    return r'aiQuestionGenerationControllerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  AiQuestionGenerationController create() => AiQuestionGenerationController();

  @override
  bool operator ==(Object other) {
    return other is AiQuestionGenerationControllerProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiQuestionGenerationControllerHash() =>
    r'bceae956d07fcce2a1deb12c6494c75c1efaffe9';

final class AiQuestionGenerationControllerFamily extends $Family
    with
        $ClassFamilyOverride<
          AiQuestionGenerationController,
          AsyncValue<AiQuestionReviewState?>,
          AiQuestionReviewState?,
          FutureOr<AiQuestionReviewState?>,
          String?
        > {
  AiQuestionGenerationControllerFamily._()
    : super(
        retry: null,
        name: r'aiQuestionGenerationControllerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AiQuestionGenerationControllerProvider call(String? initialFolderId) =>
      AiQuestionGenerationControllerProvider._(
        argument: initialFolderId,
        from: this,
      );

  @override
  String toString() => r'aiQuestionGenerationControllerProvider';
}

abstract class _$AiQuestionGenerationController
    extends $AsyncNotifier<AiQuestionReviewState?> {
  late final _$args = ref.$arg as String?;
  String? get initialFolderId => _$args;

  FutureOr<AiQuestionReviewState?> build(String? initialFolderId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<AsyncValue<AiQuestionReviewState?>, AiQuestionReviewState?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<AiQuestionReviewState?>,
                AiQuestionReviewState?
              >,
              AsyncValue<AiQuestionReviewState?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
