import 'dart:math' as math;

import '../../core/domain/domain.dart';

final class MetricComparison {
  const MetricComparison({required this.current, required this.previous});

  final double current;
  final double previous;

  double get difference => current - previous;

  double? get percentChange {
    if (previous == 0) return current == 0 ? 0 : null;
    return difference / previous * 100;
  }
}

final class PeriodStatistics {
  const PeriodStatistics({
    required this.totalMinutes,
    required this.weightedProductivity,
    required this.activityCount,
    required this.deepWorkCount,
    required this.highEfficiencyMinutes,
    required this.categoryMinutes,
  });

  final double totalMinutes;
  final double weightedProductivity;
  final int activityCount;
  final int deepWorkCount;
  final double highEfficiencyMinutes;
  final Map<String, double> categoryMinutes;
}

final class HourEfficiencyStatistics {
  const HourEfficiencyStatistics({
    required this.hour,
    required this.durationMinutes,
    required this.weightedProductivity,
  });

  final int hour;
  final double durationMinutes;
  final double weightedProductivity;
}

final class AppUsageStatistics {
  const AppUsageStatistics({
    required this.name,
    required this.durationMinutes,
    required this.share,
  });

  final String name;
  final double durationMinutes;
  final double share;
}

final class ActivityStatistics {
  const ActivityStatistics({
    required this.current,
    required this.previous,
    required this.dailyCategoryMinutes,
    required this.dailyWeightedProductivity,
    required this.categoryShares,
    required this.hourlyEfficiency,
    required this.topApps,
    required this.thisWeek,
    required this.lastWeek,
    required this.weeklyCategoryDifference,
    required this.recentDailyCategoryMinutes,
    required this.todayMinutes,
  });

  final PeriodStatistics current;
  final PeriodStatistics previous;
  final Map<DateTime, Map<String, double>> dailyCategoryMinutes;
  final Map<DateTime, double> dailyWeightedProductivity;
  final Map<String, double> categoryShares;
  final List<HourEfficiencyStatistics> hourlyEfficiency;
  final List<AppUsageStatistics> topApps;
  final PeriodStatistics thisWeek;
  final PeriodStatistics lastWeek;
  final Map<String, double> weeklyCategoryDifference;
  final Map<DateTime, Map<String, double>> recentDailyCategoryMinutes;
  final double todayMinutes;

  double get totalMinutes => current.totalMinutes;
  double get weightedProductivity => current.weightedProductivity;
  int get activityCount => current.activityCount;
  int get deepWorkCount => current.deepWorkCount;
  double get highEfficiencyMinutes => current.highEfficiencyMinutes;

  // Kept for callers from pre-dashboard builds. High-efficiency duration is
  // now displayed separately from the >= 60 minute deep-work count.
  double get deepWorkMinutes => highEfficiencyMinutes;

  Map<String, double> get categoryMinutes => current.categoryMinutes;

  Map<DateTime, double> get dailyMinutes => Map<DateTime, double>.unmodifiable(
    dailyCategoryMinutes.map(
      (day, categories) => MapEntry(
        day,
        categories.values.fold<double>(0, (sum, value) => sum + value),
      ),
    ),
  );

  MetricComparison get totalDurationComparison => MetricComparison(
    current: current.totalMinutes,
    previous: previous.totalMinutes,
  );

  MetricComparison get productivityComparison => MetricComparison(
    current: current.weightedProductivity,
    previous: previous.weightedProductivity,
  );

  MetricComparison get deepWorkComparison => MetricComparison(
    current: current.deepWorkCount.toDouble(),
    previous: previous.deepWorkCount.toDouble(),
  );

  MetricComparison get activityComparison => MetricComparison(
    current: current.activityCount.toDouble(),
    previous: previous.activityCount.toDouble(),
  );
}

final class StatisticsService {
  const StatisticsService();

  ActivityStatistics calculate({
    required List<TimelineCard> cards,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) {
    if (!rangeEnd.isAfter(rangeStart)) {
      throw ArgumentError('统计结束时间必须晚于开始时间');
    }
    final startMs = rangeStart.toUtc().millisecondsSinceEpoch;
    final endMs = rangeEnd.toUtc().millisecondsSinceEpoch;
    final rangeMs = endMs - startMs;
    final previousStartMs = startMs - rangeMs;

    final dailyCategoryMs = <DateTime, Map<String, int>>{};
    final dailyWeightedScore = <DateTime, double>{};
    final dailyScoreDurationMs = <DateTime, int>{};
    _initializeLocalDays(rangeStart, rangeEnd, dailyCategoryMs);

    final hourlyDurationMs = List<int>.filled(24, 0);
    final hourlyWeightedScore = List<double>.filled(24, 0);
    final appDurationMs = <String, int>{};
    final appDisplayNames = <String, String>{};

    final current = _summarize(
      cards,
      startMs,
      endMs,
      onSegment: (card, segmentStartMs, segmentEndMs) {
        _splitAcrossLocalDays(
          card: card,
          startMs: segmentStartMs,
          endMs: segmentEndMs,
          categoryTarget: dailyCategoryMs,
          weightedScoreTarget: dailyWeightedScore,
          scoreDurationTarget: dailyScoreDurationMs,
        );
        _splitAcrossLocalHours(
          card: card,
          startMs: segmentStartMs,
          endMs: segmentEndMs,
          durationTarget: hourlyDurationMs,
          weightedScoreTarget: hourlyWeightedScore,
        );
        _accumulateAppUsage(
          card: card,
          clippedDurationMs: segmentEndMs - segmentStartMs,
          durationTarget: appDurationMs,
          displayNames: appDisplayNames,
        );
      },
    );
    final previous = _summarize(cards, previousStartMs, startMs);

    final referenceDay = DateTime.fromMillisecondsSinceEpoch(endMs - 1);
    final weekStart = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day - (referenceDay.weekday - DateTime.monday),
    );
    final weekStartMs = weekStart.toUtc().millisecondsSinceEpoch;
    final lastWeekStartMs = weekStart
        .subtract(const Duration(days: 7))
        .toUtc()
        .millisecondsSinceEpoch;
    final thisWeek = _summarize(cards, weekStartMs, endMs);
    final lastWeek = _summarize(cards, lastWeekStartMs, weekStartMs);

    final weeklyCategories = <String>{
      ...thisWeek.categoryMinutes.keys,
      ...lastWeek.categoryMinutes.keys,
    };
    final weeklyDifference = <String, double>{
      for (final category in weeklyCategories)
        category:
            (thisWeek.categoryMinutes[category] ?? 0) -
            (lastWeek.categoryMinutes[category] ?? 0),
    };

    final recentStart = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day - 13,
    );
    final recentCategoryMs = <DateTime, Map<String, int>>{};
    _initializeLocalDays(
      recentStart,
      DateTime(referenceDay.year, referenceDay.month, referenceDay.day + 1),
      recentCategoryMs,
    );
    _summarize(
      cards,
      recentStart.toUtc().millisecondsSinceEpoch,
      endMs,
      onSegment: (card, segmentStartMs, segmentEndMs) {
        _splitAcrossLocalDays(
          card: card,
          startMs: segmentStartMs,
          endMs: segmentEndMs,
          categoryTarget: recentCategoryMs,
        );
      },
    );

    final categoryShares = <String, double>{
      for (final entry in current.categoryMinutes.entries)
        entry.key: current.totalMinutes == 0
            ? 0
            : entry.value / current.totalMinutes,
    };
    final appTotalMs = appDurationMs.values.fold<int>(0, (sum, value) {
      return sum + value;
    });
    final topApps =
        appDurationMs.entries
            .map(
              (entry) => AppUsageStatistics(
                name: appDisplayNames[entry.key]!,
                durationMinutes: entry.value / Duration.millisecondsPerMinute,
                share: appTotalMs == 0 ? 0 : entry.value / appTotalMs,
              ),
            )
            .toList()
          ..sort(
            (left, right) =>
                right.durationMinutes.compareTo(left.durationMinutes),
          );

    final today = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day,
    );
    final todayCategoryMs = recentCategoryMs[today] ?? const <String, int>{};

    return ActivityStatistics(
      current: current,
      previous: previous,
      dailyCategoryMinutes: _minutesByDay(dailyCategoryMs),
      dailyWeightedProductivity: Map<DateTime, double>.unmodifiable(
        dailyCategoryMs.map((day, _) {
          final duration = dailyScoreDurationMs[day] ?? 0;
          return MapEntry(
            day,
            duration == 0 ? 0.0 : (dailyWeightedScore[day] ?? 0) / duration,
          );
        }),
      ),
      categoryShares: Map<String, double>.unmodifiable(categoryShares),
      hourlyEfficiency: List<HourEfficiencyStatistics>.unmodifiable(
        List<HourEfficiencyStatistics>.generate(24, (hour) {
          final duration = hourlyDurationMs[hour];
          return HourEfficiencyStatistics(
            hour: hour,
            durationMinutes: duration / Duration.millisecondsPerMinute,
            weightedProductivity: duration == 0
                ? 0
                : hourlyWeightedScore[hour] / duration,
          );
        }),
      ),
      topApps: List<AppUsageStatistics>.unmodifiable(topApps.take(10)),
      thisWeek: thisWeek,
      lastWeek: lastWeek,
      weeklyCategoryDifference: Map<String, double>.unmodifiable(
        weeklyDifference,
      ),
      recentDailyCategoryMinutes: _minutesByDay(recentCategoryMs),
      todayMinutes:
          todayCategoryMs.values.fold<int>(0, (sum, value) {
            return sum + value;
          }) /
          Duration.millisecondsPerMinute,
    );
  }

  static PeriodStatistics _summarize(
    List<TimelineCard> cards,
    int startMs,
    int endMs, {
    void Function(TimelineCard card, int startMs, int endMs)? onSegment,
  }) {
    var totalMs = 0;
    var weightedScore = 0.0;
    var highEfficiencyMs = 0;
    var activityCount = 0;
    var deepWorkCount = 0;
    final categoryMs = <String, int>{};
    for (final card in cards) {
      final clippedStart = math.max(card.startedAtMs, startMs);
      final clippedEnd = math.min(card.endedAtMs, endMs);
      if (clippedEnd <= clippedStart) continue;
      final durationMs = clippedEnd - clippedStart;
      totalMs += durationMs;
      weightedScore += card.productivityScore * durationMs;
      activityCount++;
      if (durationMs >= Duration.millisecondsPerHour) deepWorkCount++;
      if (card.productivityScore >= 80) highEfficiencyMs += durationMs;
      categoryMs.update(
        card.category,
        (value) => value + durationMs,
        ifAbsent: () => durationMs,
      );
      onSegment?.call(card, clippedStart, clippedEnd);
    }
    return PeriodStatistics(
      totalMinutes: totalMs / Duration.millisecondsPerMinute,
      weightedProductivity: totalMs == 0 ? 0 : weightedScore / totalMs,
      activityCount: activityCount,
      deepWorkCount: deepWorkCount,
      highEfficiencyMinutes: highEfficiencyMs / Duration.millisecondsPerMinute,
      categoryMinutes: Map<String, double>.unmodifiable(
        categoryMs.map(
          (key, value) => MapEntry(key, value / Duration.millisecondsPerMinute),
        ),
      ),
    );
  }

  static void _initializeLocalDays(
    DateTime start,
    DateTime end,
    Map<DateTime, Map<String, int>> target,
  ) {
    var cursor = DateTime(start.year, start.month, start.day);
    final boundary = DateTime(end.year, end.month, end.day);
    while (cursor.isBefore(boundary)) {
      target.putIfAbsent(cursor, () => <String, int>{});
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
  }

  static void _splitAcrossLocalDays({
    required TimelineCard card,
    required int startMs,
    required int endMs,
    required Map<DateTime, Map<String, int>> categoryTarget,
    Map<DateTime, double>? weightedScoreTarget,
    Map<DateTime, int>? scoreDurationTarget,
  }) {
    var cursorMs = startMs;
    while (cursorMs < endMs) {
      final local = DateTime.fromMillisecondsSinceEpoch(cursorMs);
      final day = DateTime(local.year, local.month, local.day);
      final nextDayMs = DateTime(
        local.year,
        local.month,
        local.day + 1,
      ).toUtc().millisecondsSinceEpoch;
      final segmentEndMs = math.min(endMs, nextDayMs);
      final segmentMs = segmentEndMs - cursorMs;
      final categories = categoryTarget.putIfAbsent(day, () => <String, int>{});
      categories.update(
        card.category,
        (value) => value + segmentMs,
        ifAbsent: () => segmentMs,
      );
      weightedScoreTarget?.update(
        day,
        (value) => value + card.productivityScore * segmentMs,
        ifAbsent: () => card.productivityScore * segmentMs,
      );
      scoreDurationTarget?.update(
        day,
        (value) => value + segmentMs,
        ifAbsent: () => segmentMs,
      );
      cursorMs = segmentEndMs;
    }
  }

  static void _splitAcrossLocalHours({
    required TimelineCard card,
    required int startMs,
    required int endMs,
    required List<int> durationTarget,
    required List<double> weightedScoreTarget,
  }) {
    var cursorMs = startMs;
    while (cursorMs < endMs) {
      final local = DateTime.fromMillisecondsSinceEpoch(cursorMs);
      final nextHourMs = DateTime(
        local.year,
        local.month,
        local.day,
        local.hour + 1,
      ).toUtc().millisecondsSinceEpoch;
      final segmentEndMs = math.min(endMs, nextHourMs);
      final segmentMs = segmentEndMs - cursorMs;
      durationTarget[local.hour] += segmentMs;
      weightedScoreTarget[local.hour] += card.productivityScore * segmentMs;
      cursorMs = segmentEndMs;
    }
  }

  static void _accumulateAppUsage({
    required TimelineCard card,
    required int clippedDurationMs,
    required Map<String, int> durationTarget,
    required Map<String, String> displayNames,
  }) {
    if (card.appUsages.isEmpty || clippedDurationMs <= 0) return;
    final fullDurationMs = card.durationMs;
    if (fullDurationMs <= 0) return;
    final clippedScale = clippedDurationMs / fullDurationMs;
    final scaled = <({String name, String key, double durationMs})>[];
    var scaledTotal = 0.0;
    for (final usage in card.appUsages) {
      if (usage.durationMs <= 0) continue;
      final duration = usage.durationMs * clippedScale;
      final key = usage.name.trim().toLowerCase();
      if (key.isEmpty) continue;
      scaled.add((name: usage.name, key: key, durationMs: duration));
      scaledTotal += duration;
    }
    if (scaledTotal <= 0) return;
    final normalization = math.min(1.0, clippedDurationMs / scaledTotal);
    var remainingMs = clippedDurationMs;
    for (final usage in scaled) {
      final normalizedDuration = math.min(
        remainingMs,
        (usage.durationMs * normalization).round(),
      );
      if (normalizedDuration <= 0) continue;
      displayNames.putIfAbsent(usage.key, () => usage.name);
      durationTarget.update(
        usage.key,
        (value) => value + normalizedDuration,
        ifAbsent: () => normalizedDuration,
      );
      remainingMs -= normalizedDuration;
      if (remainingMs <= 0) break;
    }
  }

  static Map<DateTime, Map<String, double>> _minutesByDay(
    Map<DateTime, Map<String, int>> source,
  ) => Map<DateTime, Map<String, double>>.unmodifiable(
    source.map(
      (day, categories) => MapEntry(
        day,
        Map<String, double>.unmodifiable(
          categories.map(
            (category, milliseconds) => MapEntry(
              category,
              milliseconds / Duration.millisecondsPerMinute,
            ),
          ),
        ),
      ),
    ),
  );
}
