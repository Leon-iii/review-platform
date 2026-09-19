// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'question_list_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(QuestionListViewModel)
final questionListViewModelProvider = QuestionListViewModelFamily._();

final class QuestionListViewModelProvider
    extends $StreamNotifierProvider<QuestionListViewModel, List<Question>> {
  QuestionListViewModelProvider._({
    required QuestionListViewModelFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'questionListViewModelProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$questionListViewModelHash();

  @override
  String toString() {
    return r'questionListViewModelProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  QuestionListViewModel create() => QuestionListViewModel();

  @override
  bool operator ==(Object other) {
    return other is QuestionListViewModelProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$questionListViewModelHash() =>
    r'bac40e90915c6f6f47284903b8f86e7ca362c1d7';

final class QuestionListViewModelFamily extends $Family
    with
        $ClassFamilyOverride<
          QuestionListViewModel,
          AsyncValue<List<Question>>,
          List<Question>,
          Stream<List<Question>>,
          String
        > {
  QuestionListViewModelFamily._()
    : super(
        retry: null,
        name: r'questionListViewModelProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  QuestionListViewModelProvider call(String folderId) =>
      QuestionListViewModelProvider._(argument: folderId, from: this);

  @override
  String toString() => r'questionListViewModelProvider';
}

abstract class _$QuestionListViewModel extends $StreamNotifier<List<Question>> {
  late final _$args = ref.$arg as String;
  String get folderId => _$args;

  Stream<List<Question>> build(String folderId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<List<Question>>, List<Question>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<List<Question>>, List<Question>>,
              AsyncValue<List<Question>>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
