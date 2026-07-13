// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import '../core/domain/domain.dart';
import 'native/native_capture_service.dart';

final class SecureSettingsService {
  SecureSettingsService({
    required SettingsRepository repository,
    required NativeCaptureService platform,
    String? defaultUserDataDirectory,
    String? defaultCaptureDirectory,
  }) : _repository = repository,
       _platform = platform,
       _defaultUserDataDirectory = _resolveDefaultUserDataDirectory(
         defaultUserDataDirectory: defaultUserDataDirectory,
         defaultCaptureDirectory: defaultCaptureDirectory,
       );

  static const _settingsKey = 'app_settings';
  static const _dailyGoalHoursKey = 'daily_goal_hours';

  final SettingsRepository _repository;
  final NativeCaptureService _platform;
  final String _defaultUserDataDirectory;

  Future<AppSettings> load() async {
    final stored = await _repository.getSetting(_settingsKey);
    if (stored != null && stored.value.isNotEmpty) {
      final decoded = jsonDecode(stored.value);
      final settings = AppSettings.fromJson(decoded);
      if (decoded is Map<String, Object?> &&
          (!decoded.containsKey('userDataDirectory') ||
              decoded.containsKey('captureDirectory') ||
              decoded.containsKey('captureFps') ||
              !decoded.containsKey('captureIntervalSeconds') ||
              !decoded.containsKey('logLevel') ||
              !decoded.containsKey('autoStartRecording') ||
              !decoded.containsKey('launchAtLogin') ||
              !decoded.containsKey('analysisRetryCount') ||
              _nonEmpty(decoded['apiModel'] as String?) == null)) {
        await _repository.putSetting(
          _settingsKey,
          jsonEncode(settings.toJson()),
        );
      }
      return settings;
    }

    // Import settings written by pre-MVP development builds once.
    final records = await _repository.listSettings();
    final values = <String, String>{
      for (final item in records) item.key: item.value,
    };
    final settings = AppSettings(
      apiUrl: values['api_url'] ?? 'https://api.openai.com/v1',
      apiModel: _nonEmpty(values['api_model']) ?? AppSettings.defaultApiModel,
      apiKeyCiphertext: _nonEmpty(values['api_key_ciphertext']),
      userDataDirectory: _nonEmpty(values['user_data_directory']),
      captureDirectory:
          _nonEmpty(values['capture_directory']) ?? _defaultUserDataDirectory,
      cacheLimitGb: _storedInt(values['cache_limit_gb'], 5),
      idlePauseEnabled: _storedBool(values['idle_pause_enabled'], true),
      idlePauseSeconds: _storedInt(values['idle_pause_seconds'], 600),
      captureIntervalSeconds: 10,
      chunkDurationSeconds: _storedInt(values['chunk_duration_seconds'], 60),
      themeMode: _storedTheme(values['theme_mode']),
      logLevel: _storedLogLevel(values['log_level']),
    );
    await _repository.putSetting(_settingsKey, jsonEncode(settings.toJson()));
    return settings;
  }

  Future<AppSettings> save(
    AppSettings settings, {
    String? plaintextApiKey,
  }) async {
    var result = settings;
    final apiKey = plaintextApiKey?.trim();
    if (apiKey != null && apiKey.isNotEmpty) {
      final ciphertext = await _platform.protectText(apiKey);
      result = settings.copyWith(apiKeyCiphertext: ciphertext);
    }
    await _repository.putSetting(_settingsKey, jsonEncode(result.toJson()));
    return result;
  }

  Future<String> readApiKey({AppSettings? settings}) async {
    final value = settings ?? await load();
    final ciphertext = value.apiKeyCiphertext;
    if (ciphertext == null || ciphertext.isEmpty) {
      throw StateError('尚未配置 API key');
    }
    return _platform.unprotectText(ciphertext);
  }

  Future<int> loadDailyGoalHours() async {
    final record = await _repository.getSetting(_dailyGoalHoursKey);
    final value = int.tryParse(record?.value ?? '');
    return value != null && value >= 1 && value <= 16 ? value : 8;
  }

  Future<void> saveDailyGoalHours(int hours) {
    if (hours < 1 || hours > 16) {
      throw RangeError.range(hours, 1, 16, 'hours');
    }
    return _repository.putSetting(_dailyGoalHoursKey, hours.toString());
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static int _storedInt(String? value, int fallback) {
    if (value == null) return fallback;
    return int.tryParse(value) ?? (throw FormatException('设置不是合法整数: $value'));
  }

  static bool _storedBool(String? value, bool fallback) {
    if (value == null) return fallback;
    return switch (value) {
      'true' => true,
      'false' => false,
      _ => throw FormatException('设置不是合法布尔值: $value'),
    };
  }

  static AppThemeMode _storedTheme(String? value) {
    if (value == null) return AppThemeMode.system;
    return AppThemeMode.values.firstWhere(
      (item) => item.name == value,
      orElse: () => throw FormatException('未知主题模式: $value'),
    );
  }

  static AppLogLevel _storedLogLevel(String? value) {
    if (value == null || value.trim().isEmpty) return AppLogLevel.info;
    return AppLogLevel.values.firstWhere(
      (item) => item.name == value.trim().toLowerCase(),
      orElse: () => throw FormatException('未知日志等级: $value'),
    );
  }

  static String _resolveDefaultUserDataDirectory({
    String? defaultUserDataDirectory,
    String? defaultCaptureDirectory,
  }) {
    if (defaultUserDataDirectory != null) {
      return AppSettings.defaults(
        captureDirectory: defaultUserDataDirectory,
      ).copyWith(userDataDirectory: defaultUserDataDirectory).userDataDirectory;
    }
    if (defaultCaptureDirectory != null) {
      return AppSettings.defaults(
        captureDirectory: defaultCaptureDirectory,
      ).userDataDirectory;
    }
    throw ArgumentError(
      '必须提供 defaultUserDataDirectory 或 defaultCaptureDirectory',
    );
  }
}
