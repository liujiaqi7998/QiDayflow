import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/features/presentation/pages/analysis_queue_page.dart';
import 'package:qi_day_flow/features/presentation/pages/report_page.dart';

void main() {
  testWidgets(
    'old report stays visible with background progress and queue link',
    (tester) async {
      final viewModel = _PageViewModel(
        dailyReport: '# 旧日报\n仍然可读',
        reportLoading: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReportPage(viewModel: viewModel)),
        ),
      );

      expect(find.textContaining('旧日报'), findsOneWidget);
      expect(find.textContaining('后台生成中，可安全离开此页面'), findsOneWidget);
      expect(find.text('去分析队列'), findsOneWidget);
      final generate = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(generate.onPressed, isNull);

      await tester.tap(find.text('去分析队列'));
      expect(viewModel.section, AppSection.analysisQueue);
    },
  );

  testWidgets('failed regeneration stays visible on the report page', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 7, 13, 9);
    final viewModel = _PageViewModel(
      dailyReport: '# 旧日报',
      analysisQueue: AnalysisQueueViewData(
        items: <AnalysisQueueItemViewData>[
          AnalysisQueueItemViewData(
            chunkId: null,
            reportDate: '2026-07-13',
            status: ProcessingStatus.failed,
            recordedAt: now,
            recordedUntil: now,
            enqueuedAt: now,
            updatedAt: now,
            retryCount: 1,
            errorSummary: '日报生成请求超时',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportPage(viewModel: viewModel)),
      ),
    );

    expect(find.textContaining('日报生成失败：日报生成请求超时'), findsOneWidget);
    expect(find.textContaining('旧日报'), findsOneWidget);
    await tester.tap(find.text('去分析队列'));
    expect(viewModel.section, AppSection.analysisQueue);
  });

  testWidgets('report status banner remains usable at 240 pixels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(240, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _PageViewModel(reportLoading: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportPage(viewModel: viewModel)),
      ),
    );

    expect(find.text('去分析队列'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow analysis queue identifies a daily report job', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.utc(2026, 7, 13, 9);
    final viewModel = _PageViewModel(
      analysisQueue: AnalysisQueueViewData(
        items: <AnalysisQueueItemViewData>[
          AnalysisQueueItemViewData(
            chunkId: null,
            reportDate: '2026-07-13',
            status: ProcessingStatus.processing,
            recordedAt: now,
            recordedUntil: now,
            enqueuedAt: now,
            updatedAt: now,
            retryCount: 0,
            processingStartedAt: now,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AnalysisQueuePage(viewModel: viewModel)),
      ),
    );

    expect(find.text('日报 · 2026-07-13'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _PageViewModel extends ChangeNotifier
    implements QiDayFlowViewModel {
  _PageViewModel({
    this.dailyReport,
    this.reportLoading = false,
    this.analysisQueue = const AnalysisQueueViewData(),
  });

  @override
  AppSection section = AppSection.report;
  @override
  DateTime timelineDate = DateTime(2026, 7, 13);
  @override
  String? dailyReport;
  @override
  bool reportLoading;
  @override
  AnalysisQueueViewData analysisQueue;

  @override
  void selectSection(AppSection value) {
    section = value;
    notifyListeners();
  }

  @override
  Future<void> generateDailyReport() async {}

  @override
  Future<void> setTimelineDate(DateTime value) async {
    timelineDate = value;
    notifyListeners();
  }

  @override
  Future<void> refreshAnalysisQueue() async {}

  @override
  Future<void> retryFailedChunks() async {}

  @override
  Future<Uint8List?> loadApplicationIcon(String executablePath) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
