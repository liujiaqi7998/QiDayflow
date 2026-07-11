import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';

void main() {
  test('legacy captures directory migrates to its parent data directory', () {
    final settings = AppSettings.fromJson(<String, Object?>{
      'apiUrl': 'https://api.openai.com/v1',
      'apiModel': 'existing-model',
      'captureDirectory': r'D:\Qi Day Flow\captures\',
      'cacheLimitGb': 5,
      'idlePauseEnabled': true,
      'idlePauseSeconds': 600,
      'captureFps': 1,
      'chunkDurationSeconds': 60,
      'themeMode': 'system',
    });

    expect(settings.userDataDirectory, r'D:\Qi Day Flow');
    expect(settings.captureDirectory, r'D:\Qi Day Flow\captures');
  });

  test('log level defaults to info and persists explicit values', () {
    final legacy = AppSettings.fromJson(<String, Object?>{
      'apiUrl': 'https://api.openai.com/v1',
      'apiModel': 'existing-model',
      'userDataDirectory': r'D:\Qi Day Flow',
      'cacheLimitGb': 5,
      'idlePauseEnabled': true,
      'idlePauseSeconds': 600,
      'captureFps': 1,
      'chunkDurationSeconds': 60,
      'themeMode': 'system',
    });

    expect(legacy.logLevel, AppLogLevel.info);
    final restored = AppSettings.fromJson(
      legacy.copyWith(logLevel: AppLogLevel.warning).toJson(),
    );
    expect(restored.logLevel, AppLogLevel.warning);
  });

  test(
    'missing or empty model uses the new default without replacing a saved model',
    () {
      Map<String, Object?> json([String? model]) {
        final value = <String, Object?>{
          'apiUrl': 'https://api.openai.com/v1',
          'userDataDirectory': r'D:\Qi Day Flow',
          'cacheLimitGb': 5,
          'idlePauseEnabled': true,
          'idlePauseSeconds': 600,
          'captureFps': 1,
          'chunkDurationSeconds': 60,
          'themeMode': 'system',
        };
        if (model != null) {
          value['apiModel'] = model;
        }
        return value;
      }

      expect(AppSettings.fromJson(json()).apiModel, 'gpt-5.4-mini');
      expect(AppSettings.fromJson(json('  ')).apiModel, 'gpt-5.4-mini');
      expect(
        AppSettings.fromJson(json('user-selected-model')).apiModel,
        'user-selected-model',
      );
    },
  );
}
