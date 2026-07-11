import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/services/logging/app_logger.dart';
import 'package:qi_day_flow/services/logging/managed_log_service.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('initial size and clear stay on the active data directory', () async {
    final root = await Directory.systemTemp.createTemp('qi_logs_controller_');
    final active = Directory(p.windows.join(root.path, 'active'));
    final pending = Directory(p.windows.join(root.path, 'pending'));
    final activeLogs = Directory(p.windows.join(active.path, 'logs'));
    final pendingLogs = Directory(p.windows.join(pending.path, 'logs'));
    await activeLogs.create(recursive: true);
    await pendingLogs.create(recursive: true);
    final activeManaged = await _writeBytes(
      activeLogs.path,
      'qi_day_flow.log.1',
      5,
    );
    final activeUnknown = await _writeBytes(
      activeLogs.path,
      'private-tool.log',
      7,
    );
    final pendingManaged = await _writeBytes(
      pendingLogs.path,
      'native-capture.log',
      11,
    );
    final harness = await _LogControllerHarness.create(active: active);
    addTearDown(() async {
      await harness.dispose();
      await root.delete(recursive: true);
    });

    await harness.controller.initialize();
    expect(harness.controller.managedLogBytes, 5);
    expect(harness.controller.managedLogError, isNull);

    await harness.controller.saveSettings(
      SettingsDraft(
        apiUrl: harness.controller.settings.apiUrl,
        apiKey: '',
        model: harness.controller.settings.model,
        userDataDirectory: pending.path,
        cacheLimitGb: harness.controller.settings.cacheLimitGb,
        idlePauseEnabled: harness.controller.settings.idlePauseEnabled,
        idleTimeoutMinutes: harness.controller.settings.idleTimeoutMinutes,
        themeMode: harness.controller.settings.themeMode,
        logLevel: harness.controller.settings.logLevel,
        apiKeyChanged: false,
      ),
    );
    expect(harness.controller.settings.dataDirectoryRestartRequired, isTrue);

    await harness.controller.clearManagedLogs();

    expect(await activeManaged.exists(), isFalse);
    expect(await activeUnknown.exists(), isTrue);
    expect(await pendingManaged.exists(), isTrue);
    expect(await activeLogs.exists(), isTrue);
    expect(harness.controller.managedLogBytes, 0);
    expect(harness.controller.managedLogError, isNull);
    final closeIndex = harness.native.calls.lastIndexOf('closeLogging');
    final configureIndex = harness.native.calls.lastIndexOf('configureLogging');
    expect(closeIndex, greaterThanOrEqualTo(0));
    expect(configureIndex, greaterThan(closeIndex));
    expect(
      harness.native.lastLogDirectory,
      p.windows.join(active.path, 'logs'),
    );
  });

  test('partial deletion failure stays visible and logging resumes', () async {
    final root = await Directory.systemTemp.createTemp('qi_logs_controller_');
    final active = Directory(p.windows.join(root.path, 'active'));
    final logs = Directory(p.windows.join(active.path, 'logs'));
    await logs.create(recursive: true);
    final dartLog = await _writeBytes(logs.path, 'qi_day_flow.log', 3);
    final failed = await _writeBytes(logs.path, 'native-capture.log.1', 9);
    final logger = AppLogger(logDirectory: logs.path);
    final service = ManagedLogService(
      activeUserDataDirectory: active.path,
      fileSystem: _DeleteFailureFileSystem(failed.path),
    );
    final harness = await _LogControllerHarness.create(
      active: active,
      logger: logger,
      managedLogService: service,
    );
    addTearDown(() async {
      await logger.close();
      await harness.dispose();
      await root.delete(recursive: true);
    });
    await harness.controller.initialize();

    await expectLater(
      harness.controller.clearManagedLogs(),
      throwsA(isA<StateError>()),
    );

    expect(await dartLog.exists(), isFalse);
    expect(await failed.exists(), isTrue);
    expect(harness.controller.clearingManagedLogs, isFalse);
    expect(harness.controller.managedLogBytes, 9);
    expect(harness.controller.managedLogError, contains('1 个日志文件清理失败'));
    await logger.log(AppLogLevel.info, 'after.log_cleanup');
    expect(
      await File(p.windows.join(logs.path, AppLogger.fileName)).exists(),
      isTrue,
    );
    final closeIndex = harness.native.calls.lastIndexOf('closeLogging');
    final configureIndex = harness.native.calls.lastIndexOf('configureLogging');
    expect(configureIndex, greaterThan(closeIndex));
  });

  test('periodic maintenance refreshes managed log size', () async {
    final root = await Directory.systemTemp.createTemp('qi_logs_controller_');
    final active = Directory(p.windows.join(root.path, 'active'));
    final logs = Directory(p.windows.join(active.path, 'logs'));
    await logs.create(recursive: true);
    await _writeBytes(logs.path, 'qi_day_flow.log', 3);
    final harness = await _LogControllerHarness.create(
      active: active,
      maintenanceInterval: const Duration(milliseconds: 20),
    );
    addTearDown(() async {
      await harness.dispose();
      await root.delete(recursive: true);
    });
    await harness.controller.initialize();
    expect(harness.controller.managedLogBytes, 3);

    await _writeBytes(logs.path, 'native-capture.log.1', 7);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (harness.controller.managedLogBytes != 10 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(harness.controller.managedLogBytes, 10);
  });
}

Future<File> _writeBytes(String directory, String name, int count) async {
  final file = File(p.windows.join(directory, name));
  await file.writeAsBytes(List<int>.filled(count, 1));
  return file;
}

final class _LogControllerHarness {
  const _LogControllerHarness({
    required this.database,
    required this.native,
    required this.controller,
  });

  static Future<_LogControllerHarness> create({
    required Directory active,
    AppLogger? logger,
    ManagedLogService? managedLogService,
    Duration maintenanceInterval = const Duration(seconds: 30),
  }) async {
    await Directory(
      p.windows.join(active.path, 'captures'),
    ).create(recursive: true);
    final database = AppDatabase(
      path: p.windows.join(active.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    final native = _RecordingNativeCaptureService();
    final controller = AppController(
      database: database,
      repository: repository,
      nativeService: native,
      settingsService: SecureSettingsService(
        repository: repository,
        platform: native,
        defaultUserDataDirectory: active.path,
      ),
      activeUserDataDirectory: active.path,
      logger: logger,
      managedLogService: managedLogService,
      maintenanceInterval: maintenanceInterval,
    );
    return _LogControllerHarness(
      database: database,
      native: native,
      controller: controller,
    );
  }

  final AppDatabase database;
  final _RecordingNativeCaptureService native;
  final AppController controller;

  Future<void> dispose() async {
    controller.dispose();
    await database.close();
  }
}

final class _RecordingNativeCaptureService extends NativeCaptureService {
  _RecordingNativeCaptureService()
    : super(
        methodChannel: const MethodChannel('qi_day_flow/test/logs-unused'),
        eventChannel: const EventChannel('qi_day_flow/test/logs-unused-events'),
      );

  final List<String> calls = <String>[];
  String? lastLogDirectory;

  @override
  Stream<NativeCaptureEvent> get events =>
      const Stream<NativeCaptureEvent>.empty();

  @override
  Future<void> closeLogging() async {
    calls.add('closeLogging');
  }

  @override
  Future<void> configureLogging({
    required AppLogLevel level,
    required String logDirectory,
    int maxBytes = 1024 * 1024,
    int maxBackups = 3,
  }) async {
    calls.add('configureLogging');
    lastLogDirectory = logDirectory;
  }

  @override
  Future<void> updateTrayCaptureState(NativeTrayCaptureState state) async {}
}

final class _DeleteFailureFileSystem implements ManagedLogFileSystem {
  _DeleteFailureFileSystem(String failedPath)
    : _failedPath = p.windows.normalize(failedPath).toLowerCase();

  final String _failedPath;
  final ManagedLogFileSystem _delegate = const LocalManagedLogFileSystem();

  @override
  Future<void> deleteFile(String path) {
    if (p.windows.normalize(path).toLowerCase() == _failedPath) {
      throw const FileSystemException('injected delete failure');
    }
    return _delegate.deleteFile(path);
  }

  @override
  Future<FileSystemEntityType> entityTypeNoFollow(String path) =>
      _delegate.entityTypeNoFollow(path);

  @override
  Future<int> fileLength(String path) => _delegate.fileLength(path);

  @override
  Future<List<String>> listChildren(String directory) =>
      _delegate.listChildren(directory);

  @override
  Future<String> resolveDirectory(String path) =>
      _delegate.resolveDirectory(path);

  @override
  Future<String> resolveFile(String path) => _delegate.resolveFile(path);
}
