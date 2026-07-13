import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/openai/analysis_models.dart';
import 'package:qi_day_flow/services/openai/chat_transport.dart';
import 'package:qi_day_flow/services/openai/openai_analysis_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('settings saves are serialized and the newest draft wins', () async {
    final root = await Directory.systemTemp.createTemp(
      'qi_day_flow_settings_queue_',
    );
    final database = AppDatabase(
      path: p.join(root.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    final settingsRepository = _DelayedSettingsRepository(
      AppSettings(
        apiUrl: 'https://api.openai.com/v1',
        apiModel: 'initial-model',
        userDataDirectory: root.path,
        cacheLimitGb: 5,
        idlePauseEnabled: true,
        idlePauseSeconds: 600,
        captureIntervalSeconds: 10,
        chunkDurationSeconds: 60,
        themeMode: AppThemeMode.system,
      ),
    );
    const methods = MethodChannel('qi_day_flow/test/settings-queue-methods');
    const events = EventChannel('qi_day_flow/test/settings-queue-events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('qi_day_flow/test/settings-queue-events'),
      (_) async => null,
    );
    final native = NativeCaptureService(
      methodChannel: methods,
      eventChannel: events,
    );
    OpenAiAnalysisConfig? testedConnectionConfig;
    final controller = AppController(
      database: database,
      repository: repository,
      nativeService: native,
      settingsService: SecureSettingsService(
        repository: settingsRepository,
        platform: native,
        defaultUserDataDirectory: root.path,
      ),
      activeUserDataDirectory: root.path,
      analysisServiceBuilder: (config) {
        testedConnectionConfig = config;
        return OpenAiAnalysisService(
          config: config,
          transport: _SuccessfulConnectionTransport(),
        );
      },
    );
    addTearDown(() async {
      controller.dispose();
      await database.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('qi_day_flow/test/settings-queue-events'),
        null,
      );
      await root.delete(recursive: true);
    });
    await controller.initialize();

    final first = controller.saveSettings(_draft(controller, 'older-model'));
    await _waitFor(() => settingsRepository.pendingWrites.length == 1);
    final second = controller.saveSettings(
      _draft(controller, 'newest-model', analysisRetryCount: 5),
    );
    await Future<void>.delayed(Duration.zero);

    expect(settingsRepository.pendingWrites, hasLength(1));
    expect(controller.settingsSaveStatus, SettingsSaveStatus.saving);
    settingsRepository.pendingWrites.first.gate.complete();
    await first;
    await _waitFor(() => settingsRepository.pendingWrites.length == 2);
    expect(controller.settingsSaveStatus, SettingsSaveStatus.saving);
    settingsRepository.pendingWrites.last.gate.complete();
    await second;

    expect(controller.settingsSaveStatus, SettingsSaveStatus.saved);
    expect(controller.settings.model, 'newest-model');
    final stored = AppSettings.fromJson(
      jsonDecode(settingsRepository.values['app_settings']!),
    );
    expect(stored.apiModel, 'newest-model');
    expect(stored.captureIntervalSeconds, 10);
    expect(stored.analysisRetryCount, 5);
    expect(controller.settings.analysisRetryCount, 5);

    await controller.testApiConnection(
      _draft(
        controller,
        'connection-model',
        apiKey: 'temporary-key',
        analysisRetryCount: 5,
      ),
    );
    expect(testedConnectionConfig?.maxAttempts, 6);

    final failed = controller.saveSettings(_draft(controller, 'failed-model'));
    await _waitFor(() => settingsRepository.pendingWrites.length == 3);
    settingsRepository.pendingWrites.last.gate.completeError(
      StateError('test-key-placeholder'),
    );
    await expectLater(failed, throwsStateError);
    expect(controller.settingsSaveStatus, SettingsSaveStatus.error);
    expect(controller.settingsSaveError, contains('设置保存失败'));
    expect(
      controller.settingsSaveError,
      isNot(contains('test-key-placeholder')),
    );
  });
}

SettingsDraft _draft(
  AppController controller,
  String model, {
  String apiKey = '',
  int? analysisRetryCount,
}) => SettingsDraft(
  apiUrl: controller.settings.apiUrl,
  apiKey: apiKey,
  apiKeyChanged: apiKey.isNotEmpty,
  model: model,
  userDataDirectory: controller.settings.userDataDirectory,
  cacheLimitGb: controller.settings.cacheLimitGb,
  idlePauseEnabled: controller.settings.idlePauseEnabled,
  idleTimeoutMinutes: controller.settings.idleTimeoutMinutes,
  captureIntervalSeconds: controller.settings.captureIntervalSeconds,
  themeMode: ThemeMode.system,
  logLevel: controller.settings.logLevel,
  analysisRetryCount:
      analysisRetryCount ?? controller.settings.analysisRetryCount,
);

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the settings persistence seam');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _DelayedSettingsRepository implements SettingsRepository {
  _DelayedSettingsRepository(AppSettings initial)
    : values = <String, String>{'app_settings': jsonEncode(initial.toJson())};

  final Map<String, String> values;
  final List<_PendingWrite> pendingWrites = <_PendingWrite>[];

  @override
  Future<bool> deleteSetting(String key) async => values.remove(key) != null;

  @override
  Future<SettingRecord?> getSetting(String key) async {
    final value = values[key];
    return value == null
        ? null
        : SettingRecord(key: key, value: value, updatedAtMs: 1);
  }

  @override
  Future<List<SettingRecord>> listSettings() async => values.entries
      .map(
        (entry) =>
            SettingRecord(key: entry.key, value: entry.value, updatedAtMs: 1),
      )
      .toList(growable: false);

  @override
  Future<void> putSetting(String key, String value) async {
    if (key != 'app_settings') {
      values[key] = value;
      return;
    }
    final pending = _PendingWrite(value);
    pendingWrites.add(pending);
    await pending.gate.future;
    values[key] = value;
  }
}

final class _SuccessfulConnectionTransport implements ChatTransport {
  @override
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async => <String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{'content': '{"ok":true}'},
      },
    ],
  };

  @override
  void close() {}
}

final class _PendingWrite {
  _PendingWrite(this.value);

  final String value;
  final Completer<void> gate = Completer<void>();
}
