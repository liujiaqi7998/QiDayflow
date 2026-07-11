import '../validation.dart';

const List<String> timelineCategories = <String>[
  '工作',
  '学习',
  '编程',
  '会议',
  '娱乐',
  '社交',
  '休息',
  '其他',
];

final class AppUsage {
  AppUsage({
    required String name,
    required this.durationMs,
    String? executablePath,
    this.averageCpuUsagePercent,
    this.peakCpuUsagePercent,
    this.averageMemoryCommitBytes,
    this.peakMemoryCommitBytes,
  }) : name = requireNonBlank(name, 'name'),
       executablePath = _optionalTrimmed(executablePath) {
    if (durationMs < 0) {
      throw ArgumentError.value(durationMs, 'durationMs');
    }
    _validateCpuUsage(averageCpuUsagePercent, 'averageCpuUsagePercent');
    _validateCpuUsage(peakCpuUsagePercent, 'peakCpuUsagePercent');
    _validateMemoryCommit(averageMemoryCommitBytes, 'averageMemoryCommitBytes');
    _validateMemoryCommit(peakMemoryCommitBytes, 'peakMemoryCommitBytes');
    if (averageCpuUsagePercent != null &&
        peakCpuUsagePercent != null &&
        averageCpuUsagePercent! > peakCpuUsagePercent!) {
      throw ArgumentError('Average CPU usage cannot exceed peak CPU usage');
    }
    if (averageMemoryCommitBytes != null &&
        peakMemoryCommitBytes != null &&
        averageMemoryCommitBytes! > peakMemoryCommitBytes!) {
      throw ArgumentError(
        'Average memory commit cannot exceed peak memory commit',
      );
    }
  }

  final String name;
  final int durationMs;
  final String? executablePath;
  final double? averageCpuUsagePercent;
  final double? peakCpuUsagePercent;
  final int? averageMemoryCommitBytes;
  final int? peakMemoryCommitBytes;

  Map<String, Object> toJson() => <String, Object>{
    'name': name,
    'duration_ms': durationMs,
    'executable_path': ?executablePath,
    'average_cpu_usage_percent': ?averageCpuUsagePercent,
    'peak_cpu_usage_percent': ?peakCpuUsagePercent,
    'average_memory_commit_bytes': ?averageMemoryCommitBytes,
    'peak_memory_commit_bytes': ?peakMemoryCommitBytes,
  };

  factory AppUsage.fromJson(Object? value) {
    final json = strictJsonObject(
      value,
      'appUsage',
      allowedKeys: const <String>{
        'name',
        'duration_ms',
        'executable_path',
        'average_cpu_usage_percent',
        'peak_cpu_usage_percent',
        'average_memory_commit_bytes',
        'peak_memory_commit_bytes',
      },
    );
    return AppUsage(
      name: jsonString(json, 'name'),
      durationMs: jsonInt(json, 'duration_ms'),
      executablePath: jsonOptionalString(json, 'executable_path'),
      averageCpuUsagePercent: json['average_cpu_usage_percent'] == null
          ? null
          : jsonDouble(json, 'average_cpu_usage_percent'),
      peakCpuUsagePercent: json['peak_cpu_usage_percent'] == null
          ? null
          : jsonDouble(json, 'peak_cpu_usage_percent'),
      averageMemoryCommitBytes: json['average_memory_commit_bytes'] == null
          ? null
          : jsonInt(json, 'average_memory_commit_bytes'),
      peakMemoryCommitBytes: json['peak_memory_commit_bytes'] == null
          ? null
          : jsonInt(json, 'peak_memory_commit_bytes'),
    );
  }
}

void _validateCpuUsage(double? value, String fieldName) {
  if (value == null) return;
  if (!value.isFinite || value < 0 || value > 100) {
    throw ArgumentError.value(value, fieldName, 'must be between 0 and 100');
  }
}

void _validateMemoryCommit(int? value, String fieldName) {
  if (value != null && value < 0) {
    throw ArgumentError.value(value, fieldName, 'must be non-negative');
  }
}

String? _optionalTrimmed(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

final class Distraction {
  Distraction({
    required String description,
    required this.atMs,
    required this.durationMs,
  }) : description = requireNonBlank(description, 'description') {
    if (atMs < 0 || durationMs < 0) {
      throw ArgumentError('Distraction timestamps must be non-negative');
    }
  }

  final String description;
  final int atMs;
  final int durationMs;

  Map<String, Object> toJson() => {
    'description': description,
    'at_ms': atMs,
    'duration_ms': durationMs,
  };

  factory Distraction.fromJson(Object? value) {
    final json = strictJsonObject(
      value,
      'distraction',
      allowedKeys: const <String>{'description', 'at_ms', 'duration_ms'},
    );
    return Distraction(
      description: jsonString(json, 'description'),
      atMs: jsonInt(json, 'at_ms'),
      durationMs: jsonInt(json, 'duration_ms'),
    );
  }
}

final class TimelineCard {
  TimelineCard({
    this.id,
    this.batchId,
    required String reportDate,
    required String category,
    required String title,
    required String summary,
    required this.startedAtMs,
    required this.endedAtMs,
    required List<AppUsage> appUsages,
    required List<Distraction> distractions,
    required this.productivityScore,
    required this.createdAtMs,
    required this.updatedAtMs,
  }) : reportDate = requireReportDate(reportDate),
       category = requireNonBlank(category, 'category'),
       title = requireNonBlank(title, 'title'),
       summary = summary.trim(),
       appUsages = List.unmodifiable(appUsages),
       distractions = List.unmodifiable(distractions) {
    if (batchId != null && batchId! <= 0) {
      throw ArgumentError.value(batchId, 'batchId');
    }
    requireEpochRange(startedAtMs: startedAtMs, endedAtMs: endedAtMs);
    requireScore(productivityScore, 'productivityScore');
    if (createdAtMs < 0 || updatedAtMs < 0) {
      throw ArgumentError('Card timestamps must be non-negative');
    }
  }

  factory TimelineCard.fromJson(Object? value) {
    const allowed = <String>{
      'id',
      'batchId',
      'reportDate',
      'category',
      'title',
      'summary',
      'startedAt',
      'endedAt',
      'appUsages',
      'distractions',
      'productivityScore',
      'createdAt',
      'updatedAt',
    };
    final json = strictJsonObject(value, 'timelineCard', allowedKeys: allowed);
    return TimelineCard(
      id: json['id'] == null ? null : jsonInt(json, 'id'),
      batchId: json['batchId'] == null ? null : jsonInt(json, 'batchId'),
      reportDate: jsonString(json, 'reportDate'),
      category: jsonString(json, 'category'),
      title: jsonString(json, 'title'),
      summary: jsonString(json, 'summary', allowEmpty: true),
      startedAtMs: jsonIsoTime(json, 'startedAt').millisecondsSinceEpoch,
      endedAtMs: jsonIsoTime(json, 'endedAt').millisecondsSinceEpoch,
      appUsages: jsonList(
        json,
        'appUsages',
      ).map(AppUsage.fromJson).toList(growable: false),
      distractions: jsonList(
        json,
        'distractions',
      ).map(Distraction.fromJson).toList(growable: false),
      productivityScore: jsonDouble(json, 'productivityScore'),
      createdAtMs: jsonIsoTime(json, 'createdAt').millisecondsSinceEpoch,
      updatedAtMs: jsonIsoTime(json, 'updatedAt').millisecondsSinceEpoch,
    );
  }

  final int? id;
  final int? batchId;
  final String reportDate;
  final String category;
  final String title;
  final String summary;
  final int startedAtMs;
  final int endedAtMs;
  final List<AppUsage> appUsages;
  final List<Distraction> distractions;
  final double productivityScore;
  final int createdAtMs;
  final int updatedAtMs;

  int get durationMs => endedAtMs - startedAtMs;
}
