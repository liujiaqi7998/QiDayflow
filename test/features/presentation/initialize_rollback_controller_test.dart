import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/services/logging/app_logger.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:qi_day_flow/services/update/update_check_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final failure in _InitializationFailure.values) {
    test('initialize rolls back after ${failure.name} failure', () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_initialize_rollback_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = AppDatabase(
        path: p.join(root.path, 'dayflow.db'),
        databaseFactory: databaseFactoryFfi,
      );
      final repository = SqliteDayFlowRepository(database);
      final native = _RollbackNativeService(
        failConfigureLogging: failure == _InitializationFailure.logConfigure,
      );
      final transport = _CloseTrackingUpdateTransport();
      final logger = AppLogger(logDirectory: p.join(root.path, 'logs'));
      final controller = AppController(
        database: database,
        repository: repository,
        nativeService: native,
        settingsService: SecureSettingsService(
          repository: repository,
          platform: native,
          defaultUserDataDirectory: root.path,
        ),
        activeUserDataDirectory: root.path,
        logger: logger,
        updateCheckService: UpdateCheckService(
          currentVersion: '1.0.0',
          transport: transport,
        ),
        initializationStageHook: (stage) async {
          if (failure == _InitializationFailure.settingsLoad &&
              stage == AppInitializationStage.settingsLoaded) {
            throw StateError('settings stage failure');
          }
          if (failure == _InitializationFailure.refresh &&
              stage == AppInitializationStage.beforeDerivedRefresh) {
            throw StateError('refresh stage failure');
          }
        },
      );

      await expectLater(controller.initialize(), throwsStateError);

      expect(database.isOpen, isFalse);
      expect(native.subscriptionCancelCount, 1);
      expect(transport.closed, isTrue);
      expect(logger.isClosed, isTrue);
      expect(native.requestExitCalls, 0);
      expect(
        native.closeLoggingCalls,
        failure == _InitializationFailure.settingsLoad ? 0 : 1,
      );

      final retryDatabase = AppDatabase(
        path: database.path,
        databaseFactory: databaseFactoryFfi,
      );
      final retryRepository = SqliteDayFlowRepository(retryDatabase);
      final retryNative = _RollbackNativeService();
      final retryController = AppController(
        database: retryDatabase,
        repository: retryRepository,
        nativeService: retryNative,
        settingsService: SecureSettingsService(
          repository: retryRepository,
          platform: retryNative,
          defaultUserDataDirectory: root.path,
        ),
        activeUserDataDirectory: root.path,
      );
      await retryController.initialize();
      expect(retryDatabase.isOpen, isTrue);
      await retryController.shutdown();
      retryController.dispose();
      controller.dispose();
      await native.close();
      await retryNative.close();
    });
  }

  test('exit request is sent once even when resource cleanup fails', () async {
    final root = await Directory.systemTemp.createTemp(
      'qi_day_flow_exit_cleanup_failure_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final database = AppDatabase(
      path: p.join(root.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    final native = _RollbackNativeService(failCloseLogging: true);
    final controller = AppController(
      database: database,
      repository: repository,
      nativeService: native,
      settingsService: SecureSettingsService(
        repository: repository,
        platform: native,
        defaultUserDataDirectory: root.path,
      ),
      activeUserDataDirectory: root.path,
    );
    await controller.initialize();

    await controller.exitApplication();
    await controller.exitApplication();

    expect(native.closeLoggingCalls, 1);
    expect(native.requestExitCalls, 1);
    controller.dispose();
    await native.close();
  });
}

enum _InitializationFailure { settingsLoad, logConfigure, refresh }

final class _RollbackNativeService extends NativeCaptureService {
  _RollbackNativeService({
    this.failConfigureLogging = false,
    this.failCloseLogging = false,
  }) : super(
         methodChannel: const MethodChannel('qi_day_flow/test/rollback-unused'),
         eventChannel: const EventChannel(
           'qi_day_flow/test/rollback-unused-events',
         ),
       ) {
    _controller = StreamController<NativeCaptureEvent>.broadcast(
      onCancel: () => subscriptionCancelCount++,
    );
  }

  final bool failConfigureLogging;
  final bool failCloseLogging;
  late final StreamController<NativeCaptureEvent> _controller;
  int subscriptionCancelCount = 0;
  int closeLoggingCalls = 0;
  int requestExitCalls = 0;

  @override
  Stream<NativeCaptureEvent> get events => _controller.stream;

  @override
  Future<bool> queryLaunchAtLogin() async => false;

  @override
  Future<void> configureLogging({
    required level,
    required String logDirectory,
    int maxBytes = 1024 * 1024,
    int maxBackups = 3,
  }) async {
    if (failConfigureLogging) throw StateError('configure logging failed');
  }

  @override
  Future<void> closeLogging() async {
    closeLoggingCalls++;
    if (failCloseLogging) throw StateError('close logging failed');
  }

  @override
  Future<void> updateTrayCaptureState(state) async {}

  @override
  Future<void> requestExit() async => requestExitCalls++;

  Future<void> close() => _controller.close();
}

final class _CloseTrackingUpdateTransport implements UpdateCheckTransport {
  bool closed = false;

  @override
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async => throw StateError('network must not run');

  @override
  void close() => closed = true;
}
