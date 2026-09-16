// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quiz_result_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(quizResult)
final quizResultProvider = QuizResultFamily._();

final class QuizResultProvider
    extends
        $FunctionalProvider<
          AsyncValue<QuizResultSummary>,
          QuizResultSummary,
          FutureOr<QuizResultSummary>
        >
    with
        $FutureModifier<QuizResultSummary>,
        $FutureProvider<QuizResultSummary> {
  QuizResultProvider._({
    required QuizResultFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'quizResultProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$quizResultHash();

  @override
  String toString() {
    return r'quizResultProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<QuizResultSummary> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<QuizResultSummary> create(Ref ref) {
    final argument = this.argument as String;
    return quizResult(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is QuizResultProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$quizResultHash() => r'8d28ff37157aac19a0169120aced268168ae3505';

final class QuizResultFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<QuizResultSummary>, String> {
  QuizResultFamily._()
    : super(
        retry: null,
        name: r'quizResultProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  QuizResultProvider call(String sessionId) =>
      QuizResultProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'quizResultProvider';
}
