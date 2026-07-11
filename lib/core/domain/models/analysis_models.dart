import '../validation.dart';
import 'statuses.dart';

final class AnalysisBatch {
  AnalysisBatch({
    this.id,
    required List<int> chunkIds,
    this.status = ProcessingStatus.pending,
    this.retryCount = 0,
    this.errorMessage,
    this.processingStartedAtMs,
    this.completedAtMs,
    required this.createdAtMs,
    required this.updatedAtMs,
  }) : chunkIds = List.unmodifiable(chunkIds) {
    if (chunkIds.isEmpty || chunkIds.any((id) => id <= 0)) {
      throw ArgumentError.value(chunkIds, 'chunkIds');
    }
    if (chunkIds.toSet().length != chunkIds.length) {
      throw ArgumentError.value(chunkIds, 'chunkIds', 'contains duplicates');
    }
    if (retryCount < 0 || createdAtMs < 0 || updatedAtMs < 0) {
      throw ArgumentError('Batch counters and timestamps must be non-negative');
    }
  }

  final int? id;
  final List<int> chunkIds;
  final ProcessingStatus status;
  final int retryCount;
  final String? errorMessage;
  final int? processingStartedAtMs;
  final int? completedAtMs;
  final int createdAtMs;
  final int updatedAtMs;
}

final class AnalysisQueueEntry {
  AnalysisQueueEntry({
    required this.chunkId,
    this.batchId,
    required this.status,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.enqueuedAtMs,
    required this.updatedAtMs,
    required this.retryCount,
    this.processingStartedAtMs,
    this.errorMessage,
  }) {
    if (chunkId <= 0) {
      throw ArgumentError.value(chunkId, 'chunkId');
    }
    if (batchId != null && batchId! <= 0) {
      throw ArgumentError.value(batchId, 'batchId');
    }
    if (status == ProcessingStatus.completed) {
      throw ArgumentError.value(status, 'status', 'must be active');
    }
    requireEpochRange(startedAtMs: startedAtMs, endedAtMs: endedAtMs);
    if (enqueuedAtMs < 0 || updatedAtMs < 0 || retryCount < 0) {
      throw ArgumentError(
        'Queue timestamps and retry count must be non-negative',
      );
    }
    if (processingStartedAtMs != null && processingStartedAtMs! < 0) {
      throw ArgumentError.value(processingStartedAtMs, 'processingStartedAtMs');
    }
  }

  final int chunkId;
  final int? batchId;
  final ProcessingStatus status;
  final int startedAtMs;
  final int endedAtMs;
  final int enqueuedAtMs;
  final int updatedAtMs;
  final int retryCount;
  final int? processingStartedAtMs;
  final String? errorMessage;
}

final class Observation {
  Observation({
    this.id,
    this.batchId,
    required this.chunkId,
    required this.startedAtMs,
    required this.endedAtMs,
    required String description,
    this.appName,
    this.processName,
    this.processPath,
    this.windowTitle,
    this.confidence,
    required this.createdAtMs,
  }) : description = requireNonBlank(description, 'description') {
    if (batchId != null && batchId! <= 0) {
      throw ArgumentError.value(batchId, 'batchId');
    }
    if (chunkId <= 0) {
      throw ArgumentError.value(chunkId, 'chunkId');
    }
    requireEpochRange(startedAtMs: startedAtMs, endedAtMs: endedAtMs);
    if (confidence != null) {
      requireScore(confidence!, 'confidence', max: 1);
    }
    if (createdAtMs < 0) {
      throw ArgumentError.value(createdAtMs, 'createdAtMs');
    }
  }

  factory Observation.fromJson(
    Object? value, {
    required int chunkId,
    required int chunkStartedAtMs,
    required int chunkEndedAtMs,
    int? batchId,
    int? createdAtMs,
  }) {
    const allowed = <String>{
      'startSeconds',
      'endSeconds',
      'text',
      'appName',
      'processName',
      'processPath',
      'windowTitle',
      'confidence',
    };
    final json = strictJsonObject(value, 'observation', allowedKeys: allowed);
    final startSeconds = jsonDouble(json, 'startSeconds');
    final endSeconds = jsonDouble(json, 'endSeconds');
    final durationSeconds = (chunkEndedAtMs - chunkStartedAtMs) / 1000;
    if (startSeconds < 0 ||
        endSeconds <= startSeconds ||
        endSeconds > durationSeconds + 0.5) {
      throw FormatException('observation 相对时间必须在切片 0..$durationSeconds 秒范围内');
    }
    final confidence = json['confidence'] == null
        ? null
        : jsonDouble(json, 'confidence');
    return Observation(
      batchId: batchId,
      chunkId: chunkId,
      startedAtMs: chunkStartedAtMs + (startSeconds * 1000).round(),
      endedAtMs: chunkStartedAtMs + (endSeconds * 1000).round(),
      description: jsonString(json, 'text'),
      appName: jsonOptionalString(json, 'appName'),
      processName: jsonOptionalString(json, 'processName'),
      processPath: jsonOptionalString(json, 'processPath'),
      windowTitle: jsonOptionalString(json, 'windowTitle'),
      confidence: confidence,
      createdAtMs: createdAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  final int? id;
  final int? batchId;
  final int chunkId;
  final int startedAtMs;
  final int endedAtMs;
  final String description;
  final String? appName;
  final String? processName;
  final String? processPath;
  final String? windowTitle;
  final double? confidence;
  final int createdAtMs;
}
