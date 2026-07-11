import '../validation.dart';
import 'statuses.dart';

final class CaptureSession {
  CaptureSession({
    this.id,
    required String captureScope,
    required String captureDirectory,
    required this.startedAtMs,
    this.endedAtMs,
    this.status = CaptureSessionStatus.recording,
    this.errorMessage,
    required this.createdAtMs,
    required this.updatedAtMs,
  }) : captureScope = requireNonBlank(captureScope, 'captureScope'),
       captureDirectory = requireNonBlank(
         captureDirectory,
         'captureDirectory',
       ) {
    if (startedAtMs < 0 || createdAtMs < 0 || updatedAtMs < 0) {
      throw ArgumentError('Session timestamps must be non-negative');
    }
    if (endedAtMs != null && endedAtMs! <= startedAtMs) {
      throw ArgumentError.value(endedAtMs, 'endedAtMs');
    }
  }

  factory CaptureSession.fromJson(Object? value) {
    const allowed = <String>{
      'id',
      'captureScope',
      'displayId',
      'captureDirectory',
      'startedAt',
      'endedAt',
      'status',
      'errorMessage',
      'createdAt',
      'updatedAt',
    };
    final json = strictJsonObject(
      value,
      'captureSession',
      allowedKeys: allowed,
    );
    return CaptureSession(
      id: json['id'] == null ? null : jsonInt(json, 'id'),
      captureScope: json['captureScope'] == null
          ? jsonString(json, 'displayId')
          : jsonString(json, 'captureScope'),
      captureDirectory: jsonString(json, 'captureDirectory'),
      startedAtMs: jsonIsoTime(json, 'startedAt').millisecondsSinceEpoch,
      endedAtMs: json['endedAt'] == null
          ? null
          : jsonIsoTime(json, 'endedAt').millisecondsSinceEpoch,
      status: CaptureSessionStatus.fromStorage(jsonString(json, 'status')),
      errorMessage: jsonOptionalString(json, 'errorMessage'),
      createdAtMs: jsonIsoTime(json, 'createdAt').millisecondsSinceEpoch,
      updatedAtMs: jsonIsoTime(json, 'updatedAt').millisecondsSinceEpoch,
    );
  }

  final int? id;
  final String captureScope;
  final String captureDirectory;
  final int startedAtMs;
  final int? endedAtMs;
  final CaptureSessionStatus status;
  final String? errorMessage;
  final int createdAtMs;
  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'captureScope': captureScope,
    'captureDirectory': captureDirectory,
    'startedAt': DateTime.fromMillisecondsSinceEpoch(
      startedAtMs,
      isUtc: true,
    ).toIso8601String(),
    'endedAt': endedAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            endedAtMs!,
            isUtc: true,
          ).toIso8601String(),
    'status': status.name,
    'errorMessage': errorMessage,
    'createdAt': DateTime.fromMillisecondsSinceEpoch(
      createdAtMs,
      isUtc: true,
    ).toIso8601String(),
    'updatedAt': DateTime.fromMillisecondsSinceEpoch(
      updatedAtMs,
      isUtc: true,
    ).toIso8601String(),
  };
}

final class CaptureChunk {
  CaptureChunk({
    this.id,
    required this.sessionId,
    required String framesDirectory,
    required String metadataPath,
    this.videoPath,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.frameCount,
    this.status = ProcessingStatus.pending,
    this.retryCount = 0,
    this.nextRetryAtMs,
    this.errorMessage,
    this.processingStartedAtMs,
    this.completedAtMs,
    this.evidencePurgedAtMs,
    required this.createdAtMs,
    required this.updatedAtMs,
  }) : framesDirectory = requireNonBlank(framesDirectory, 'framesDirectory'),
       metadataPath = requireNonBlank(metadataPath, 'metadataPath') {
    if (sessionId <= 0) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    requireEpochRange(startedAtMs: startedAtMs, endedAtMs: endedAtMs);
    if (frameCount <= 0) {
      throw ArgumentError.value(frameCount, 'frameCount', 'must be positive');
    }
    if (videoPath != null) {
      requireNonBlank(videoPath!, 'videoPath');
    }
    if (retryCount < 0) {
      throw ArgumentError.value(retryCount, 'retryCount');
    }
    if (createdAtMs < 0 || updatedAtMs < 0) {
      throw ArgumentError('Chunk timestamps must be non-negative');
    }
    if (evidencePurgedAtMs != null &&
        (evidencePurgedAtMs! < 0 || status != ProcessingStatus.completed)) {
      throw ArgumentError(
        'Purged evidence must belong to a completed chunk and use a '
        'non-negative timestamp',
      );
    }
  }

  factory CaptureChunk.fromJson(Object? value) {
    const allowed = <String>{
      'id',
      'sessionId',
      'framesDirectory',
      'metadataPath',
      'videoPath',
      'startedAt',
      'endedAt',
      'frameCount',
      'status',
      'retryCount',
      'nextRetryAt',
      'errorMessage',
      'processingStartedAt',
      'completedAt',
      'evidencePurgedAt',
      'createdAt',
      'updatedAt',
    };
    final json = strictJsonObject(value, 'chunk', allowedKeys: allowed);
    int? optionalTime(String key) => json[key] == null
        ? null
        : jsonIsoTime(json, key).millisecondsSinceEpoch;
    return CaptureChunk(
      id: json['id'] == null ? null : jsonInt(json, 'id'),
      sessionId: jsonInt(json, 'sessionId'),
      framesDirectory: jsonString(json, 'framesDirectory'),
      metadataPath: jsonString(json, 'metadataPath'),
      videoPath: jsonOptionalString(json, 'videoPath'),
      startedAtMs: jsonIsoTime(json, 'startedAt').millisecondsSinceEpoch,
      endedAtMs: jsonIsoTime(json, 'endedAt').millisecondsSinceEpoch,
      frameCount: jsonInt(json, 'frameCount'),
      status: ProcessingStatus.fromStorage(jsonString(json, 'status')),
      retryCount: jsonInt(json, 'retryCount'),
      nextRetryAtMs: optionalTime('nextRetryAt'),
      errorMessage: jsonOptionalString(json, 'errorMessage'),
      processingStartedAtMs: optionalTime('processingStartedAt'),
      completedAtMs: optionalTime('completedAt'),
      evidencePurgedAtMs: optionalTime('evidencePurgedAt'),
      createdAtMs: jsonIsoTime(json, 'createdAt').millisecondsSinceEpoch,
      updatedAtMs: jsonIsoTime(json, 'updatedAt').millisecondsSinceEpoch,
    );
  }

  final int? id;
  final int sessionId;
  final String framesDirectory;
  final String metadataPath;
  final String? videoPath;
  final int startedAtMs;
  final int endedAtMs;
  final int frameCount;
  final ProcessingStatus status;
  final int retryCount;
  final int? nextRetryAtMs;
  final String? errorMessage;
  final int? processingStartedAtMs;
  final int? completedAtMs;
  final int? evidencePurgedAtMs;
  final int createdAtMs;
  final int updatedAtMs;

  bool get isVideoChunk => videoPath != null;
}
