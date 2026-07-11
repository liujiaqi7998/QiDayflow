import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/services/logging/managed_log_service.dart';

void main() {
  test(
    'counts only managed current logs and positive-number rotations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_managed_logs_',
      );
      addTearDown(() => root.delete(recursive: true));
      final logs = Directory(p.windows.join(root.path, 'logs'));
      await logs.create();

      await _writeBytes(logs.path, 'qi_day_flow.log', 3);
      await _writeBytes(logs.path, 'qi_day_flow.log.1', 5);
      await _writeBytes(logs.path, 'native-capture.log', 7);
      await _writeBytes(logs.path, 'native-capture.log.12', 11);
      await _writeBytes(logs.path, 'other.log', 13);
      await _writeBytes(logs.path, 'qi_day_flow.log.old', 17);
      await _writeBytes(logs.path, 'qi_day_flow.log.0', 19);
      await _writeBytes(logs.path, 'native-capture.log.01', 23);
      final nested = Directory(p.windows.join(logs.path, 'nested'));
      await nested.create();
      await _writeBytes(nested.path, 'qi_day_flow.log', 29);

      final snapshot = await ManagedLogService(
        activeUserDataDirectory: root.path,
      ).inspect();

      expect(snapshot.totalBytes, 26);
      expect(snapshot.managedFileCount, 4);
      expect(snapshot.issues, isEmpty);
    },
  );

  test(
    'clear removes only managed logs and keeps directories and data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_managed_logs_',
      );
      addTearDown(() => root.delete(recursive: true));
      final logs = Directory(p.windows.join(root.path, 'logs'));
      final captures = Directory(p.windows.join(root.path, 'captures'));
      await logs.create();
      await captures.create();
      final database = File(p.windows.join(root.path, 'qi_day_flow.db'));
      final capture = File(p.windows.join(captures.path, 'chunk.mp4'));
      final unknown = await _writeBytes(logs.path, 'keep-me.txt', 13);
      final nonRotation = await _writeBytes(
        logs.path,
        'qi_day_flow.log.backup',
        17,
      );
      await database.writeAsBytes(<int>[1]);
      await capture.writeAsBytes(<int>[2]);
      final managed = <File>[
        await _writeBytes(logs.path, 'qi_day_flow.log', 3),
        await _writeBytes(logs.path, 'qi_day_flow.log.2', 5),
        await _writeBytes(logs.path, 'native-capture.log', 7),
        await _writeBytes(logs.path, 'native-capture.log.3', 11),
      ];

      final result = await ManagedLogService(
        activeUserDataDirectory: root.path,
      ).clear();

      expect(result.deletedFileNames, hasLength(4));
      expect(result.issues, isEmpty);
      for (final file in managed) {
        expect(await file.exists(), isFalse);
      }
      expect(await unknown.exists(), isTrue);
      expect(await nonRotation.exists(), isTrue);
      expect(await logs.exists(), isTrue);
      expect(await root.exists(), isTrue);
      expect(await database.exists(), isTrue);
      expect(await capture.exists(), isTrue);
    },
  );

  test(
    'clear reports a partial delete failure and keeps the failed file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_managed_logs_',
      );
      addTearDown(() => root.delete(recursive: true));
      final logs = Directory(p.windows.join(root.path, 'logs'));
      await logs.create();
      final deleted = await _writeBytes(logs.path, 'qi_day_flow.log', 3);
      final failed = await _writeBytes(logs.path, 'native-capture.log.1', 5);
      final fileSystem = _OverrideFileSystem(
        deleteFailures: <String>{failed.path},
      );

      final result = await ManagedLogService(
        activeUserDataDirectory: root.path,
        fileSystem: fileSystem,
      ).clear();

      expect(result.deletedFileNames, <String>['qi_day_flow.log']);
      expect(
        result.issues,
        contains(
          isA<ManagedLogIssue>()
              .having(
                (issue) => issue.fileName,
                'fileName',
                'native-capture.log.1',
              )
              .having(
                (issue) => issue.kind,
                'kind',
                ManagedLogIssueKind.deletionFailed,
              ),
        ),
      );
      expect(await deleted.exists(), isFalse);
      expect(await failed.exists(), isTrue);
      expect(result.succeeded, isFalse);
    },
  );

  test(
    'link and resolved-outside managed candidates are skipped safely',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_managed_logs_',
      );
      addTearDown(() => root.delete(recursive: true));
      final logs = Directory(p.windows.join(root.path, 'logs'));
      await logs.create();
      final outsideCandidate = await _writeBytes(
        logs.path,
        'qi_day_flow.log',
        3,
      );
      final linkCandidate = await _writeBytes(
        logs.path,
        'native-capture.log',
        5,
      );
      final fileSystem = _OverrideFileSystem(
        typeOverrides: <String, FileSystemEntityType>{
          linkCandidate.path: FileSystemEntityType.link,
        },
        resolvedFileOverrides: <String, String>{
          outsideCandidate.path: p.windows.join(
            p.windows.dirname(root.path),
            'outside.log',
          ),
        },
      );
      final service = ManagedLogService(
        activeUserDataDirectory: root.path,
        fileSystem: fileSystem,
      );

      final snapshot = await service.inspect();
      final result = await service.clear();

      expect(snapshot.totalBytes, 0);
      expect(snapshot.managedFileCount, 0);
      expect(
        snapshot.issues.map((issue) => issue.kind),
        containsAll(<ManagedLogIssueKind>[
          ManagedLogIssueKind.unsafePath,
          ManagedLogIssueKind.notRegularFile,
        ]),
      );
      expect(result.deletedFileNames, isEmpty);
      expect(result.succeeded, isFalse);
      expect(await outsideCandidate.exists(), isTrue);
      expect(await linkCandidate.exists(), isTrue);
    },
  );

  test(
    'a logs directory reparse target outside active data is rejected',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_managed_logs_',
      );
      addTearDown(() => root.delete(recursive: true));
      final logs = Directory(p.windows.join(root.path, 'logs'));
      await logs.create();
      final managed = await _writeBytes(logs.path, 'qi_day_flow.log', 3);
      final fileSystem = _OverrideFileSystem(
        resolvedDirectoryOverrides: <String, String>{
          logs.path: p.windows.join(
            p.windows.dirname(root.path),
            'outside-logs',
          ),
        },
      );
      final service = ManagedLogService(
        activeUserDataDirectory: root.path,
        fileSystem: fileSystem,
      );

      final snapshot = await service.inspect();
      final result = await service.clear();

      expect(snapshot.totalBytes, 0);
      expect(snapshot.issues.single.kind, ManagedLogIssueKind.unsafePath);
      expect(result.deletedFileNames, isEmpty);
      expect(result.issues.single.kind, ManagedLogIssueKind.unsafePath);
      expect(await managed.exists(), isTrue);
      expect(await logs.exists(), isTrue);
    },
  );
}

Future<File> _writeBytes(String directory, String name, int count) async {
  final file = File(p.windows.join(directory, name));
  await file.writeAsBytes(List<int>.filled(count, 1));
  return file;
}

final class _OverrideFileSystem implements ManagedLogFileSystem {
  _OverrideFileSystem({
    Map<String, FileSystemEntityType> typeOverrides = const {},
    Map<String, String> resolvedFileOverrides = const {},
    Map<String, String> resolvedDirectoryOverrides = const {},
    Set<String> deleteFailures = const {},
  }) : _typeOverrides = _normalizedMap(typeOverrides),
       _resolvedFileOverrides = _normalizedMap(resolvedFileOverrides),
       _resolvedDirectoryOverrides = _normalizedMap(resolvedDirectoryOverrides),
       _deleteFailures = deleteFailures.map(_key).toSet();

  final ManagedLogFileSystem _delegate = const LocalManagedLogFileSystem();
  final Map<String, FileSystemEntityType> _typeOverrides;
  final Map<String, String> _resolvedFileOverrides;
  final Map<String, String> _resolvedDirectoryOverrides;
  final Set<String> _deleteFailures;

  @override
  Future<void> deleteFile(String path) {
    if (_deleteFailures.contains(_key(path))) {
      throw FileSystemException('injected delete failure');
    }
    return _delegate.deleteFile(path);
  }

  @override
  Future<FileSystemEntityType> entityTypeNoFollow(String path) async =>
      _typeOverrides[_key(path)] ?? _delegate.entityTypeNoFollow(path);

  @override
  Future<int> fileLength(String path) => _delegate.fileLength(path);

  @override
  Future<List<String>> listChildren(String directory) =>
      _delegate.listChildren(directory);

  @override
  Future<String> resolveDirectory(String path) async =>
      _resolvedDirectoryOverrides[_key(path)] ??
      _delegate.resolveDirectory(path);

  @override
  Future<String> resolveFile(String path) async =>
      _resolvedFileOverrides[_key(path)] ?? _delegate.resolveFile(path);
}

Map<String, T> _normalizedMap<T>(Map<String, T> values) =>
    values.map((key, value) => MapEntry(_key(key), value));

String _key(String value) => p.windows.normalize(value).toLowerCase();
