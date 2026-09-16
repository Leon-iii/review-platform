// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'question_editor_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(QuestionEditorViewModel)
final questionEditorViewModelProvider = QuestionEditorViewModelFamily._();

final class QuestionEditorViewModelProvider
    extends $AsyncNotifierProvider<QuestionEditorViewModel, Question?> {
  QuestionEditorViewModelProvider._({
    required QuestionEditorViewModelFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'questionEditorViewModelProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$questionEditorViewModelHash();

  @override
  String toString() {
    return r'questionEditorViewModelProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  QuestionEditorViewModel create() => QuestionEditorViewModel();

  @override
  bool operator ==(Object other) {
    return other is QuestionEditorViewModelProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$questionEditorViewModelHash() =>
    r'1ad6910c74945f9436c8a07020da165fbf04009d';

final class QuestionEditorViewModelFamily extends $Family
    with
        $ClassFamilyOverride<
          QuestionEditorViewModel,
          AsyncValue<Question?>,
          Question?,
          FutureOr<Question?>,
          String?
        > {
  QuestionEditorViewModelFamily._()
    : super(
        retry: null,
        name: r'questionEditorViewModelProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  QuestionEditorViewModelProvider call(String? questionId) =>
      QuestionEditorViewModelProvider._(argument: questionId, from: this);

  @override
  String toString() => r'questionEditorViewModelProvider';
}

abstract class _$QuestionEditorViewModel extends $AsyncNotifier<Question?> {
  late final _$args = ref.$arg as String?;
  String? get questionId => _$args;

  FutureOr<Question?> build(String? questionId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<Question?>, Question?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<Question?>, Question?>,
              AsyncValue<Question?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
