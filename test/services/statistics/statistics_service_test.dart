import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/statistics/statistics_service.dart';

void main() {
  test(
    'uses weighted productivity, deep-work count, and high-efficiency time',
    () {
      final start = DateTime.utc(2026, 7, 10, 8);
      final cards = [
        _card(
          start: start,
          end: start.add(const Duration(hours: 1)),
          category: '编程',
          score: 90,
        ),
        _card(
          start: start.add(const Duration(hours: 1)),
          end: start.add(const Duration(hours: 1, minutes: 30)),
          category: '会议',
          score: 50,
        ),
      ];

      final result = const StatisticsService().calculate(
        cards: cards,
        rangeStart: start,
        rangeEnd: start.add(const Duration(days: 1)),
      );

      expect(result.totalMinutes, 90);
      expect(result.weightedProductivity, closeTo(76.666, 0.01));
      expect(result.deepWorkCount, 1);
      expect(result.highEfficiencyMinutes, 60);
      expect(result.categoryMinutes, {'编程': 60, '会议': 30});
    },
  );

  test('splits a cross-midnight interval into local calendar days', () {
    final localStart = DateTime(2026, 7, 10, 23, 30);
    final localEnd = DateTime(2026, 7, 11, 0, 30);

    final result = const StatisticsService().calculate(
      cards: [
        _card(
          start: localStart.toUtc(),
          end: localEnd.toUtc(),
          category: '学习',
          score: 80,
        ),
      ],
      rangeStart: DateTime(2026, 7, 10),
      rangeEnd: DateTime(2026, 7, 12),
    );

    expect(result.dailyMinutes[DateTime(2026, 7, 10)], 30);
    expect(result.dailyMinutes[DateTime(2026, 7, 11)], 30);
    expect(result.dailyCategoryMinutes[DateTime(2026, 7, 10)], {'学习': 30});
    expect(result.dailyWeightedProductivity[DateTime(2026, 7, 11)], 80);
  });

  test('splits duration and weighted score across actual local hours', () {
    final start = DateTime(2026, 7, 10, 9, 30);
    final end = DateTime(2026, 7, 10, 10, 30);

    final result = const StatisticsService().calculate(
      cards: [
        _card(
          start: start.toUtc(),
          end: end.toUtc(),
          category: '编程',
          score: 75,
        ),
      ],
      rangeStart: DateTime(2026, 7, 10),
      rangeEnd: DateTime(2026, 7, 11),
    );

    expect(result.hourlyEfficiency[9].durationMinutes, 30);
    expect(result.hourlyEfficiency[10].durationMinutes, 30);
    expect(result.hourlyEfficiency[9].weightedProductivity, 75);
    expect(result.hourlyEfficiency[8].durationMinutes, 0);
  });

  test('loads an equally long previous period for comparisons', () {
    final currentStart = DateTime(2026, 7, 10);
    final currentEnd = DateTime(2026, 7, 12);
    final cards = [
      _card(
        start: DateTime(2026, 7, 10, 8).toUtc(),
        end: DateTime(2026, 7, 10, 9).toUtc(),
        category: '工作',
        score: 90,
      ),
      _card(
        start: DateTime(2026, 7, 11, 8).toUtc(),
        end: DateTime(2026, 7, 11, 9).toUtc(),
        category: '工作',
        score: 70,
      ),
      _card(
        start: DateTime(2026, 7, 9, 8).toUtc(),
        end: DateTime(2026, 7, 9, 9).toUtc(),
        category: '学习',
        score: 40,
      ),
    ];

    final result = const StatisticsService().calculate(
      cards: cards,
      rangeStart: currentStart,
      rangeEnd: currentEnd,
    );

    expect(result.current.totalMinutes, 120);
    expect(result.previous.totalMinutes, 60);
    expect(result.current.weightedProductivity, 80);
    expect(result.previous.weightedProductivity, 40);
    expect(result.totalDurationComparison.percentChange, 100);
    expect(result.activityComparison.difference, 1);
  });

  test('normalizes application totals so they cannot exceed card duration', () {
    final start = DateTime(2026, 7, 10, 8);
    final result = const StatisticsService().calculate(
      cards: [
        _card(
          start: start.toUtc(),
          end: start.add(const Duration(hours: 1)).toUtc(),
          category: '工作',
          score: 80,
          appUsages: [
            AppUsage(name: 'Editor', durationMs: 90 * 60 * 1000),
            AppUsage(name: 'Browser', durationMs: 30 * 60 * 1000),
          ],
        ),
      ],
      rangeStart: DateTime(2026, 7, 10),
      rangeEnd: DateTime(2026, 7, 11),
    );

    expect(result.topApps, hasLength(2));
    expect(result.topApps.first.name, 'Editor');
    expect(result.topApps.first.durationMinutes, 45);
    expect(result.topApps.last.durationMinutes, 15);
    expect(
      result.topApps.fold<double>(0, (sum, app) => sum + app.durationMinutes),
      lessThanOrEqualTo(result.totalMinutes),
    );
  });

  test(
    'app ranking keeps a recorded executable path without changing totals',
    () {
      final start = DateTime(2026, 7, 10, 9);
      final result = const StatisticsService().calculate(
        cards: [
          _card(
            start: start.toUtc(),
            end: start.add(const Duration(hours: 1)).toUtc(),
            category: '工作',
            score: 80,
            appUsages: [
              AppUsage(
                name: 'Editor',
                durationMs: 30 * 60 * 1000,
                executablePath: r'C:\Apps\Editor.exe',
              ),
              AppUsage(name: 'Editor', durationMs: 30 * 60 * 1000),
            ],
          ),
        ],
        rangeStart: DateTime(2026, 7, 10),
        rangeEnd: DateTime(2026, 7, 11),
      );

      expect(result.topApps, hasLength(1));
      expect(result.topApps.single.durationMinutes, 60);
      expect(result.topApps.single.executablePath, r'C:\Apps\Editor.exe');
      expect(result.activeApplicationCount, 1);
    },
  );

  test('empty ranges return stable zeroed dashboard data', () {
    final result = const StatisticsService().calculate(
      cards: const [],
      rangeStart: DateTime(2026, 7, 1),
      rangeEnd: DateTime(2026, 7, 8),
    );

    expect(result.totalMinutes, 0);
    expect(result.weightedProductivity, 0);
    expect(result.previous.totalMinutes, 0);
    expect(result.hourlyEfficiency, hasLength(24));
    expect(
      result.hourlyEfficiency.every((item) => item.durationMinutes == 0),
      isTrue,
    );
    expect(result.recentDailyCategoryMinutes, hasLength(14));
    expect(result.topApps, isEmpty);
  });
}

TimelineCard _card({
  required DateTime start,
  required DateTime end,
  required String category,
  required double score,
  List<AppUsage> appUsages = const [],
}) {
  return TimelineCard(
    reportDate: '2026-07-10',
    category: category,
    title: '活动',
    summary: '',
    startedAtMs: start.millisecondsSinceEpoch,
    endedAtMs: end.millisecondsSinceEpoch,
    appUsages: appUsages,
    distractions: const [],
    productivityScore: score,
    createdAtMs: start.millisecondsSinceEpoch,
    updatedAtMs: start.millisecondsSinceEpoch,
  );
}
