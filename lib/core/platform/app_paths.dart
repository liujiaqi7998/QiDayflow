import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths._(this.userDataDirectory)
    : database = p.windows.join(userDataDirectory, 'qi_day_flow.db'),
      logsDirectory = p.windows.join(userDataDirectory, 'logs'),
      captureDirectory = p.windows.join(userDataDirectory, 'captures');

  factory AppPaths.forUserDataDirectory(String value) {
    final normalized = p.windows.normalize(value.trim());
    if (normalized.isEmpty || !p.windows.isAbsolute(normalized)) {
      throw ArgumentError.value(value, 'value', '必须是绝对 Windows 路径');
    }
    return AppPaths._(normalized);
  }

  final String userDataDirectory;
  final String database;
  final String logsDirectory;
  final String captureDirectory;

  String get root => userDataDirectory;

  String get defaultCaptureDirectory => captureDirectory;

  static Future<AppPaths> create() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Qi Day Flow 仅支持 Windows');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      throw StateError('无法定位 Windows LOCALAPPDATA 目录');
    }
    final paths = AppPaths.forUserDataDirectory(
      p.windows.join(localAppData, 'QiDayFlow'),
    );
    await paths.ensureDirectories();
    return paths;
  }

  Future<void> ensureDirectories() async {
    await Future.wait(<Future<Directory>>[
      Directory(userDataDirectory).create(recursive: true),
      Directory(captureDirectory).create(recursive: true),
      Directory(logsDirectory).create(recursive: true),
    ]);
  }
}
