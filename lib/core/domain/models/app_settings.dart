import '../validation.dart';
import 'package:path/path.dart' as p;

enum AppThemeMode { system, light, dark }

enum AppLogLevel { debug, info, warning, error }

final class AppSettings {
  static const String defaultApiModel = 'gpt-5.4-mini';
  static const Set<int> supportedCaptureIntervalSeconds = <int>{1, 10, 20, 30};

  AppSettings({
    required String apiUrl,
    required String apiModel,
    this.apiKeyCiphertext,
    String? userDataDirectory,
    String? captureDirectory,
    required this.cacheLimitGb,
    required this.idlePauseEnabled,
    required this.idlePauseSeconds,
    this.captureIntervalSeconds = 10,
    required this.chunkDurationSeconds,
    required this.themeMode,
    this.logLevel = AppLogLevel.info,
    this.autoStartRecording = false,
    this.launchAtLogin = false,
  }) : apiUrl = requireNonBlank(apiUrl, 'apiUrl'),
       apiModel = requireNonBlank(apiModel, 'apiModel'),
       userDataDirectory = _resolveUserDataDirectory(
         userDataDirectory: userDataDirectory,
         legacyCaptureDirectory: captureDirectory,
       ) {
    final uri = Uri.tryParse(this.apiUrl);
    final isLoopback =
        uri != null &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && isLoopback))) {
      throw FormatException('apiUrl 必须使用 HTTPS，本机回环地址可使用 HTTP');
    }
    if (cacheLimitGb < 1 || cacheLimitGb > 50) {
      throw RangeError.range(cacheLimitGb, 1, 50, 'cacheLimitGb');
    }
    if (idlePauseSeconds < 60 || idlePauseSeconds > 3600) {
      throw RangeError.range(idlePauseSeconds, 60, 3600, 'idlePauseSeconds');
    }
    if (!supportedCaptureIntervalSeconds.contains(captureIntervalSeconds)) {
      throw ArgumentError.value(
        captureIntervalSeconds,
        'captureIntervalSeconds',
        'must be one of 1, 10, 20, or 30',
      );
    }
    if (chunkDurationSeconds < 10 || chunkDurationSeconds > 3600) {
      throw RangeError.range(
        chunkDurationSeconds,
        10,
        3600,
        'chunkDurationSeconds',
      );
    }
  }

  factory AppSettings.fromJson(Object? value) {
    const keys = <String>{
      'apiUrl',
      'apiModel',
      'apiKeyCiphertext',
      'displayId',
      'userDataDirectory',
      'captureDirectory',
      'cacheLimitGb',
      'idlePauseEnabled',
      'idlePauseSeconds',
      'captureIntervalSeconds',
      'captureFps',
      'chunkDurationSeconds',
      'themeMode',
      'logLevel',
      'autoStartRecording',
      'launchAtLogin',
    };
    final json = strictJsonObject(value, 'settings', allowedKeys: keys);
    return AppSettings(
      apiUrl: jsonString(json, 'apiUrl'),
      apiModel: _apiModelFromJson(json),
      apiKeyCiphertext: jsonOptionalString(json, 'apiKeyCiphertext'),
      userDataDirectory: json.containsKey('userDataDirectory')
          ? jsonString(json, 'userDataDirectory')
          : null,
      captureDirectory: json.containsKey('captureDirectory')
          ? jsonString(json, 'captureDirectory')
          : null,
      cacheLimitGb: jsonInt(json, 'cacheLimitGb'),
      idlePauseEnabled: jsonBool(json, 'idlePauseEnabled'),
      idlePauseSeconds: jsonInt(json, 'idlePauseSeconds'),
      captureIntervalSeconds: _captureIntervalSecondsFromJson(json),
      chunkDurationSeconds: jsonInt(json, 'chunkDurationSeconds'),
      themeMode: AppThemeMode.values.byName(jsonString(json, 'themeMode')),
      logLevel: json.containsKey('logLevel')
          ? AppLogLevel.values.byName(jsonString(json, 'logLevel'))
          : AppLogLevel.info,
      autoStartRecording: json.containsKey('autoStartRecording')
          ? jsonBool(json, 'autoStartRecording')
          : false,
      launchAtLogin: json.containsKey('launchAtLogin')
          ? jsonBool(json, 'launchAtLogin')
          : false,
    );
  }

  factory AppSettings.defaults({required String captureDirectory}) =>
      AppSettings(
        apiUrl: 'https://api.openai.com/v1',
        apiModel: defaultApiModel,
        captureDirectory: captureDirectory,
        cacheLimitGb: 5,
        idlePauseEnabled: true,
        idlePauseSeconds: 600,
        captureIntervalSeconds: 10,
        chunkDurationSeconds: 60,
        themeMode: AppThemeMode.system,
        logLevel: AppLogLevel.info,
      );

  final String apiUrl;
  final String apiModel;
  final String? apiKeyCiphertext;
  final String userDataDirectory;
  final int cacheLimitGb;
  final bool idlePauseEnabled;
  final int idlePauseSeconds;
  final int captureIntervalSeconds;
  final int chunkDurationSeconds;
  final AppThemeMode themeMode;
  final AppLogLevel logLevel;
  final bool autoStartRecording;
  final bool launchAtLogin;

  bool get apiKeyConfigured => apiKeyCiphertext?.isNotEmpty ?? false;

  String get captureDirectory => p.windows.join(userDataDirectory, 'captures');

  Map<String, Object?> toJson() => <String, Object?>{
    'apiUrl': apiUrl,
    'apiModel': apiModel,
    'apiKeyCiphertext': apiKeyCiphertext,
    'userDataDirectory': userDataDirectory,
    'cacheLimitGb': cacheLimitGb,
    'idlePauseEnabled': idlePauseEnabled,
    'idlePauseSeconds': idlePauseSeconds,
    'captureIntervalSeconds': captureIntervalSeconds,
    'chunkDurationSeconds': chunkDurationSeconds,
    'themeMode': themeMode.name,
    'logLevel': logLevel.name,
    'autoStartRecording': autoStartRecording,
    'launchAtLogin': launchAtLogin,
  };

  AppSettings copyWith({
    String? apiUrl,
    String? apiModel,
    String? apiKeyCiphertext,
    bool clearApiKey = false,
    String? userDataDirectory,
    String? captureDirectory,
    int? cacheLimitGb,
    bool? idlePauseEnabled,
    int? idlePauseSeconds,
    int? captureIntervalSeconds,
    int? chunkDurationSeconds,
    AppThemeMode? themeMode,
    AppLogLevel? logLevel,
    bool? autoStartRecording,
    bool? launchAtLogin,
  }) => AppSettings(
    apiUrl: apiUrl ?? this.apiUrl,
    apiModel: apiModel ?? this.apiModel,
    apiKeyCiphertext: clearApiKey
        ? null
        : (apiKeyCiphertext ?? this.apiKeyCiphertext),
    userDataDirectory:
        userDataDirectory ??
        (captureDirectory == null
            ? this.userDataDirectory
            : _dataDirectoryFromLegacyCapture(captureDirectory)),
    cacheLimitGb: cacheLimitGb ?? this.cacheLimitGb,
    idlePauseEnabled: idlePauseEnabled ?? this.idlePauseEnabled,
    idlePauseSeconds: idlePauseSeconds ?? this.idlePauseSeconds,
    captureIntervalSeconds:
        captureIntervalSeconds ?? this.captureIntervalSeconds,
    chunkDurationSeconds: chunkDurationSeconds ?? this.chunkDurationSeconds,
    themeMode: themeMode ?? this.themeMode,
    logLevel: logLevel ?? this.logLevel,
    autoStartRecording: autoStartRecording ?? this.autoStartRecording,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
  );
}

int _captureIntervalSecondsFromJson(Map<String, Object?> json) {
  if (json.containsKey('captureIntervalSeconds')) {
    return jsonInt(json, 'captureIntervalSeconds');
  }
  if (json.containsKey('captureFps')) {
    jsonInt(json, 'captureFps');
    return 1;
  }
  return 10;
}

String _apiModelFromJson(Map<String, Object?> json) {
  final value = json['apiModel'];
  if (value == null) return AppSettings.defaultApiModel;
  if (value is! String) {
    throw const FormatException('apiModel 必须是字符串');
  }
  final normalized = value.trim();
  return normalized.isEmpty ? AppSettings.defaultApiModel : normalized;
}

String _resolveUserDataDirectory({
  String? userDataDirectory,
  String? legacyCaptureDirectory,
}) {
  if (userDataDirectory != null) {
    return p.windows.normalize(
      requireNonBlank(userDataDirectory, 'userDataDirectory'),
    );
  }
  if (legacyCaptureDirectory != null) {
    return _dataDirectoryFromLegacyCapture(legacyCaptureDirectory);
  }
  throw const FormatException('settings 缺少 userDataDirectory');
}

String _dataDirectoryFromLegacyCapture(String value) {
  final normalized = p.windows.normalize(
    requireNonBlank(value, 'captureDirectory'),
  );
  if (p.windows.basename(normalized).toLowerCase() == 'captures') {
    return p.windows.dirname(normalized);
  }
  return normalized;
}
