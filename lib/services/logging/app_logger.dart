import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/domain/domain.dart';

final class AppLogger {
  AppLogger({
    required String logDirectory,
    this.level = AppLogLevel.info,
    this.maxBytes = 1024 * 1024,
    this.maxBackups = 3,
    DateTime Function()? now,
  }) : _logDirectory = p.windows.normalize(logDirectory),
       _now = now ?? DateTime.now {
    if (!p.windows.isAbsolute(_logDirectory)) {
      throw ArgumentError.value(logDirectory, 'logDirectory', '必须是绝对路径');
    }
    if (maxBytes < 256) {
      throw ArgumentError.value(maxBytes, 'maxBytes', '不得小于 256');
    }
    if (maxBackups < 0 || maxBackups > 20) {
      throw RangeError.range(maxBackups, 0, 20, 'maxBackups');
    }
  }

  static const fileName = 'qi_day_flow.log';

  final String _logDirectory;
  final int maxBytes;
  final int maxBackups;
  final DateTime Function() _now;
  AppLogLevel level;
  Future<void> _tail = Future<void>.value();
  bool _paused = false;
  bool _closed = false;

  String get logDirectory => _logDirectory;
  bool get isClosed => _closed;

  bool isEnabled(AppLogLevel value) => value.index >= level.index;

  Future<void> log(
    AppLogLevel level,
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    if (_closed || _paused || !isEnabled(level)) return Future<void>.value();
    final normalizedEvent = event.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{0,95}$').hasMatch(normalizedEvent)) {
      throw ArgumentError.value(event, 'event', '必须是稳定的非敏感事件标识');
    }
    final safeFields = _sanitizeFields(fields);
    final timestamp = _now().toUtc().toIso8601String();
    final operation = _tail.then(
      (_) => _write(
        level: level,
        event: normalizedEvent,
        timestamp: timestamp,
        fields: safeFields,
      ),
    );
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> pauseAndFlush() async {
    _paused = true;
    await _tail;
  }

  void resume() {
    if (_closed) {
      throw StateError('已关闭的日志记录器不能恢复');
    }
    _paused = false;
  }

  Future<void> close() async {
    _closed = true;
    _paused = true;
    await _tail;
  }

  Future<void> _write({
    required AppLogLevel level,
    required String event,
    required String timestamp,
    required Map<String, Object?> fields,
  }) async {
    await Directory(_logDirectory).create(recursive: true);
    var line =
        '${jsonEncode(<String, Object?>{'timestamp': timestamp, 'level': level.name.toUpperCase(), 'event': event, if (fields.isNotEmpty) 'fields': fields})}\n';
    if (utf8.encode(line).length > maxBytes) {
      line =
          '${jsonEncode(<String, Object?>{
            'timestamp': timestamp,
            'level': level.name.toUpperCase(),
            'event': event,
            'fields': const <String, Object?>{'recordTruncated': true},
          })}\n';
    }
    final bytes = utf8.encode(line).length;
    final current = File(p.windows.join(_logDirectory, fileName));
    final currentBytes = await current.exists() ? await current.length() : 0;
    if (currentBytes > 0 && currentBytes + bytes > maxBytes) {
      await _rotate(current);
    }
    await current.writeAsString(line, mode: FileMode.append, flush: false);
  }

  Future<void> _rotate(File current) async {
    if (maxBackups == 0) {
      if (await current.exists()) await current.delete();
      return;
    }
    for (var index = maxBackups; index >= 2; index--) {
      final source = File('${current.path}.${index - 1}');
      if (!await source.exists()) continue;
      final target = File('${current.path}.$index');
      if (await target.exists()) await target.delete();
      await source.rename(target.path);
    }
    final firstBackup = File('${current.path}.1');
    if (await firstBackup.exists()) await firstBackup.delete();
    if (await current.exists()) await current.rename(firstBackup.path);
  }
}

Map<String, Object?> _sanitizeFields(Map<String, Object?> fields) {
  final sanitized = <String, Object?>{};
  for (final entry in fields.entries) {
    final normalizedKey = entry.key
        .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
        .toLowerCase();
    if (_sensitiveFieldKeys.any(normalizedKey.contains)) continue;
    final value = entry.value;
    if (value == null || value is num || value is bool) {
      sanitized[entry.key] = value;
    } else if (value is String) {
      sanitized[entry.key] = _sanitizeString(value);
    }
  }
  return Map<String, Object?>.unmodifiable(sanitized);
}

const _sensitiveFieldKeys = <String>[
  'apikey',
  'authorization',
  'base64',
  'jpeg',
  'image',
  'payload',
  'windowtitle',
  'windowname',
];

String _sanitizeString(String value) {
  var result = value;
  result = result.replaceAll(
    RegExp(
      r'authorization\s*[:=]\s*(?:bearer\s+)?[^\s,;]+',
      caseSensitive: false,
    ),
    'authorization=[REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\bbearer\s+[a-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\bsk-[a-z0-9_-]{6,}', caseSensitive: false),
    '[REDACTED_API_KEY]',
  );
  result = result.replaceAll(
    RegExp(r'data:image/[^;,\s]+;base64,[a-z0-9+/=]+', caseSensitive: false),
    '[REDACTED_IMAGE]',
  );
  result = result.replaceAll(
    RegExp(r'/9j/[a-z0-9+/=]*', caseSensitive: false),
    '[REDACTED_JPEG]',
  );
  result = result.replaceAll(
    RegExp(r'\b[a-z0-9+/]{80,}={0,2}\b', caseSensitive: false),
    '[REDACTED_BASE64]',
  );
  return result.length <= 256 ? result : '${result.substring(0, 253)}...';
}
