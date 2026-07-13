import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/domain/domain.dart';
import 'capture_video_spec.dart';

const String _methodChannelName = 'qi_day_flow/platform';
const String _eventChannelName = 'qi_day_flow/capture_events';

enum NativeCaptureStatus {
  stopped,
  starting,
  capturing,
  paused,
  stopping,
  error,
}

enum NativeTrayCaptureState {
  stopped,
  starting,
  recording,
  paused,
  stopping,
  error,
}

enum NativeTrayCommand { startCapture, stopCapture }

final class NativeCaptureConfiguration {
  const NativeCaptureConfiguration({
    required this.outputDirectory,
    required this.sessionId,
    this.captureIntervalSeconds = defaultCaptureIntervalSeconds,
    this.chunkDurationSeconds = captureChunkDurationSeconds,
    this.maxWidth = captureVideoWidth,
    this.maxHeight = captureVideoHeight,
    this.idlePauseEnabled = true,
    this.idleTimeoutSeconds = 600,
  }) : assert(
         captureIntervalSeconds == 1 ||
             captureIntervalSeconds == 10 ||
             captureIntervalSeconds == 20 ||
             captureIntervalSeconds == 30,
         'captureIntervalSeconds must be one of 1, 10, 20, or 30',
       );

  final String outputDirectory;
  final String sessionId;
  final int captureIntervalSeconds;
  final int chunkDurationSeconds;
  final int maxWidth;
  final int maxHeight;
  final bool idlePauseEnabled;
  final int idleTimeoutSeconds;

  Map<String, Object> toMap() => <String, Object>{
    'outputDirectory': outputDirectory,
    'sessionId': sessionId,
    'captureIntervalSeconds': captureIntervalSeconds,
    'chunkDurationSeconds': chunkDurationSeconds,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'idlePauseEnabled': idlePauseEnabled,
    'idleTimeoutSeconds': idleTimeoutSeconds,
  };
}

sealed class NativeCaptureEvent {
  const NativeCaptureEvent();

  factory NativeCaptureEvent.fromMap(Map<Object?, Object?> map) {
    final type = _requiredString(map, const <String>['type']);
    return switch (type) {
      'state' => NativeCaptureStateEvent(
        status: _parseStatus(
          _requiredString(map, const <String>['state', 'status']),
        ),
        sessionId: _requiredString(map, const <String>[
          'sessionId',
          'session_id',
        ]),
        reason: _optionalString(map['reason']),
        idleSeconds: _optionalInt(map['idleSeconds']),
      ),
      'chunkCompleted' ||
      'chunkFinalized' => NativeChunkCompletedEvent.fromMap(map),
      'error' => NativeCaptureErrorEvent(
        code: _requiredString(map, const <String>['code']),
        message: _requiredString(map, const <String>['message']),
        recoverable: map['recoverable'] == true || map['fatal'] == false,
        sessionId: _requiredString(map, const <String>[
          'sessionId',
          'session_id',
        ]),
      ),
      'idle' => NativeIdleEvent(
        idleSeconds:
            _optionalInt(map['idleSeconds']) ??
            ((_optionalInt(map['idleMilliseconds']) ?? 0) ~/ 1000),
        paused: map['paused'] == true,
      ),
      'trayCommand' => NativeTrayCommandEvent(
        command: switch (_requiredString(map, const <String>['command'])) {
          'startCapture' => NativeTrayCommand.startCapture,
          'stopCapture' => NativeTrayCommand.stopCapture,
          final command => throw FormatException('未知托盘录制命令: $command'),
        },
      ),
      'quitRequested' || 'exitRequested' => const NativeQuitRequestedEvent(),
      _ => throw FormatException('未知原生事件类型: $type'),
    };
  }
}

final class NativeCaptureStateEvent extends NativeCaptureEvent {
  const NativeCaptureStateEvent({
    required this.status,
    required this.sessionId,
    this.reason,
    this.idleSeconds,
  });

  final NativeCaptureStatus status;
  final String sessionId;
  final String? reason;
  final int? idleSeconds;
}

final class NativeIdleEvent extends NativeCaptureEvent {
  const NativeIdleEvent({required this.idleSeconds, required this.paused});

  final int idleSeconds;
  final bool paused;
}

final class NativeWindowRecord {
  const NativeWindowRecord({
    required this.timestampMs,
    required this.offsetMs,
    required this.processId,
    required this.appName,
    required this.processName,
    required this.windowTitle,
    this.processPath = '',
    this.cpuUsagePercent,
    this.memoryCommitBytes,
  });

  factory NativeWindowRecord.fromMap(Map<Object?, Object?> map) {
    final cpuUsagePercent = _optionalPercentage(
      _value(map, const <String>['cpuUsagePercent', 'cpu_usage_percent']),
      field: 'cpuUsagePercent',
    );
    final memoryCommitBytes = _optionalNonNegativeInt(
      _value(map, const <String>['memoryCommitBytes', 'memory_commit_bytes']),
      field: 'memoryCommitBytes',
    );
    return NativeWindowRecord(
      timestampMs: _nonNegativeInt(
        _value(map, const <String>['timestampMs', 'timestamp_ms']),
        field: 'timestampMs',
      ),
      offsetMs: _nonNegativeInt(
        _value(map, const <String>['offsetMs', 'offset_ms']),
        field: 'offsetMs',
      ),
      processId: _nonNegativeInt(
        _value(map, const <String>['processId', 'process_id']),
        field: 'processId',
      ),
      appName: _requiredString(map, const <String>[
        'appName',
        'friendlyName',
        'app_name',
      ]),
      processName: _requiredString(map, const <String>[
        'processName',
        'process_name',
      ]),
      processPath:
          _value(map, const <String>[
            'processPath',
            'process_path',
          ])?.toString() ??
          '',
      windowTitle:
          _value(map, const <String>[
            'windowTitle',
            'window_title',
          ])?.toString() ??
          '',
      cpuUsagePercent: cpuUsagePercent,
      memoryCommitBytes: memoryCommitBytes,
    );
  }

  final int timestampMs;
  final int offsetMs;
  final int processId;
  final String appName;
  final String processName;
  final String processPath;
  final String windowTitle;
  final double? cpuUsagePercent;
  final int? memoryCommitBytes;
}

final class NativeChunkCompletedEvent extends NativeCaptureEvent {
  const NativeChunkCompletedEvent({
    required this.schemaVersion,
    required this.sessionId,
    required this.chunkId,
    required this.captureScope,
    required this.directoryPath,
    required this.videoPath,
    required this.metadataPath,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.frameCount,
    required this.videoWidth,
    required this.videoHeight,
    required this.captureIntervalSeconds,
    required this.videoFrameRateNumerator,
    required this.videoFrameRateDenominator,
    required this.videoFrameDurationTicks,
    required this.windowRecords,
  });

  factory NativeChunkCompletedEvent.fromMap(Map<Object?, Object?> map) {
    final schemaVersion = _requiredInt(map, const <String>['schemaVersion']);
    if (schemaVersion != 3 && schemaVersion != 4) {
      throw const FormatException('原生切片元数据版本必须是 schema 3 或 4');
    }
    final captureScope = _requiredString(map, const <String>['captureScope']);
    if (captureScope != activeWindowDisplayCaptureScope) {
      throw const FormatException('原生切片采集范围必须是 active-window-display');
    }
    final records =
        _optionalList(
              _value(map, const <String>['windowRecords', 'window_records']),
            )
            .map((value) => NativeWindowRecord.fromMap(_asMap(value)))
            .toList(growable: false);
    final counts = map['counts'] is Map ? _asMap(map['counts']) : map;
    final directoryPath = _requiredString(map, const <String>[
      'directoryPath',
      'chunkPath',
    ]);
    final videoPath = _requiredString(map, const <String>['videoPath']);
    final metadataPath = _requiredString(map, const <String>[
      'metadataPath',
      'sidecarPath',
      'sidecar_path',
    ]);
    final normalizedDirectory = p.normalize(p.absolute(directoryPath));
    final normalizedVideo = p.normalize(p.absolute(videoPath));
    final normalizedMetadata = p.normalize(p.absolute(metadataPath));
    if (!p.isWithin(normalizedDirectory, normalizedVideo) ||
        !p.isWithin(normalizedDirectory, normalizedMetadata) ||
        p.extension(normalizedVideo).toLowerCase() != '.mp4' ||
        p.extension(normalizedMetadata).toLowerCase() != '.json') {
      throw const FormatException('原生切片文件路径无效');
    }
    if (p.basename(normalizedMetadata).toLowerCase() != 'metadata.json' &&
        p.basenameWithoutExtension(normalizedVideo).toLowerCase() !=
            p.basenameWithoutExtension(normalizedMetadata).toLowerCase()) {
      throw const FormatException('扁平 MP4 与 JSON 必须使用相同文件名');
    }
    final videoWidth = _positiveInt(map['videoWidth'], field: 'videoWidth');
    final videoHeight = _positiveInt(map['videoHeight'], field: 'videoHeight');
    if (videoWidth != captureVideoWidth || videoHeight != captureVideoHeight) {
      throw const FormatException('原生切片视频必须是 1920x1080');
    }
    final captureIntervalSeconds = schemaVersion == 3
        ? 1
        : _positiveInt(
            map['captureIntervalSeconds'],
            field: 'captureIntervalSeconds',
          );
    final videoFrameRateNumerator = schemaVersion == 3
        ? 1
        : _positiveInt(
            map['videoFrameRateNumerator'],
            field: 'videoFrameRateNumerator',
          );
    final videoFrameRateDenominator = schemaVersion == 3
        ? 1
        : _positiveInt(
            map['videoFrameRateDenominator'],
            field: 'videoFrameRateDenominator',
          );
    final videoFrameDurationTicks = schemaVersion == 3
        ? 10000000
        : _positiveInt(
            map['videoFrameDurationTicks'],
            field: 'videoFrameDurationTicks',
          );
    if (schemaVersion == 4 &&
        (captureIntervalSeconds != 1 &&
                captureIntervalSeconds != 10 &&
                captureIntervalSeconds != 20 &&
                captureIntervalSeconds != 30 ||
            videoFrameRateNumerator != 1 ||
            videoFrameRateDenominator != captureIntervalSeconds ||
            videoFrameDurationTicks != captureIntervalSeconds * 10000000)) {
      throw const FormatException('schema 4 原生切片视频时序无效');
    }
    final startedAtMs = _timeMillis(
      _value(map, const <String>['startTimeMs', 'startedAtMs', 'startTime']),
      field: 'startTime',
    );
    final endedAtMs = _timeMillis(
      _value(map, const <String>['endTimeMs', 'endedAtMs', 'endTime']),
      field: 'endTime',
    );
    final durationMs = endedAtMs - startedAtMs;
    final declaredDurationMs = _optionalInt(map['durationMs']);
    if (endedAtMs <= startedAtMs || durationMs > 60000) {
      throw const FormatException('原生切片时长必须在 1 到 60000 毫秒之间');
    }
    if ((schemaVersion == 4 && declaredDurationMs == null) ||
        (map.containsKey('durationMs') && declaredDurationMs == null) ||
        (declaredDurationMs != null && declaredDurationMs != durationMs)) {
      throw const FormatException('原生切片 durationMs 与时间范围不一致');
    }
    final frameCount = _positiveInt(
      _value(map, const <String>['frameCount']) ?? counts['capturedFrames'],
      field: 'frameCount',
    );
    final maximumFrameCount = calculateMaximumChunkFrameCount(
      durationMs: durationMs,
      captureIntervalSeconds: captureIntervalSeconds,
    );
    if (frameCount > maximumFrameCount) {
      throw const FormatException('原生切片帧数超出实际时长允许的上限');
    }
    return NativeChunkCompletedEvent(
      schemaVersion: schemaVersion,
      sessionId: _requiredString(map, const <String>[
        'sessionId',
        'session_id',
      ]),
      chunkId: _requiredString(map, const <String>['chunkId', 'chunk_id']),
      captureScope: captureScope,
      directoryPath: directoryPath,
      videoPath: videoPath,
      metadataPath: metadataPath,
      startedAtMs: startedAtMs,
      endedAtMs: endedAtMs,
      frameCount: frameCount,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      captureIntervalSeconds: captureIntervalSeconds,
      videoFrameRateNumerator: videoFrameRateNumerator,
      videoFrameRateDenominator: videoFrameRateDenominator,
      videoFrameDurationTicks: videoFrameDurationTicks,
      windowRecords: List<NativeWindowRecord>.unmodifiable(records),
    );
  }

  final int schemaVersion;
  final String sessionId;
  final String chunkId;
  final String captureScope;
  final String directoryPath;
  final String videoPath;
  final String metadataPath;
  final int startedAtMs;
  final int endedAtMs;
  final int frameCount;
  final int videoWidth;
  final int videoHeight;
  final int captureIntervalSeconds;
  final int videoFrameRateNumerator;
  final int videoFrameRateDenominator;
  final int videoFrameDurationTicks;
  final List<NativeWindowRecord> windowRecords;
}

final class NativeExtractedVideoFrame {
  const NativeExtractedVideoFrame({
    required this.offsetMs,
    required this.jpegBytes,
  });

  factory NativeExtractedVideoFrame.fromMap(Map<Object?, Object?> map) {
    final bytes = map['jpegBytes'];
    if (bytes is! Uint8List ||
        bytes.length < 4 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes[bytes.length - 1] != 0xd9) {
      throw const FormatException('jpegBytes 必须是合法 JPEG Uint8List');
    }
    return NativeExtractedVideoFrame(
      offsetMs: _requiredInt(map, const <String>['offsetMs']),
      jpegBytes: bytes,
    );
  }

  final int offsetMs;
  final Uint8List jpegBytes;
}

final class NativeCaptureErrorEvent extends NativeCaptureEvent {
  const NativeCaptureErrorEvent({
    required this.code,
    required this.message,
    required this.recoverable,
    required this.sessionId,
  });

  final String code;
  final String message;
  final bool recoverable;
  final String sessionId;
}

final class NativeQuitRequestedEvent extends NativeCaptureEvent {
  const NativeQuitRequestedEvent();
}

final class NativeTrayCommandEvent extends NativeCaptureEvent {
  const NativeTrayCommandEvent({required this.command});

  final NativeTrayCommand command;
}

class NativeCaptureService {
  NativeCaptureService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methods = methodChannel ?? const MethodChannel(_methodChannelName),
       _eventChannel = eventChannel ?? const EventChannel(_eventChannelName);

  final MethodChannel _methods;
  final EventChannel _eventChannel;
  Stream<NativeCaptureEvent>? _events;
  final Map<String, Future<Uint8List?>> _executableIconCache =
      <String, Future<Uint8List?>>{};

  Stream<NativeCaptureEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map((value) => NativeCaptureEvent.fromMap(_asMap(value)))
      .asBroadcastStream();

  Future<Map<Object?, Object?>> getCapabilities() async =>
      _asMap(await _methods.invokeMethod<Object?>('getCapabilities'));

  Future<void> start(NativeCaptureConfiguration configuration) =>
      _methods.invokeMethod<void>('startCapture', configuration.toMap());

  Future<void> pause() => _methods.invokeMethod<void>('pauseCapture');

  Future<void> resume() => _methods.invokeMethod<void>('resumeCapture');

  Future<void> stop() => _methods.invokeMethod<void>('stopCapture');

  Future<Map<Object?, Object?>> getState() async =>
      _asMap(await _methods.invokeMethod<Object?>('getCaptureState'));

  Future<void> configureLogging({
    required AppLogLevel level,
    required String logDirectory,
    int maxBytes = 1024 * 1024,
    int maxBackups = 3,
  }) {
    final directory = p.windows.normalize(logDirectory.trim());
    if (!p.windows.isAbsolute(directory)) {
      throw ArgumentError.value(logDirectory, 'logDirectory', '必须是绝对路径');
    }
    if (maxBytes < 64 * 1024 || maxBytes > 100 * 1024 * 1024) {
      throw RangeError.range(
        maxBytes,
        64 * 1024,
        100 * 1024 * 1024,
        'maxBytes',
      );
    }
    if (maxBackups < 0 || maxBackups > 10) {
      throw RangeError.range(maxBackups, 0, 10, 'maxBackups');
    }
    return _methods.invokeMethod<void>('configureLogging', <String, Object>{
      'level': level.name.toUpperCase(),
      'logDirectory': directory,
      'maxBytes': maxBytes,
      'maxBackups': maxBackups,
    });
  }

  Future<void> closeLogging() => _methods.invokeMethod<void>('closeLogging');

  Future<bool> queryLaunchAtLogin() async {
    final value = await _methods.invokeMethod<Object?>('queryLaunchAtLogin');
    if (value is! bool) {
      throw const FormatException('queryLaunchAtLogin 必须返回布尔值');
    }
    return value;
  }

  Future<void> setLaunchAtLogin(bool enabled) => _methods.invokeMethod<void>(
    'setLaunchAtLogin',
    <String, Object>{'enabled': enabled},
  );

  Future<void> updateTrayCaptureState(NativeTrayCaptureState state) =>
      _methods.invokeMethod<void>('updateTrayCaptureState', <String, Object>{
        'state': state.name,
      });

  Future<String> protectText(String plaintext) async {
    if (plaintext.isEmpty) {
      throw ArgumentError.value(plaintext, 'plaintext', '不能为空');
    }
    final value = await _methods.invokeMethod<Object?>(
      'protectSecret',
      <String, Object>{'plaintext': plaintext},
    );
    return _protectedResult(value);
  }

  Future<String> unprotectText(String protectedData) async {
    if (protectedData.isEmpty) {
      throw ArgumentError.value(protectedData, 'protectedData', '不能为空');
    }
    final value = await _methods.invokeMethod<Object?>(
      'unprotectSecret',
      <String, Object>{'protectedData': protectedData},
    );
    return _plaintextResult(value);
  }

  Future<List<int>> protectSecret(List<int> plaintext) async {
    final value = await _methods.invokeMethod<Object?>(
      'protectSecret',
      Uint8List.fromList(plaintext),
    );
    if (value is Uint8List) {
      return value;
    }
    throw const FormatException('DPAPI 加密返回值格式无效');
  }

  Future<List<int>> unprotectSecret(List<int> protectedData) async {
    final value = await _methods.invokeMethod<Object?>(
      'unprotectSecret',
      Uint8List.fromList(protectedData),
    );
    if (value is Uint8List) {
      return value;
    }
    throw const FormatException('DPAPI 解密返回值格式无效');
  }

  Future<String?> selectDirectory({String? initialDirectory}) async {
    final value = await _methods.invokeMethod<Object?>(
      'selectDirectory',
      <String, Object?>{'initialDirectory': initialDirectory},
    );
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    return _asMap(value)['path']?.toString();
  }

  Future<String> getDefaultDataDirectory() async {
    final value = await _methods.invokeMethod<Object?>(
      'getDefaultDataDirectory',
    );
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    return _requiredString(_asMap(value), const <String>['path']);
  }

  Future<Uint8List?> getExecutableIcon(String executablePath, {int size = 32}) {
    final path = _validateExecutablePath(executablePath);
    if (size != 32 && size != 48) {
      throw ArgumentError.value(size, 'size', '只支持 32 或 48 像素');
    }
    final cacheKey = '$size:${path.toLowerCase()}';
    return _executableIconCache.putIfAbsent(cacheKey, () async {
      try {
        final value = await _methods.invokeMethod<Object?>(
          'getExecutableIcon',
          <String, Object>{'executablePath': path, 'size': size},
        );
        final bytes = switch (value) {
          Uint8List() => value,
          Map() => _asMap(value)['pngBytes'],
          _ => null,
        };
        if (bytes is! Uint8List ||
            bytes.length < 8 ||
            bytes.length > 2 * 1024 * 1024 ||
            bytes[0] != 0x89 ||
            bytes[1] != 0x50 ||
            bytes[2] != 0x4e ||
            bytes[3] != 0x47) {
          return null;
        }
        return bytes;
      } on MissingPluginException {
        return null;
      } on PlatformException {
        return null;
      }
    });
  }

  Future<bool> revealExecutableInExplorer(String executablePath) async {
    final path = _validateExecutablePath(executablePath);
    final value = await _methods.invokeMethod<Object?>(
      'revealExecutableInExplorer',
      <String, Object>{'executablePath': path},
    );
    if (value is bool) return value;
    if (value is Map) return _asMap(value)['revealed'] == true;
    throw const FormatException('Explorer 返回值格式无效');
  }

  Future<bool> openDirectoryInExplorer(String directoryPath) async {
    final path = _validateWindowsDirectoryPath(directoryPath);
    final value = await _methods.invokeMethod<Object?>(
      'openDirectoryInExplorer',
      <String, Object>{'directoryPath': path},
    );
    if (value is bool) return value;
    if (value is Map) return _asMap(value)['opened'] == true;
    throw const FormatException('Explorer 返回值格式无效');
  }

  Future<List<NativeExtractedVideoFrame>> extractVideoFrames({
    required String videoPath,
    required String captureRoot,
    required int expectedFrameCount,
    int maxFrames = 8,
    int maxWidth = 1920,
    int maxHeight = 1080,
    int jpegQuality = 85,
    int maxFrameBytes = 2 * 1024 * 1024,
    int maxTotalBytes = 12 * 1024 * 1024,
  }) async {
    if (videoPath.trim().isEmpty ||
        captureRoot.trim().isEmpty ||
        expectedFrameCount < 0 ||
        expectedFrameCount > 36000 ||
        maxFrames < 1 ||
        maxFrames > 8 ||
        maxWidth < 1 ||
        maxWidth > 1920 ||
        maxHeight < 1 ||
        maxHeight > 1080 ||
        jpegQuality < 25 ||
        jpegQuality > 95 ||
        maxFrameBytes < 1024 ||
        maxFrameBytes > 2 * 1024 * 1024 ||
        maxTotalBytes < maxFrameBytes ||
        maxTotalBytes > 12 * 1024 * 1024) {
      throw ArgumentError('MP4 抽帧参数超出安全限额');
    }
    final value = await _methods
        .invokeMethod<Object?>('extractVideoFrames', <String, Object>{
          'videoPath': videoPath,
          'captureRoot': captureRoot,
          'expectedFrameCount': expectedFrameCount,
          'maxFrames': maxFrames,
          'maxWidth': maxWidth,
          'maxHeight': maxHeight,
          'jpegQuality': jpegQuality,
          'maxFrameBytes': maxFrameBytes,
          'maxTotalBytes': maxTotalBytes,
        });
    final frames = _requiredList(value, field: 'extractVideoFrames')
        .map((item) => NativeExtractedVideoFrame.fromMap(_asMap(item)))
        .toList(growable: false);
    if (frames.isEmpty || frames.length > maxFrames) {
      throw const FormatException('原生 MP4 抽帧数量无效');
    }
    var totalBytes = 0;
    var previousOffset = -1;
    for (final frame in frames) {
      totalBytes += frame.jpegBytes.length;
      if (frame.offsetMs < 0 ||
          frame.offsetMs <= previousOffset ||
          frame.jpegBytes.length > maxFrameBytes ||
          totalBytes > maxTotalBytes) {
        throw const FormatException('原生 MP4 抽帧结果超出限额或顺序无效');
      }
      previousOffset = frame.offsetMs;
    }
    return List<NativeExtractedVideoFrame>.unmodifiable(frames);
  }

  Future<bool> deleteChunkArtifacts({
    required String captureRoot,
    required String directoryPath,
    required String metadataPath,
    String? videoPath,
    List<String> framePaths = const <String>[],
  }) async {
    try {
      final value = await _methods
          .invokeMethod<Object?>('deleteChunk', <String, Object?>{
            'captureRoot': captureRoot,
            'directoryPath': directoryPath,
            'metadataPath': metadataPath,
            'videoPath': videoPath,
            'framePaths': framePaths,
          });
      if (value == null) {
        return true;
      }
      if (value is bool) {
        return value;
      }
      return value is Map && _asMap(value)['deleted'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      if (error.code == 'notImplemented' || error.code == 'unsupported') {
        return false;
      }
      rethrow;
    }
  }

  Future<void> showWindow() => _methods.invokeMethod<void>('showWindow');

  Future<void> hideWindow() => _methods.invokeMethod<void>('hideWindow');

  Future<void> requestExit() => _methods.invokeMethod<void>('quitApplication');

  Future<void> shutdownNative() => _methods.invokeMethod<void>('shutdown');
}

String _validateExecutablePath(String value) {
  final path = p.normalize(value.trim());
  final extension = p.extension(path).toLowerCase();
  if (path.isEmpty ||
      path.contains('\u0000') ||
      !p.isAbsolute(path) ||
      !const <String>{'.exe', '.com'}.contains(extension)) {
    throw ArgumentError.value(value, 'executablePath', '必须是绝对可执行文件路径');
  }
  return path;
}

String _validateWindowsDirectoryPath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('\u0000')) {
    throw ArgumentError.value(value, 'directoryPath', '必须是 Windows 绝对目录路径');
  }
  final path = p.windows.normalize(trimmed);
  if (!p.windows.isAbsolute(path)) {
    throw ArgumentError.value(value, 'directoryPath', '必须是 Windows 绝对目录路径');
  }
  return path;
}

Map<Object?, Object?> _asMap(Object? value) {
  if (value is Map<Object?, Object?>) {
    return value;
  }
  if (value is Map) {
    return Map<Object?, Object?>.from(value);
  }
  throw FormatException('预期对象，实际为 ${value.runtimeType}');
}

List<Object?> _requiredList(Object? value, {required String field}) {
  if (value is List) {
    return List<Object?>.from(value);
  }
  throw FormatException('$field 必须是数组');
}

List<Object?> _optionalList(Object? value) =>
    value == null ? const <Object?>[] : _requiredList(value, field: 'list');

Object? _value(Map<Object?, Object?> map, List<String> keys) {
  for (final key in keys) {
    if (map.containsKey(key)) {
      return map[key];
    }
  }
  return null;
}

String _requiredString(Map<Object?, Object?> map, List<String> keys) {
  final value = _value(map, keys);
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  throw FormatException('${keys.first} 必须是非空字符串');
}

String? _optionalString(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw const FormatException('可选字段必须是字符串');
  }
  final result = value.trim();
  return result.isEmpty ? null : result;
}

int _requiredInt(Map<Object?, Object?> map, List<String> keys) {
  final value = _optionalInt(_value(map, keys));
  if (value == null) {
    throw FormatException('${keys.first} 必须是整数');
  }
  return value;
}

int _positiveInt(Object? value, {required String field}) {
  final integer = _optionalInt(value);
  if (integer == null || integer <= 0) {
    throw FormatException('$field 必须是正整数');
  }
  return integer;
}

int? _optionalInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

double? _optionalPercentage(Object? value, {required String field}) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0 || value > 100) {
    throw FormatException('$field 必须是 0 到 100 的有限数字或 null');
  }
  return value.toDouble();
}

int? _optionalNonNegativeInt(Object? value, {required String field}) {
  if (value == null) return null;
  final result = _optionalInt(value);
  if (result == null || result < 0) {
    throw FormatException('$field 必须是非负整数或 null');
  }
  return result;
}

int _nonNegativeInt(Object? value, {required String field}) {
  final result = _optionalInt(value);
  if (result == null || result < 0) {
    throw FormatException('$field 必须是非负整数');
  }
  return result;
}

int _timeMillis(Object? value, {required String field}) {
  final integer = _optionalInt(value);
  if (integer != null) {
    return integer;
  }
  if (value is String) {
    try {
      return DateTime.parse(value).millisecondsSinceEpoch;
    } on FormatException {
      throw FormatException('$field 必须是 epoch ms 或 ISO 8601 时间');
    }
  }
  throw FormatException('$field 必须是 epoch ms 或 ISO 8601 时间');
}

String _protectedResult(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  if (value is Uint8List && value.isNotEmpty) {
    return base64Encode(value);
  }
  if (value is Map) {
    final nested = _value(_asMap(value), const <String>[
      'ciphertext',
      'protectedData',
      'value',
    ]);
    return _protectedResult(nested);
  }
  throw const FormatException('DPAPI 加密返回值格式无效');
}

String _plaintextResult(Object? value) {
  if (value is String) {
    return value;
  }
  if (value is Uint8List) {
    return utf8.decode(value);
  }
  if (value is Map) {
    final nested = _value(_asMap(value), const <String>['plaintext', 'value']);
    return _plaintextResult(nested);
  }
  throw const FormatException('DPAPI 解密返回值格式无效');
}

NativeCaptureStatus _parseStatus(String value) => switch (value) {
  'stopped' || 'idle' => NativeCaptureStatus.stopped,
  'starting' => NativeCaptureStatus.starting,
  'capturing' || 'recording' => NativeCaptureStatus.capturing,
  'paused' || 'idlePaused' => NativeCaptureStatus.paused,
  'stopping' => NativeCaptureStatus.stopping,
  'error' => NativeCaptureStatus.error,
  _ => throw FormatException('未知采集状态: $value'),
};
