import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/services/data_directory_service.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'system launch state wins in memory and auto recording starts last',
    () async {
      final harness = await _createHarness(
        autoStartRecording: true,
        launchAtLogin: false,
        nativeHandler: (call) async => switch (call.method) {
          'queryLaunchAtLogin' => true,
          _ => null,
        },
      );
      addTearDown(harness.dispose);

      await harness.controller.initialize();

      expect(harness.controller.settings.launchAtLogin, isTrue);
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);
      expect(
        harness.nativeCalls.indexWhere(
          (call) => call.method == 'queryLaunchAtLogin',
        ),
        lessThan(
          harness.nativeCalls.indexWhere(
            (call) => call.method == 'startCapture',
          ),
        ),
      );
      final stored = await _storedSettings(harness.repository);
      expect(stored.launchAtLogin, isFalse);
    },
  );

  test('auto recording failure does not abort initialization', () async {
    final harness = await _createHarness(
      autoStartRecording: true,
      launchAtLogin: false,
      nativeHandler: (call) async {
        if (call.method == 'queryLaunchAtLogin') return false;
        if (call.method == 'startCapture') {
          throw PlatformException(code: 'capture-failed');
        }
        return null;
      },
    );
    addTearDown(harness.dispose);

    await harness.controller.initialize();

    expect(harness.controller.recordingStatus, RecordingViewStatus.error);
    expect(harness.controller.statusMessage, contains('启动采集失败'));
  });

  test(
    'native launch failure prevents persistence and reports save error',
    () async {
      final harness = await _createHarness(
        autoStartRecording: false,
        launchAtLogin: false,
        nativeHandler: (call) async {
          if (call.method == 'queryLaunchAtLogin') return false;
          if (call.method == 'setLaunchAtLogin') {
            throw PlatformException(code: 'registry-denied');
          }
          return null;
        },
      );
      addTearDown(harness.dispose);
      await harness.controller.initialize();

      await expectLater(
        harness.controller.saveSettings(
          _draft(
            harness.controller,
            autoStartRecording: true,
            launchAtLogin: true,
          ),
        ),
        throwsA(isA<PlatformException>()),
      );

      expect(harness.controller.settingsSaveStatus, SettingsSaveStatus.error);
      expect(harness.controller.settingsSaveError, contains('设置保存失败'));
      expect(harness.controller.settings.launchAtLogin, isFalse);
      final stored = await _storedSettings(harness.repository);
      expect(stored.autoStartRecording, isFalse);
      expect(stored.launchAtLogin, isFalse);
    },
  );

  test(
    'post-commit directory scheduling failure does not roll back settings',
    () async {
      late DataDirectoryService dataDirectoryService;
      late String differentActiveDirectory;
      final harness = await _createHarness(
        autoStartRecording: false,
        launchAtLogin: false,
        nativeHandler: (call) async => switch (call.method) {
          'queryLaunchAtLogin' => false,
          _ => null,
        },
        createDataDirectoryService: (root) {
          differentActiveDirectory = p.join(root, 'different-active');
          return dataDirectoryService = DataDirectoryService(
            locatorDirectory: p.join(root, 'locator'),
            defaultUserDataDirectory: differentActiveDirectory,
          );
        },
      );
      addTearDown(harness.dispose);
      await dataDirectoryService.scheduleChange(
        currentUserDataDirectory: differentActiveDirectory,
        nextUserDataDirectory: differentActiveDirectory,
      );
      await harness.controller.initialize();
      final nextDirectory = p.join(harness.root.path, 'next-data');

      await harness.controller.saveSettings(
        _draft(
          harness.controller,
          autoStartRecording: false,
          launchAtLogin: false,
          userDataDirectory: nextDirectory,
        ),
      );

      expect(harness.controller.settingsSaveStatus, SettingsSaveStatus.saved);
      expect(harness.controller.settings.userDataDirectory, nextDirectory);
      expect(
        (await _storedSettings(harness.repository)).userDataDirectory,
        nextDirectory,
      );
      expect(harness.controller.statusMessage, contains('目录迁移调度失败'));
    },
  );

  test('post-commit log apply failure keeps the persisted value', () async {
    var configureCalls = 0;
    final harness = await _createHarness(
      autoStartRecording: false,
      launchAtLogin: false,
      nativeHandler: (call) async {
        if (call.method == 'queryLaunchAtLogin') return false;
        if (call.method == 'configureLogging' && ++configureCalls > 1) {
          throw PlatformException(code: 'logger-unavailable');
        }
        return null;
      },
    );
    addTearDown(harness.dispose);
    await harness.controller.initialize();

    await expectLater(
      harness.controller.updateLogLevel(AppLogLevel.debug),
      completes,
    );

    expect(harness.controller.settings.logLevel, AppLogLevel.debug);
    expect(harness.controller.settingsSaveStatus, SettingsSaveStatus.saved);
    expect(harness.controller.statusMessage, contains('日志级别应用失败'));
    expect(
      (await _storedSettings(harness.repository)).logLevel,
      AppLogLevel.debug,
    );
  });

  test(
    'failed registry compensation re-queries and exposes the actual value',
    () async {
      var launchAtLogin = false;
      var setCalls = 0;
      final harness = await _createHarness(
        autoStartRecording: false,
        launchAtLogin: false,
        nativeHandler: (call) async {
          if (call.method == 'queryLaunchAtLogin') return launchAtLogin;
          if (call.method == 'setLaunchAtLogin') {
            setCalls++;
            final enabled =
                (call.arguments as Map<Object?, Object?>)['enabled'] as bool;
            if (setCalls == 2) {
              throw PlatformException(code: 'rollback-denied');
            }
            launchAtLogin = enabled;
            return null;
          }
          if (call.method == 'protectSecret') {
            throw PlatformException(code: 'settings-write-failed');
          }
          return null;
        },
      );
      addTearDown(harness.dispose);
      await harness.controller.initialize();

      await expectLater(
        harness.controller.saveSettings(
          _draft(
            harness.controller,
            autoStartRecording: false,
            launchAtLogin: true,
            apiKey: 'new-key',
            apiKeyChanged: true,
          ),
        ),
        throwsA(isA<StateError>()),
      );

      expect(setCalls, 2);
      expect(harness.controller.settings.launchAtLogin, isTrue);
      expect(harness.controller.settingsSaveStatus, SettingsSaveStatus.error);
      expect(
        (await _storedSettings(harness.repository)).launchAtLogin,
        isFalse,
      );
    },
  );
}

SettingsDraft _draft(
  AppController controller, {
  required bool autoStartRecording,
  required bool launchAtLogin,
  String? userDataDirectory,
  String apiKey = '',
  bool apiKeyChanged = false,
}) => SettingsDraft(
  apiUrl: controller.settings.apiUrl,
  apiKey: apiKey,
  apiKeyChanged: apiKeyChanged,
  model: controller.settings.model,
  userDataDirectory: userDataDirectory ?? controller.settings.userDataDirectory,
  cacheLimitGb: controller.settings.cacheLimitGb,
  idlePauseEnabled: controller.settings.idlePauseEnabled,
  idleTimeoutMinutes: controller.settings.idleTimeoutMinutes,
  captureIntervalSeconds: controller.settings.captureIntervalSeconds,
  themeMode: controller.settings.themeMode,
  logLevel: controller.settings.logLevel,
  autoStartRecording: autoStartRecording,
  launchAtLogin: launchAtLogin,
);

Future<AppSettings> _storedSettings(SettingsRepository repository) async {
  final record = await repository.getSetting('app_settings');
  return AppSettings.fromJson(jsonDecode(record!.value));
}

Future<_Harness> _createHarness({
  required bool autoStartRecording,
  required bool launchAtLogin,
  required Future<Object?> Function(MethodCall call) nativeHandler,
  DataDirectoryService Function(String root)? createDataDirectoryService,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'qi_day_flow_startup_settings_',
  );
  final database = AppDatabase(
    path: p.join(root.path, 'dayflow.db'),
    databaseFactory: databaseFactoryFfi,
  );
  final repository = SqliteDayFlowRepository(database);
  const methods = MethodChannel('qi_day_flow/test/startup-settings-methods');
  const events = EventChannel('qi_day_flow/test/startup-settings-events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <MethodCall>[];
  messenger.setMockMethodCallHandler(methods, (call) async {
    nativeCalls.add(call);
    return nativeHandler(call);
  });
  messenger.setMockMethodCallHandler(
    const MethodChannel('qi_day_flow/test/startup-settings-events'),
    (_) async => null,
  );
  final native = NativeCaptureService(
    methodChannel: methods,
    eventChannel: events,
  );
  final settingsService = SecureSettingsService(
    repository: repository,
    platform: native,
    defaultUserDataDirectory: root.path,
  );
  await settingsService.save(
    AppSettings.defaults(captureDirectory: root.path).copyWith(
      userDataDirectory: root.path,
      autoStartRecording: autoStartRecording,
      launchAtLogin: launchAtLogin,
    ),
  );
  final controller = AppController(
    database: database,
    repository: repository,
    nativeService: native,
    settingsService: settingsService,
    dataDirectoryService: createDataDirectoryService?.call(root.path),
    activeUserDataDirectory: root.path,
  );
  return _Harness(
    root: root,
    database: database,
    repository: repository,
    controller: controller,
    nativeCalls: nativeCalls,
    messenger: messenger,
    methods: methods,
  );
}

final class _Harness {
  const _Harness({
    required this.root,
    required this.database,
    required this.repository,
    required this.controller,
    required this.nativeCalls,
    required this.messenger,
    required this.methods,
  });

  final Directory root;
  final AppDatabase database;
  final SqliteDayFlowRepository repository;
  final AppController controller;
  final List<MethodCall> nativeCalls;
  final TestDefaultBinaryMessenger messenger;
  final MethodChannel methods;

  Future<void> dispose() async {
    controller.dispose();
    await database.close();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('qi_day_flow/test/startup-settings-events'),
      null,
    );
    await root.delete(recursive: true);
  }
}
