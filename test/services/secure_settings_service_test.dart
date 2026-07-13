import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';

void main() {
  test(
    'legacy capture directory is persisted as a user data directory',
    () async {
      final repository = _MemorySettingsRepository(<String, String>{
        'capture_directory': r'E:\Existing QiDayFlow\captures',
        'api_model': 'existing-model',
      });
      final service = SecureSettingsService(
        repository: repository,
        platform: NativeCaptureService(),
        defaultCaptureDirectory: r'C:\Default QiDayFlow\captures',
      );

      final settings = await service.load();

      expect(settings.userDataDirectory, r'E:\Existing QiDayFlow');
      expect(settings.captureIntervalSeconds, 10);
      final migrated = jsonDecode(repository.values['app_settings']!) as Map;
      expect(migrated['userDataDirectory'], r'E:\Existing QiDayFlow');
      expect(migrated, isNot(contains('captureDirectory')));
    },
  );

  test(
    'legacy model default applies only to missing or blank values',
    () async {
      for (final scenario in <(String?, String)>[
        (null, 'gpt-5.4-mini'),
        ('   ', 'gpt-5.4-mini'),
        ('saved-custom-model', 'saved-custom-model'),
      ]) {
        final repository = _MemorySettingsRepository(<String, String>{
          'capture_directory': r'C:\QiDayFlow\captures',
          if (scenario.$1 != null) 'api_model': scenario.$1!,
        });
        final service = SecureSettingsService(
          repository: repository,
          platform: NativeCaptureService(),
          defaultUserDataDirectory: r'C:\QiDayFlow',
        );

        expect((await service.load()).apiModel, scenario.$2);
      }
    },
  );
}

final class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository(Map<String, String> values)
    : values = Map<String, String>.of(values);

  final Map<String, String> values;

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
    values[key] = value;
  }
}
