import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/openai/analysis_models.dart';
import 'package:qi_day_flow/services/openai/chat_transport.dart';
import 'package:qi_day_flow/services/openai/openai_analysis_service.dart';
import 'package:qi_day_flow/services/reports/daily_report_service.dart';

void main() {
  test(
    'shutdown cancels a generation whose service factory returns late',
    () async {
      final factoryEntered = Completer<void>();
      final releaseFactory = Completer<void>();
      final transport = _TrackingTransport();
      final service = OpenAiAnalysisService(
        config: const OpenAiAnalysisConfig(
          baseUrl: 'https://api.example.com/v1/',
          apiKey: 'test-key',
          model: 'test-model',
        ),
        transport: transport,
      );
      final reports = DailyReportService(
        timelineRepository: _TimelineRepository(),
        reportRepository: _ReportRepository(),
        serviceFactory: () async {
          factoryEntered.complete();
          await releaseFactory.future;
          return service;
        },
        modelName: () async => 'test-model',
      );

      final generation = reports.generate('2026-07-13');
      await factoryEntered.future;
      reports.cancelActiveGeneration();
      releaseFactory.complete();

      await expectLater(generation, throwsStateError);
      expect(transport.postCalls, 0);
      expect(transport.closed, isTrue);
    },
  );

  test('only a report generated after the job request is idempotent', () async {
    DailyReport report(int generatedAtMs) => DailyReport(
      reportDate: '2026-07-13',
      content: '日报',
      sourceRevision: 1,
      currentRevision: 1,
      generatedAtMs: generatedAtMs,
      model: 'test-model|daily-v1',
    );
    final repository = _ReportRepository(report(1000));
    final reports = DailyReportService(
      timelineRepository: _TimelineRepository(),
      reportRepository: repository,
      serviceFactory: () async => throw UnimplementedError(),
      modelName: () async => 'test-model',
    );

    expect(
      await reports.hasFreshReportGeneratedSince('2026-07-13', 1000),
      isFalse,
    );
    repository.report = report(1001);
    expect(
      await reports.hasFreshReportGeneratedSince('2026-07-13', 1000),
      isTrue,
    );
  });
}

final class _TimelineRepository implements TimelineRepository {
  @override
  Future<int> getTimelineRevision(String reportDate) async => 1;

  @override
  Future<List<TimelineCard>> listCardsForReportDate(String reportDate) async =>
      <TimelineCard>[
        TimelineCard(
          batchId: 1,
          reportDate: reportDate,
          category: '工作',
          title: '测试活动',
          summary: '测试',
          startedAtMs: 1000,
          endedAtMs: 2000,
          productivityScore: 80,
          appUsages: const <AppUsage>[],
          distractions: const <Distraction>[],
          createdAtMs: 1000,
          updatedAtMs: 1000,
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReportRepository implements DailyReportRepository {
  _ReportRepository([this.report]);

  DailyReport? report;

  @override
  Future<DailyReport?> getDailyReport(String reportDate) async => report;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TrackingTransport implements ChatTransport {
  int postCalls = 0;
  bool closed = false;

  @override
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    postCalls++;
    throw StateError('request should not start');
  }

  @override
  void close() => closed = true;
}
