// ignore_for_file: prefer_initializing_formals

import '../../core/domain/domain.dart';
import '../openai/analysis_models.dart' as ai;
import '../openai/openai_analysis_service.dart';
import '../processing/analysis_coordinator.dart';

class DailyReportService {
  DailyReportService({
    required TimelineRepository timelineRepository,
    required DailyReportRepository reportRepository,
    required AnalysisServiceFactory serviceFactory,
    required Future<String> Function() modelName,
  }) : _timelineRepository = timelineRepository,
       _reportRepository = reportRepository,
       _serviceFactory = serviceFactory,
       _modelName = modelName;

  static const promptVersion = 'daily-v1';

  final TimelineRepository _timelineRepository;
  final DailyReportRepository _reportRepository;
  final AnalysisServiceFactory _serviceFactory;
  final Future<String> Function() _modelName;
  OpenAiAnalysisService? _activeService;
  int _cancellationGeneration = 0;

  void cancelActiveGeneration() {
    _cancellationGeneration++;
    final active = _activeService;
    _activeService = null;
    active?.close();
  }

  Future<String?> loadFresh(String reportDate) async {
    final report = await _reportRepository.getDailyReport(reportDate);
    if (report == null || report.isStale) return null;
    final expectedModel = '${await _modelName()}|$promptVersion';
    return report.model == expectedModel ? report.content : null;
  }

  Future<bool> hasFreshReportGeneratedSince(
    String reportDate,
    int requestedAtMs,
  ) async {
    final report = await _reportRepository.getDailyReport(reportDate);
    if (report == null ||
        report.isStale ||
        report.generatedAtMs <= requestedAtMs) {
      return false;
    }
    final expectedModel = '${await _modelName()}|$promptVersion';
    return report.model == expectedModel;
  }

  Future<String> generate(String reportDate) async {
    final cancellationGeneration = _cancellationGeneration;
    final expectedRevision = await _timelineRepository.getTimelineRevision(
      reportDate,
    );
    final cards = await _timelineRepository.listCardsForReportDate(reportDate);
    if (cards.isEmpty) {
      throw StateError('当天没有可生成日报的活动卡片');
    }
    final service = await _serviceFactory();
    if (cancellationGeneration != _cancellationGeneration) {
      service.close();
      throw StateError('日报生成已取消');
    }
    _activeService = service;
    try {
      final model = await _modelName();
      final report = await service.generateDailyReport(
        cards: cards.map(_toAiCard).toList(growable: false),
        reportDate: DateTime.parse(reportDate),
      );
      await _reportRepository.saveDailyReport(
        reportDate: reportDate,
        content: report,
        model: '$model|$promptVersion',
        expectedRevision: expectedRevision,
      );
      return report;
    } finally {
      if (identical(_activeService, service)) _activeService = null;
      service.close();
    }
  }

  static ai.AnalysisCard _toAiCard(TimelineCard card) {
    return ai.AnalysisCard(
      category: card.category,
      title: card.title,
      summary: card.summary,
      startTime: DateTime.fromMillisecondsSinceEpoch(
        card.startedAtMs,
        isUtc: true,
      ),
      endTime: DateTime.fromMillisecondsSinceEpoch(card.endedAtMs, isUtc: true),
      appSites: card.appUsages
          .map(
            (usage) => ai.AnalysisAppSite(
              name: usage.name,
              durationSeconds: usage.durationMs / 1000,
            ),
          )
          .toList(growable: false),
      distractions: card.distractions
          .map(
            (item) => ai.AnalysisDistraction(
              description: item.description,
              offsetSeconds: (item.atMs - card.startedAtMs) / 1000,
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                item.atMs,
                isUtc: true,
              ),
              durationSeconds: item.durationMs / 1000,
            ),
          )
          .toList(growable: false),
      productivityScore: card.productivityScore,
    );
  }
}
