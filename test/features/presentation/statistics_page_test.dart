import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/features/presentation/app_theme.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/features/presentation/pages/statistics_page.dart';

void main() {
  testWidgets('one day range is labeled as a rolling 24 hour period', (
    tester,
  ) async {
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(),
      statisticsDays: 1,
    );

    await tester.pumpWidget(_host(viewModel));

    expect(find.text('近 1 天'), findsOneWidget);
    expect(find.textContaining('最近 24 小时'), findsOneWidget);
    expect(find.textContaining('按本地日期'), findsNothing);
  });

  testWidgets('calendar day ranges retain their local date description', (
    tester,
  ) async {
    final viewModel = _StatisticsViewModel(statistics: _statistics());

    await tester.pumpWidget(_host(viewModel));

    expect(find.text('近 7 天'), findsOneWidget);
    expect(find.text('近 30 天'), findsOneWidget);
    expect(find.textContaining('按本地日期'), findsOneWidget);
  });

  testWidgets('daily chart uses hover details instead of a permanent legend', (
    tester,
  ) async {
    final day = DateTime(2026, 7, 10);
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        dailyCategoryMinutes: {
          day: const {'编程': 60},
        },
      ),
    );
    await tester.pumpWidget(_host(viewModel));

    final section = find.byKey(const ValueKey('daily-category-section'));
    final chart = find.byKey(const ValueKey('daily-category-chart'));
    expect(section, findsOneWidget);
    expect(
      find.descendant(of: section, matching: find.text('编程')),
      findsNothing,
    );

    await tester.ensureVisible(chart);
    await tester.pumpAndSettle();
    final box = tester.getRect(chart);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: box.topLeft - const Offset(4, 4));

    await mouse.moveTo(Offset(box.left + 2, box.center.dy));
    await tester.pump();
    expect(find.byKey(const ValueKey('daily-category-tooltip')), findsNothing);

    await mouse.moveTo(Offset(box.center.dx + 16, box.center.dy));
    await tester.pump();
    expect(find.text('2026年7月10日 · 编程'), findsOneWidget);
    expect(find.text('1 小时 · 当日 100%'), findsOneWidget);

    await mouse.moveTo(Offset(box.center.dx, box.bottom - 2));
    await tester.pump();
    expect(find.byKey(const ValueKey('daily-category-tooltip')), findsNothing);

    await mouse.moveTo(box.bottomRight + const Offset(8, 8));
    await tester.pump();
    expect(find.byKey(const ValueKey('daily-category-tooltip')), findsNothing);
  });

  testWidgets('daily chart handles empty and zero duration data safely', (
    tester,
  ) async {
    final day = DateTime(2026, 7, 10);
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        dailyCategoryMinutes: {
          day: const {'编程': 0},
        },
      ),
    );
    await tester.pumpWidget(_host(viewModel));

    final chart = find.byKey(const ValueKey('daily-category-chart'));
    await tester.ensureVisible(chart);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(chart));
    await tester.pump();

    expect(find.byKey(const ValueKey('daily-category-tooltip')), findsNothing);
    expect(find.textContaining('NaN'), findsNothing);
    expect(find.textContaining('Infinity'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily chart exposes category details without mouse hover', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final day = DateTime(2026, 7, 10);
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        dailyCategoryMinutes: {
          day: const {'编程': 45, '会议': 15},
        },
      ),
    );
    await tester.pumpWidget(_host(viewModel));

    final chart = find.byKey(const ValueKey('daily-category-chart'));
    await tester.ensureVisible(chart);
    await tester.pumpAndSettle();

    final traversal = tester.semantics.simulatedAccessibilityTraversal();
    expect(
      traversal,
      containsAll(<Matcher>[
        isSemantics(label: '2026年7月10日，编程，45 分钟，当日 75%'),
        isSemantics(label: '2026年7月10日，会议，15 分钟，当日 25%'),
      ]),
    );

    final box = tester.getRect(chart);
    await tester.tapAt(Offset(box.center.dx + 16, box.center.dy));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('daily-category-tooltip')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('application ranking shows decoded icons and stable fallbacks', (
    tester,
  ) async {
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        topApps: const [
          StatisticsAppViewData(
            name: 'Editor',
            durationMinutes: 90,
            share: .75,
            executablePath: r'C:\Apps\Editor.exe',
          ),
          StatisticsAppViewData(
            name: 'Removed App',
            durationMinutes: 30,
            share: .25,
          ),
        ],
      ),
      iconResults: {
        r'C:\Apps\Editor.exe': Future<Uint8List?>.value(_onePixelPng),
      },
    );
    await tester.pumpWidget(_host(viewModel));
    await _showApplicationRanking(tester);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('statistics-app-icon-Editor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('statistics-app-icon-fallback-Removed App')),
      findsOneWidget,
    );
    expect(find.text(r'C:\Apps\Editor.exe'), findsNothing);
    expect(find.text('75%'), findsOneWidget);
  });

  testWidgets('application icon future is reused across rebuilds', (
    tester,
  ) async {
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        topApps: const [
          StatisticsAppViewData(
            name: 'Editor',
            durationMinutes: 60,
            share: 1,
            executablePath: r'C:\Apps\Editor.exe',
          ),
        ],
      ),
      iconResults: {
        r'C:\Apps\Editor.exe': Future<Uint8List?>.value(_onePixelPng),
      },
    );
    await tester.pumpWidget(_host(viewModel));
    await _showApplicationRanking(tester);
    await tester.pump();
    await tester.pumpWidget(_host(viewModel));
    await _showApplicationRanking(tester);
    await tester.pump();

    expect(viewModel.iconRequests, [r'C:\Apps\Editor.exe']);
  });

  testWidgets('late icon completion after dispose is ignored', (tester) async {
    final icon = Completer<Uint8List?>();
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        topApps: const [
          StatisticsAppViewData(
            name: 'Editor',
            durationMinutes: 60,
            share: 1,
            executablePath: r'C:\Apps\Editor.exe',
          ),
        ],
      ),
      iconResults: {r'C:\Apps\Editor.exe': icon.future},
    );
    await tester.pumpWidget(_host(viewModel));
    await _showApplicationRanking(tester);
    await tester.pumpWidget(const SizedBox());
    icon.complete(_onePixelPng);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('overview KPIs come from view data and narrow layout is safe', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = _StatisticsViewModel(
      statistics: _statistics(
        totalMinutes: 150,
        weightedProductivity: 87,
        activityCount: 4,
        activeApplicationCount: 12,
        topApps: const [
          StatisticsAppViewData(name: 'Editor', durationMinutes: 90, share: .6),
          StatisticsAppViewData(
            name: 'Browser',
            durationMinutes: 60,
            share: .4,
          ),
        ],
      ),
    );
    await tester.pumpWidget(_host(viewModel));

    expect(find.text('统计概览'), findsOneWidget);
    expect(find.text('2 小时 30 分钟'), findsOneWidget);
    expect(find.text('87 分'), findsOneWidget);
    expect(find.text('12 个'), findsOneWidget);
    expect(find.text('4 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(_StatisticsViewModel viewModel) => MaterialApp(
  theme: QiDayFlowTheme.light(),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: StatisticsPage(
        key: const ValueKey('statistics-page'),
        viewModel: viewModel,
      ),
    ),
  ),
);

Future<void> _showApplicationRanking(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.text('应用使用排行'),
    find.byType(ListView),
    const Offset(0, -500),
  );
  await tester.pump();
}

StatisticsViewData _statistics({
  double totalMinutes = 60,
  double weightedProductivity = 80,
  int activityCount = 1,
  int activeApplicationCount = 0,
  Map<DateTime, Map<String, double>> dailyCategoryMinutes = const {},
  List<StatisticsAppViewData> topApps = const [],
}) => StatisticsViewData(
  totalMinutes: totalMinutes,
  weightedProductivity: weightedProductivity,
  activityCount: activityCount,
  activeApplicationCount: activeApplicationCount,
  dailyCategoryMinutes: dailyCategoryMinutes,
  dailyMinutes: {
    for (final entry in dailyCategoryMinutes.entries)
      entry.key: entry.value.values.fold<double>(
        0,
        (sum, value) => sum + value,
      ),
  },
  dailyWeightedProductivity: {
    for (final day in dailyCategoryMinutes.keys) day: weightedProductivity,
  },
  topApps: topApps,
);

final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

final class _StatisticsViewModel extends ChangeNotifier
    implements QiDayFlowViewModel {
  _StatisticsViewModel({
    required this.statistics,
    this.iconResults = const {},
    this.statisticsDays = 7,
  });

  @override
  final StatisticsViewData statistics;

  final Map<String, Future<Uint8List?>> iconResults;
  final List<String> iconRequests = [];

  @override
  int statisticsDays;

  @override
  Future<Uint8List?> loadApplicationIcon(String executablePath) {
    iconRequests.add(executablePath);
    return iconResults[executablePath] ?? Future<Uint8List?>.value();
  }

  @override
  Future<void> setStatisticsDays(int days) async {
    statisticsDays = days;
  }

  @override
  Future<void> updateDailyGoalHours(int hours) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
