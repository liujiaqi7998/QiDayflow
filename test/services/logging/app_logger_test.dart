import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/logging/app_logger.dart';

void main() {
  test('filters levels and never writes sensitive fields or payloads', () async {
    final root = await Directory.systemTemp.createTemp('qi_day_flow_logger_');
    addTearDown(() => root.delete(recursive: true));
    final logger = AppLogger(logDirectory: root.path, maxBytes: 4096);

    await logger.log(
      AppLogLevel.debug,
      'capture.debug',
      fields: const {'count': 1},
    );
    await logger.log(
      AppLogLevel.info,
      'analysis.completed',
      fields: const <String, Object?>{
        'count': 2,
        'apiKey': 'test-key-placeholder',
        'Authorization': 'Bearer authorization-secret',
        'jpegBase64': '/9j/base64-payload',
        'windowTitle': 'Confidential payroll window',
        'note':
            'Authorization: Bearer nested-secret data:image/jpeg;base64,/9j/abc',
      },
    );
    await logger.close();

    final content = await File(
      p.join(root.path, 'qi_day_flow.log'),
    ).readAsString();
    expect(content, contains('analysis.completed'));
    expect(content, contains('"count":2'));
    expect(content, isNot(contains('capture.debug')));
    for (final secret in <String>[
      'test-key-placeholder',
      'authorization-secret',
      '/9j/',
      'Confidential payroll window',
      'nested-secret',
      'data:image',
    ]) {
      expect(content, isNot(contains(secret)));
    }
  });

  test('changes level immediately and rotates within the size cap', () async {
    final root = await Directory.systemTemp.createTemp('qi_day_flow_logger_');
    addTearDown(() => root.delete(recursive: true));
    final logger = AppLogger(
      logDirectory: root.path,
      maxBytes: 256,
      maxBackups: 2,
    );
    logger.level = AppLogLevel.warning;
    await logger.log(AppLogLevel.info, 'filtered.info');
    for (var index = 0; index < 12; index++) {
      await logger.log(
        AppLogLevel.error,
        'rotation.record',
        fields: <String, Object?>{'index': index, 'status': 'failed'},
      );
    }
    await logger.close();

    final files = root
        .listSync()
        .whereType<File>()
        .where((file) => p.basename(file.path).startsWith('qi_day_flow.log'))
        .toList();
    expect(files, hasLength(3));
    expect(files.every((file) => file.lengthSync() <= 256), isTrue);
    final allContent = (await Future.wait(
      files.map((file) => file.readAsString()),
    )).join();
    expect(allContent, isNot(contains('filtered.info')));
    expect(allContent, contains('rotation.record'));
  });

  test(
    'pauseAndFlush drains queued writes and resume cannot reopen after close',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_logger_pause_',
      );
      addTearDown(() => root.delete(recursive: true));
      final logger = AppLogger(logDirectory: root.path, maxBytes: 4096);

      final queued = logger.log(AppLogLevel.info, 'before.pause');
      await logger.pauseAndFlush();
      await queued;
      await logger.log(AppLogLevel.error, 'while.paused');

      final current = File(p.join(root.path, AppLogger.fileName));
      final paused = await current.rename(
        p.join(root.path, '${AppLogger.fileName}.paused'),
      );
      final pausedContent = await paused.readAsString();
      expect(pausedContent, contains('before.pause'));
      expect(pausedContent, isNot(contains('while.paused')));

      logger.resume();
      await logger.log(AppLogLevel.info, 'after.resume');
      await logger.close();
      final resumedContent = await current.readAsString();
      expect(resumedContent, contains('after.resume'));
      expect(resumedContent, isNot(contains('while.paused')));

      expect(logger.resume, throwsStateError);
      await logger.log(AppLogLevel.error, 'after.close');
      expect(await current.readAsString(), resumedContent);
    },
  );
}
