import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/domain/domain.dart';

enum AppSection { timeline, analysisQueue, report, statistics, settings }

enum RecordingViewStatus {
  stopped,
  starting,
  recording,
  paused,
  stopping,
  error,
}

enum SettingsSaveStatus { idle, saving, saved, error }

final class AnalysisQueueItemViewData {
  const AnalysisQueueItemViewData({
    required this.chunkId,
    this.batchId,
    required this.status,
    required this.recordedAt,
    required this.recordedUntil,
    required this.enqueuedAt,
    required this.updatedAt,
    required this.retryCount,
    this.processingStartedAt,
    this.errorSummary,
  });

  final int chunkId;
  final int? batchId;
  final ProcessingStatus status;
  final DateTime recordedAt;
  final DateTime recordedUntil;
  final DateTime enqueuedAt;
  final DateTime updatedAt;
  final int retryCount;
  final DateTime? processingStartedAt;
  final String? errorSummary;

  String get id => 'chunk-$chunkId';
  Duration get recordingDuration => recordedUntil.difference(recordedAt);
}

final class AnalysisQueueViewData {
  const AnalysisQueueViewData({
    this.items = const <AnalysisQueueItemViewData>[],
  });

  final List<AnalysisQueueItemViewData> items;

  int get processingCount =>
      items.where((item) => item.status == ProcessingStatus.processing).length;
  int get pendingCount =>
      items.where((item) => item.status == ProcessingStatus.pending).length;
  int get failedCount =>
      items.where((item) => item.status == ProcessingStatus.failed).length;
}

String safeAnalysisErrorSummary(String? value, {int maxLength = 120}) {
  if (maxLength <= 0) {
    throw RangeError.range(maxLength, 1, null, 'maxLength');
  }
  final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  final exception = RegExp(
    r'AnalysisException\.([a-zA-Z]+)(?:\s*\(HTTP\s+(\d{3})\))?',
    caseSensitive: false,
  ).firstMatch(normalized);
  final kind = exception?.group(1)?.toLowerCase();
  final statusCode = int.tryParse(exception?.group(2) ?? '');
  final summary = switch (kind) {
    'configuration' => '模型服务配置错误',
    'input' => '分析输入无效',
    'io' => '本地分析数据读取失败',
    'timeout' => '分析请求超时',
    'network' => '网络连接失败',
    'http' => _safeHttpErrorSummary(statusCode),
    'protocol' => '模型服务响应协议错误',
    'invalidjson' => '模型返回格式无效',
    'validation' => '模型返回内容未通过校验',
    _ => _safeUnstructuredErrorSummary(normalized),
  };
  if (summary.length <= maxLength) return summary;
  if (maxLength == 1) return '…';
  return '${summary.substring(0, maxLength - 1)}…';
}

String _safeHttpErrorSummary(int? statusCode) {
  if (statusCode == 401 || statusCode == 403) {
    return '模型服务身份验证失败 (HTTP $statusCode)';
  }
  if (statusCode == 429) {
    return '模型服务请求过于频繁 (HTTP 429)';
  }
  if (statusCode != null && statusCode >= 500) {
    return '模型服务暂时不可用 (HTTP $statusCode)';
  }
  return statusCode == null ? '模型服务请求失败' : '模型服务请求失败 (HTTP $statusCode)';
}

String _safeUnstructuredErrorSummary(String normalized) {
  if (normalized.isEmpty) return '分析失败，未提供错误详情';
  if (RegExp(r'\b(?:401|403)\b').hasMatch(normalized)) {
    return '模型服务身份验证失败';
  }
  if (RegExp(r'\b429\b').hasMatch(normalized)) {
    return '模型服务请求过于频繁';
  }
  if (RegExp(r'\b5\d\d\b').hasMatch(normalized)) {
    return '模型服务暂时不可用';
  }
  if (RegExp(r'time.?out|超时', caseSensitive: false).hasMatch(normalized)) {
    return '分析请求超时';
  }
  if (RegExp(
    r'network|socket|connection|网络连接',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return '网络连接失败';
  }
  if (RegExp(
    r'api.?key|密钥.*(?:缺失|未配置)',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return '模型服务配置错误';
  }
  if (RegExp(
    r'MP4|关键帧|切片元数据|本地证据',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return '本地分析数据读取失败';
  }
  if (RegExp(r'JSON|模型返回|格式无效', caseSensitive: false).hasMatch(normalized)) {
    return '模型返回内容无效';
  }
  return '分析失败，详细信息已隐藏';
}

class TimelineCardViewData {
  const TimelineCardViewData({
    required this.id,
    required this.category,
    required this.title,
    required this.summary,
    required this.startedAt,
    required this.endedAt,
    required this.productivityScore,
    required this.apps,
    this.appUsages = const <TimelineAppViewData>[],
  });

  final String id;
  final String category;
  final String title;
  final String summary;
  final DateTime startedAt;
  final DateTime endedAt;
  final double productivityScore;
  final List<String> apps;
  final List<TimelineAppViewData> appUsages;

  Duration get duration => endedAt.difference(startedAt);
}

class TimelineAppViewData {
  const TimelineAppViewData({
    required this.name,
    required this.duration,
    this.executablePath,
    this.averageCpuUsagePercent,
    this.peakCpuUsagePercent,
    this.averageMemoryCommitBytes,
    this.peakMemoryCommitBytes,
  });

  final String name;
  final Duration duration;
  final String? executablePath;
  final double? averageCpuUsagePercent;
  final double? peakCpuUsagePercent;
  final int? averageMemoryCommitBytes;
  final int? peakMemoryCommitBytes;
}

class TimelineCardEditDraft {
  const TimelineCardEditDraft({
    required this.id,
    required this.category,
    required this.title,
    required this.summary,
    required this.productivityScore,
  });

  final String id;
  final String category;
  final String title;
  final String summary;
  final double productivityScore;
}

class StatisticsMetricComparisonViewData {
  const StatisticsMetricComparisonViewData({
    this.current = 0,
    this.previous = 0,
  });

  final double current;
  final double previous;

  double get difference => current - previous;
  double? get percentChange {
    if (previous == 0) return current == 0 ? 0 : null;
    return difference / previous * 100;
  }
}

class HourEfficiencyViewData {
  const HourEfficiencyViewData({
    required this.hour,
    required this.durationMinutes,
    required this.weightedProductivity,
  });

  final int hour;
  final double durationMinutes;
  final double weightedProductivity;
}

class StatisticsAppViewData {
  const StatisticsAppViewData({
    required this.name,
    required this.durationMinutes,
    required this.share,
    this.executablePath,
  });

  final String name;
  final double durationMinutes;
  final double share;
  final String? executablePath;
}

class StatisticsPeriodViewData {
  const StatisticsPeriodViewData({
    this.totalMinutes = 0,
    this.weightedProductivity = 0,
    this.categoryMinutes = const <String, double>{},
  });

  final double totalMinutes;
  final double weightedProductivity;
  final Map<String, double> categoryMinutes;
}

class StatisticsViewData {
  const StatisticsViewData({
    this.totalMinutes = 0,
    this.weightedProductivity = 0,
    this.activityCount = 0,
    this.deepWorkCount = 0,
    this.highEfficiencyMinutes = 0,
    this.totalDurationComparison = const StatisticsMetricComparisonViewData(),
    this.productivityComparison = const StatisticsMetricComparisonViewData(),
    this.deepWorkComparison = const StatisticsMetricComparisonViewData(),
    this.activityComparison = const StatisticsMetricComparisonViewData(),
    this.categoryMinutes = const <String, double>{},
    this.categoryShares = const <String, double>{},
    this.dailyMinutes = const <DateTime, double>{},
    this.dailyCategoryMinutes = const <DateTime, Map<String, double>>{},
    this.dailyWeightedProductivity = const <DateTime, double>{},
    this.hourlyEfficiency = const <HourEfficiencyViewData>[],
    this.topApps = const <StatisticsAppViewData>[],
    this.thisWeek = const StatisticsPeriodViewData(),
    this.lastWeek = const StatisticsPeriodViewData(),
    this.weeklyCategoryDifference = const <String, double>{},
    this.recentDailyCategoryMinutes = const <DateTime, Map<String, double>>{},
    this.todayMinutes = 0,
    this.dailyGoalHours = 8,
    this.activeApplicationCount = 0,
  });

  final double totalMinutes;
  final double weightedProductivity;
  final int activityCount;
  final int deepWorkCount;
  final double highEfficiencyMinutes;
  double get deepWorkMinutes => highEfficiencyMinutes;
  final StatisticsMetricComparisonViewData totalDurationComparison;
  final StatisticsMetricComparisonViewData productivityComparison;
  final StatisticsMetricComparisonViewData deepWorkComparison;
  final StatisticsMetricComparisonViewData activityComparison;
  final Map<String, double> categoryMinutes;
  final Map<String, double> categoryShares;
  final Map<DateTime, double> dailyMinutes;
  final Map<DateTime, Map<String, double>> dailyCategoryMinutes;
  final Map<DateTime, double> dailyWeightedProductivity;
  final List<HourEfficiencyViewData> hourlyEfficiency;
  final List<StatisticsAppViewData> topApps;
  final StatisticsPeriodViewData thisWeek;
  final StatisticsPeriodViewData lastWeek;
  final Map<String, double> weeklyCategoryDifference;
  final Map<DateTime, Map<String, double>> recentDailyCategoryMinutes;
  final double todayMinutes;
  final int dailyGoalHours;
  final int activeApplicationCount;

  double get todayGoalProgress => dailyGoalHours <= 0
      ? 0
      : (todayMinutes / 60 / dailyGoalHours).clamp(0, 1).toDouble();
}

class SettingsDraft {
  const SettingsDraft({
    required this.apiUrl,
    required this.apiKey,
    required this.model,
    required this.userDataDirectory,
    required this.cacheLimitGb,
    required this.idlePauseEnabled,
    required this.idleTimeoutMinutes,
    this.captureIntervalSeconds = 1,
    required this.themeMode,
    this.logLevel = AppLogLevel.info,
    this.apiKeyChanged = true,
  });

  final String apiUrl;
  final String apiKey;
  final String model;
  final String userDataDirectory;
  final int cacheLimitGb;
  final bool idlePauseEnabled;
  final int idleTimeoutMinutes;
  final int captureIntervalSeconds;
  final ThemeMode themeMode;
  final AppLogLevel logLevel;
  final bool apiKeyChanged;
}

class SettingsViewData {
  const SettingsViewData({
    required this.apiUrl,
    required this.hasApiKey,
    required this.model,
    required this.userDataDirectory,
    required this.activeUserDataDirectory,
    required this.dataDirectoryRestartRequired,
    required this.cacheLimitGb,
    required this.idlePauseEnabled,
    required this.idleTimeoutMinutes,
    this.captureIntervalSeconds = 1,
    required this.themeMode,
    this.logLevel = AppLogLevel.info,
  });

  final String apiUrl;
  final bool hasApiKey;
  final String model;
  final String userDataDirectory;
  final String activeUserDataDirectory;
  final bool dataDirectoryRestartRequired;
  final int cacheLimitGb;
  final bool idlePauseEnabled;
  final int idleTimeoutMinutes;
  final int captureIntervalSeconds;
  final ThemeMode themeMode;
  final AppLogLevel logLevel;
}

abstract class QiDayFlowViewModel implements Listenable {
  AppSection get section;
  RecordingViewStatus get recordingStatus;
  Duration get recordingDuration;
  String? get statusMessage;
  DateTime get timelineDate;
  List<TimelineCardViewData> get timelineCards;
  bool get timelineLoading;
  String? get dailyReport;
  bool get reportLoading;
  int get statisticsDays;
  StatisticsViewData get statistics;
  SettingsViewData get settings;
  AnalysisQueueViewData get analysisQueue;
  int get failedChunkCount;
  int get pendingChunkCount;
  int get cacheBytes;
  int? get managedLogBytes;
  bool get clearingManagedLogs;
  String? get managedLogError;
  bool get savingSettings;
  SettingsSaveStatus get settingsSaveStatus;
  String? get settingsSaveError;

  void selectSection(AppSection section);
  Future<void> startCapture();
  Future<void> pauseOrResumeCapture();
  Future<void> stopCapture();
  Future<void> setTimelineDate(DateTime date);
  Future<void> updateTimelineCard(TimelineCardEditDraft draft);
  Future<Uint8List?> loadApplicationIcon(String executablePath);
  Future<void> revealExecutableInExplorer(String executablePath);
  Future<void> openUserDataDirectory(String directoryPath);
  Future<void> generateDailyReport();
  Future<void> setStatisticsDays(int days);
  Future<void> updateDailyGoalHours(int hours);
  Future<String> loadApiKeyForEditing();
  Future<void> saveSettings(SettingsDraft draft);
  Future<void> updateLogLevel(AppLogLevel level);
  Future<void> testApiConnection(SettingsDraft draft);
  Future<String?> chooseUserDataDirectory();
  Future<void> clearCompletedVideos();
  Future<void> clearManagedLogs();
  Future<void> refreshAnalysisQueue();
  Future<void> retryFailedChunks();
  Future<void> exitApplication();
}

extension RecordingViewStatusText on RecordingViewStatus {
  String get label => switch (this) {
    RecordingViewStatus.stopped => '未录制',
    RecordingViewStatus.starting => '正在启动',
    RecordingViewStatus.recording => '录制中',
    RecordingViewStatus.paused => '已暂停',
    RecordingViewStatus.stopping => '正在停止',
    RecordingViewStatus.error => '录制异常',
  };

  bool get isActive => switch (this) {
    RecordingViewStatus.starting ||
    RecordingViewStatus.recording ||
    RecordingViewStatus.paused ||
    RecordingViewStatus.stopping => true,
    _ => false,
  };
}
