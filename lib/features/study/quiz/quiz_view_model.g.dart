// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quiz_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(QuizViewModel)
final quizViewModelProvider = QuizViewModelFamily._();

final class QuizViewModelProvider
    extends $AsyncNotifierProvider<QuizViewModel, QuizRuntimeState> {
  QuizViewModelProvider._({
    required QuizViewModelFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'quizViewModelProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$quizViewModelHash();

  @override
  String toString() {
    return r'quizViewModelProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  QuizViewModel create() => QuizViewModel();

  @override
  bool operator ==(Object other) {
    return other is QuizViewModelProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$quizViewModelHash() => r'4e33914e1218c66e3262ab462fb295f273c8429f';

final class QuizViewModelFamily extends $Family
    with
        $ClassFamilyOverride<
          QuizViewModel,
          AsyncValue<QuizRuntimeState>,
          QuizRuntimeState,
          FutureOr<QuizRuntimeState>,
          String
        > {
  QuizViewModelFamily._()
    : super(
        retry: null,
        name: r'quizViewModelProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  QuizViewModelProvider call(String sessionId) =>
      QuizViewModelProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'quizViewModelProvider';
}

abstract class _$QuizViewModel extends $AsyncNotifier<QuizRuntimeState> {
  late final _$args = ref.$arg as String;
  String get sessionId => _$args;

  FutureOr<QuizRuntimeState> build(String sessionId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<QuizRuntimeState>, QuizRuntimeState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<QuizRuntimeState>, QuizRuntimeState>,
              AsyncValue<QuizRuntimeState>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
