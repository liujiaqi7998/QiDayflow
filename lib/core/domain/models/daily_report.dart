import '../validation.dart';

final class DailyReport {
  DailyReport({
    required String reportDate,
    required String content,
    required this.sourceRevision,
    required this.currentRevision,
    required this.generatedAtMs,
    required String model,
    this.invalidatedAtMs,
  }) : reportDate = requireReportDate(reportDate),
       content = requireNonBlank(content, 'content'),
       model = requireNonBlank(model, 'model') {
    if (sourceRevision < 0 || currentRevision < 0 || generatedAtMs < 0) {
      throw ArgumentError(
        'Report revisions and timestamps must be non-negative',
      );
    }
  }

  final String reportDate;
  final String content;
  final int sourceRevision;
  final int currentRevision;
  final int generatedAtMs;
  final String model;
  final int? invalidatedAtMs;

  bool get isStale =>
      invalidatedAtMs != null || sourceRevision != currentRevision;

  factory DailyReport.fromJson(Object? value) {
    const allowed = <String>{
      'reportDate',
      'content',
      'sourceRevision',
      'currentRevision',
      'generatedAt',
      'model',
      'invalidatedAt',
    };
    final json = strictJsonObject(value, 'dailyReport', allowedKeys: allowed);
    return DailyReport(
      reportDate: jsonString(json, 'reportDate'),
      content: jsonString(json, 'content'),
      sourceRevision: jsonInt(json, 'sourceRevision'),
      currentRevision: jsonInt(json, 'currentRevision'),
      generatedAtMs: jsonIsoTime(json, 'generatedAt').millisecondsSinceEpoch,
      model: jsonString(json, 'model'),
      invalidatedAtMs: json['invalidatedAt'] == null
          ? null
          : jsonIsoTime(json, 'invalidatedAt').millisecondsSinceEpoch,
    );
  }
}
