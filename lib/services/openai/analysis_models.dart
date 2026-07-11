import 'dart:io';

final class OpenAiAnalysisConfig {
  const OpenAiAnalysisConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 120),
    this.maxTokens = 4096,
    this.maxJpegBytes = 2 * 1024 * 1024,
    this.maxImagePayloadBytes = 12 * 1024 * 1024,
    this.maxImageFrames = 8,
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.maxAttempts = 1,
    this.retryBaseDelay = const Duration(milliseconds: 500),
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final int maxTokens;
  final int maxJpegBytes;
  final int maxImagePayloadBytes;
  final int maxImageFrames;
  final int maxResponseBytes;
  final int maxAttempts;
  final Duration retryBaseDelay;
}

final class AnalysisKeyFrame {
  const AnalysisKeyFrame.file({required this.offsetSeconds, required this.path})
    : _bytes = null;

  AnalysisKeyFrame.memory({
    required this.offsetSeconds,
    required List<int> jpegBytes,
  }) : path = null,
       _bytes = List<int>.unmodifiable(jpegBytes);

  final double offsetSeconds;
  final String? path;
  final List<int>? _bytes;

  Future<List<int>> readBytes() async {
    final bytes = _bytes;
    if (bytes != null) {
      return bytes;
    }
    return File(path!).readAsBytes();
  }
}

final class WindowContextSegment {
  const WindowContextSegment({
    required this.startSeconds,
    required this.endSeconds,
    required this.processName,
    required this.friendlyAppName,
    required this.windowTitle,
    this.executablePath,
    this.cpuUsagePercent,
    this.memoryCommitBytes,
  });

  final double startSeconds;
  final double endSeconds;
  final String processName;
  final String friendlyAppName;
  final String windowTitle;
  final String? executablePath;
  final double? cpuUsagePercent;
  final int? memoryCommitBytes;

  Map<String, Object> toPromptJson() => <String, Object>{
    'start_seconds': startSeconds,
    'end_seconds': endSeconds,
    'process_name': processName,
    'app_name': friendlyAppName,
    'window_title': windowTitle,
  };
}

final class AnalysisChunkInput {
  AnalysisChunkInput({
    required this.chunkId,
    required this.startedAt,
    required this.durationSeconds,
    required List<AnalysisKeyFrame> keyFrames,
    required List<WindowContextSegment> windowContexts,
  }) : keyFrames = List<AnalysisKeyFrame>.unmodifiable(keyFrames),
       windowContexts = List<WindowContextSegment>.unmodifiable(windowContexts);

  final String chunkId;
  final DateTime startedAt;
  final double durationSeconds;
  final List<AnalysisKeyFrame> keyFrames;
  final List<WindowContextSegment> windowContexts;
}

final class AnalysisObservation {
  const AnalysisObservation({
    required this.chunkId,
    required this.startSeconds,
    required this.endSeconds,
    required this.startTime,
    required this.endTime,
    required this.text,
    this.processName,
    this.appName,
    this.windowTitle,
    this.executablePath,
  });

  final String chunkId;
  final double startSeconds;
  final double endSeconds;
  final DateTime startTime;
  final DateTime endTime;
  final String text;
  final String? processName;
  final String? appName;
  final String? windowTitle;
  final String? executablePath;
}

final class AnalysisAppSite {
  const AnalysisAppSite({required this.name, required this.durationSeconds});

  final String name;
  final double durationSeconds;
}

final class AnalysisDistraction {
  const AnalysisDistraction({
    required this.description,
    required this.offsetSeconds,
    required this.timestamp,
    required this.durationSeconds,
  });

  final String description;
  final double offsetSeconds;
  final DateTime timestamp;
  final double durationSeconds;
}

final class AnalysisCard {
  AnalysisCard({
    required this.category,
    required this.title,
    required this.summary,
    required this.startTime,
    required this.endTime,
    required List<AnalysisAppSite> appSites,
    required List<AnalysisDistraction> distractions,
    required this.productivityScore,
  }) : appSites = List<AnalysisAppSite>.unmodifiable(appSites),
       distractions = List<AnalysisDistraction>.unmodifiable(distractions);

  final String category;
  final String title;
  final String summary;
  final DateTime startTime;
  final DateTime endTime;
  final List<AnalysisAppSite> appSites;
  final List<AnalysisDistraction> distractions;
  final double productivityScore;

  Duration get duration => endTime.difference(startTime);
}
