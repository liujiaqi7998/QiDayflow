import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';

void main() {
  group('capture interval settings', () {
    Map<String, Object?> settingsJson({
      int? captureIntervalSeconds,
      int? captureFps,
    }) {
      final value = <String, Object?>{
        'apiUrl': 'https://api.openai.com/v1',
        'apiModel': 'existing-model',
        'userDataDirectory': r'D:\Qi Day Flow',
        'cacheLimitGb': 5,
        'idlePauseEnabled': true,
        'idlePauseSeconds': 600,
        'chunkDurationSeconds': 60,
        'themeMode': 'system',
      };
      if (captureIntervalSeconds != null) {
        value['captureIntervalSeconds'] = captureIntervalSeconds;
      }
      if (captureFps != null) value['captureFps'] = captureFps;
      return value;
    }

    test(
      'new settings default to ten seconds and write only the new field',
      () {
        final settings = AppSettings.defaults(
          captureDirectory: r'D:\Qi Day Flow\captures',
        );

        expect(settings.captureIntervalSeconds, 10);
        expect(settings.toJson()['captureIntervalSeconds'], 10);
        expect(settings.toJson(), isNot(contains('captureFps')));

        final constructed = AppSettings(
          apiUrl: 'https://api.openai.com/v1',
          apiModel: 'existing-model',
          userDataDirectory: r'D:\Qi Day Flow',
          cacheLimitGb: 5,
          idlePauseEnabled: true,
          idlePauseSeconds: 600,
          chunkDurationSeconds: 60,
          themeMode: AppThemeMode.system,
        );
        expect(constructed.captureIntervalSeconds, 10);
      },
    );

    test('round-trips each supported capture interval', () {
      for (final interval in const <int>[1, 10, 20, 30]) {
        final settings = AppSettings.fromJson(
          settingsJson(captureIntervalSeconds: interval),
        );

        expect(settings.captureIntervalSeconds, interval);
        expect(
          AppSettings.fromJson(settings.toJson()).captureIntervalSeconds,
          interval,
        );
      }
    });

    test('new field wins while legacy-only settings migrate to one second', () {
      expect(
        AppSettings.fromJson(
          settingsJson(captureIntervalSeconds: 20, captureFps: 9),
        ).captureIntervalSeconds,
        20,
      );
      expect(
        AppSettings.fromJson(
          settingsJson(captureFps: 9),
        ).captureIntervalSeconds,
        1,
      );
      expect(AppSettings.fromJson(settingsJson()).captureIntervalSeconds, 10);
    });

    test('copyWith validates the exact supported intervals', () {
      final settings = AppSettings.defaults(
        captureDirectory: r'D:\Qi Day Flow\captures',
      );

      expect(
        settings.copyWith(captureIntervalSeconds: 30).captureIntervalSeconds,
        30,
      );
      for (final interval in const <int>[0, 2, 9, 11, 31]) {
        expect(
          () => settings.copyWith(captureIntervalSeconds: interval),
          throwsArgumentError,
          reason: '$interval seconds must be rejected',
        );
      }
    });
  });

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

  group('startup settings', () {
    Map<String, Object?> settingsJson() => <String, Object?>{
      'apiUrl': 'https://api.openai.com/v1',
      'apiModel': 'existing-model',
      'userDataDirectory': r'D:\Qi Day Flow',
      'cacheLimitGb': 5,
      'idlePauseEnabled': true,
      'idlePauseSeconds': 600,
      'captureIntervalSeconds': 10,
      'chunkDurationSeconds': 60,
      'themeMode': 'system',
    };

    test('missing startup fields default to false', () {
      final settings = AppSettings.fromJson(settingsJson());

      expect(settings.autoStartRecording, isFalse);
      expect(settings.launchAtLogin, isFalse);
    });

    test('startup fields round-trip and copy independently', () {
      final settings = AppSettings.fromJson(<String, Object?>{
        ...settingsJson(),
        'autoStartRecording': true,
        'launchAtLogin': true,
      });

      expect(settings.autoStartRecording, isTrue);
      expect(settings.launchAtLogin, isTrue);
      expect(
        AppSettings.fromJson(settings.toJson()).autoStartRecording,
        isTrue,
      );
      expect(
        settings.copyWith(autoStartRecording: false).launchAtLogin,
        isTrue,
      );
      expect(
        settings.copyWith(launchAtLogin: false).autoStartRecording,
        isTrue,
      );
    });
  });

  group('analysis retry count', () {
    test('defaults to three retries and migrates missing JSON', () {
      final defaults = AppSettings.defaults(
        captureDirectory: r'D:\Qi Day Flow\captures',
      );
      final legacyJson = Map<String, Object?>.of(defaults.toJson())
        ..remove('analysisRetryCount');

      expect(defaults.analysisRetryCount, 3);
      expect(AppSettings.fromJson(legacyJson).analysisRetryCount, 3);
    });

    test('round-trips and copies every supported retry count', () {
      final defaults = AppSettings.defaults(
        captureDirectory: r'D:\Qi Day Flow\captures',
      );

      for (var count = 0; count <= 5; count++) {
        final settings = defaults.copyWith(analysisRetryCount: count);
        expect(settings.analysisRetryCount, count);
        expect(settings.toJson()['analysisRetryCount'], count);
        expect(
          AppSettings.fromJson(settings.toJson()).analysisRetryCount,
          count,
        );
      }
    });

    test('constructor, copyWith, and fromJson reject out of range values', () {
      final defaults = AppSettings.defaults(
        captureDirectory: r'D:\Qi Day Flow\captures',
      );
      for (final count in <int>[-1, 6]) {
        expect(
          () => AppSettings(
            apiUrl: defaults.apiUrl,
            apiModel: defaults.apiModel,
            userDataDirectory: defaults.userDataDirectory,
            cacheLimitGb: defaults.cacheLimitGb,
            idlePauseEnabled: defaults.idlePauseEnabled,
            idlePauseSeconds: defaults.idlePauseSeconds,
            chunkDurationSeconds: defaults.chunkDurationSeconds,
            themeMode: defaults.themeMode,
            analysisRetryCount: count,
          ),
          throwsRangeError,
        );
        expect(
          () => defaults.copyWith(analysisRetryCount: count),
          throwsRangeError,
        );
        expect(
          () => AppSettings.fromJson(<String, Object?>{
            ...defaults.toJson(),
            'analysisRetryCount': count,
          }),
          throwsRangeError,
        );
      }
    });
  });
}
