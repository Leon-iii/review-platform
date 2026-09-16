// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'statistics_view_model.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(statistics)
final statisticsProvider = StatisticsProvider._();

final class StatisticsProvider
    extends
        $FunctionalProvider<
          AsyncValue<StatisticsSummary>,
          StatisticsSummary,
          Stream<StatisticsSummary>
        >
    with
        $FutureModifier<StatisticsSummary>,
        $StreamProvider<StatisticsSummary> {
  StatisticsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'statisticsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$statisticsHash();

  @$internal
  @override
  $StreamProviderElement<StatisticsSummary> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<StatisticsSummary> create(Ref ref) {
    return statistics(ref);
  }
}

String _$statisticsHash() => r'aa00cf150001ca89f217a09c135a65d6add87ad6';
