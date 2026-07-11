import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/platform/app_paths.dart';
import '../data/local/app_database.dart';

final class DataDirectoryService {
  DataDirectoryService({
    required String locatorDirectory,
    required String defaultUserDataDirectory,
    this.databaseFactory,
  }) : _locatorDirectory = _absoluteWindowsPath(
         locatorDirectory,
         'locatorDirectory',
       ),
       _defaultUserDataDirectory = _absoluteWindowsPath(
         defaultUserDataDirectory,
         'defaultUserDataDirectory',
       );

  static const _locatorVersion = 1;
  static const _locatorStem = '.qi_day_flow_data_location';
  static const _migrationMarkerName = '.qi_day_flow_database_migration.json';

  final String _locatorDirectory;
  final String _defaultUserDataDirectory;
  final DatabaseFactory? databaseFactory;

  Future<AppPaths> resolvePaths() async {
    final stored = await _readLatestState();
    final active = stored?.activeUserDataDirectory ?? _defaultUserDataDirectory;
    final pending = stored?.pendingUserDataDirectory;
    if (pending == null || _samePath(active, pending)) {
      final paths = AppPaths.forUserDataDirectory(active);
      await paths.ensureDirectories();
      return paths;
    }

    await _migrateDatabase(active, pending);
    final applied = _LocatorState(
      generation: (stored?.generation ?? 0) + 1,
      activeUserDataDirectory: pending,
    );
    await _writeState(applied);
    final paths = AppPaths.forUserDataDirectory(pending);
    await paths.ensureDirectories();
    await _deleteMigrationMarker(paths.userDataDirectory);
    return paths;
  }

  Future<void> scheduleChange({
    required String currentUserDataDirectory,
    required String nextUserDataDirectory,
  }) async {
    final current = _absoluteWindowsPath(
      currentUserDataDirectory,
      'currentUserDataDirectory',
    );
    final next = _absoluteWindowsPath(
      nextUserDataDirectory,
      'nextUserDataDirectory',
    );
    final stored = await _readLatestState();
    final active = stored?.activeUserDataDirectory ?? current;
    if (!_samePath(active, current)) {
      throw StateError('当前用户数据目录与启动定位记录不一致，请重启后再试');
    }
    await _writeState(
      _LocatorState(
        generation: (stored?.generation ?? 0) + 1,
        activeUserDataDirectory: active,
        pendingUserDataDirectory: _samePath(active, next) ? null : next,
      ),
    );
  }

  Future<void> _migrateDatabase(String current, String next) async {
    final sourcePaths = AppPaths.forUserDataDirectory(current);
    final targetPaths = AppPaths.forUserDataDirectory(next);
    await targetPaths.ensureDirectories();
    final sourceFile = File(sourcePaths.database);
    final targetFile = File(targetPaths.database);
    final marker = File(
      p.windows.join(targetPaths.userDataDirectory, _migrationMarkerName),
    );
    final markerMatches = await _markerMatches(marker, current, next);

    if (await targetFile.exists()) {
      if (!markerMatches) {
        throw StateError('目标用户数据目录已包含数据库，未执行覆盖');
      }
      return;
    }
    if (!await sourceFile.exists()) {
      if (await marker.exists() && !markerMatches) {
        throw StateError('目标用户数据目录包含其他迁移标记');
      }
      return;
    }

    if (!markerMatches) {
      await marker.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'sourceUserDataDirectory': current,
          'targetUserDataDirectory': next,
        }),
        flush: true,
      );
    }

    final sourceDatabase = AppDatabase(
      path: sourcePaths.database,
      databaseFactory: databaseFactory,
    );
    try {
      await sourceDatabase.open();
    } finally {
      await sourceDatabase.close();
    }

    final temporary = File(
      '${targetPaths.database}.migrating.${pid.toString()}',
    );
    try {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      await sourceFile.copy(temporary.path);
      await temporary.open(mode: FileMode.append).then((file) async {
        try {
          await file.flush();
        } finally {
          await file.close();
        }
      });
      await temporary.rename(targetFile.path);
    } on Object {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  Future<_LocatorState?> _readLatestState() async {
    final states = <_LocatorState>[];
    var foundLocatorFile = false;
    for (var slot = 0; slot < 2; slot++) {
      final file = File(_slotPath(slot));
      if (!await file.exists()) continue;
      foundLocatorFile = true;
      try {
        final decoded = jsonDecode(await file.readAsString());
        states.add(_LocatorState.fromJson(decoded));
      } on Object {
        // The other slot remains a valid recovery point after an interrupted write.
      }
    }
    if (states.isEmpty) {
      if (foundLocatorFile) {
        throw const FormatException('用户数据目录启动定位文件已损坏');
      }
      return null;
    }
    states.sort((left, right) => right.generation.compareTo(left.generation));
    return states.first;
  }

  Future<void> _writeState(_LocatorState state) async {
    await Directory(_locatorDirectory).create(recursive: true);
    final slotPath = _slotPath(state.generation % 2);
    final slot = File(slotPath);
    final temporary = File('$slotPath.tmp.${pid.toString()}');
    try {
      await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
      if (await slot.exists()) {
        await slot.delete();
      }
      await temporary.rename(slotPath);
    } on Object {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  String _slotPath(int slot) =>
      p.windows.join(_locatorDirectory, '$_locatorStem.$slot.json');

  Future<bool> _markerMatches(File marker, String source, String target) async {
    if (!await marker.exists()) return false;
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map<String, Object?> || value['version'] != 1) return false;
      final storedSource = value['sourceUserDataDirectory'];
      final storedTarget = value['targetUserDataDirectory'];
      return storedSource is String &&
          storedTarget is String &&
          _samePath(storedSource, source) &&
          _samePath(storedTarget, target);
    } on Object {
      return false;
    }
  }

  Future<void> _deleteMigrationMarker(String directory) async {
    final marker = File(p.windows.join(directory, _migrationMarkerName));
    if (await marker.exists()) {
      await marker.delete();
    }
  }
}

final class _LocatorState {
  const _LocatorState({
    required this.generation,
    required this.activeUserDataDirectory,
    this.pendingUserDataDirectory,
  });

  factory _LocatorState.fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value['version'] != DataDirectoryService._locatorVersion) {
      throw const FormatException('启动定位文件版本无效');
    }
    final generation = value['generation'];
    final active = value['activeUserDataDirectory'];
    final pending = value['pendingUserDataDirectory'];
    if (generation is! int || generation < 0 || active is! String) {
      throw const FormatException('启动定位文件字段无效');
    }
    return _LocatorState(
      generation: generation,
      activeUserDataDirectory: _absoluteWindowsPath(active, 'active'),
      pendingUserDataDirectory: pending == null
          ? null
          : _absoluteWindowsPath(pending as String, 'pending'),
    );
  }

  final int generation;
  final String activeUserDataDirectory;
  final String? pendingUserDataDirectory;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': DataDirectoryService._locatorVersion,
    'generation': generation,
    'activeUserDataDirectory': activeUserDataDirectory,
    'pendingUserDataDirectory': pendingUserDataDirectory,
  };
}

String _absoluteWindowsPath(String value, String name) {
  final normalized = p.windows.normalize(value.trim());
  if (normalized.isEmpty || !p.windows.isAbsolute(normalized)) {
    throw ArgumentError.value(value, name, '必须是绝对 Windows 路径');
  }
  return normalized;
}

bool _samePath(String left, String right) =>
    p.windows.normalize(left).toLowerCase() ==
    p.windows.normalize(right).toLowerCase();
