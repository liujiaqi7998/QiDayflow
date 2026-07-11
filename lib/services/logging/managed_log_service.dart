import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

enum ManagedLogIssueKind {
  inaccessible,
  unsafePath,
  notRegularFile,
  deletionFailed,
}

final class ManagedLogIssue {
  const ManagedLogIssue({required this.fileName, required this.kind});

  final String fileName;
  final ManagedLogIssueKind kind;

  String get message => switch (kind) {
    ManagedLogIssueKind.inaccessible => '$fileName 无法访问',
    ManagedLogIssueKind.unsafePath => '$fileName 路径未通过安全校验',
    ManagedLogIssueKind.notRegularFile => '$fileName 不是普通文件',
    ManagedLogIssueKind.deletionFailed => '$fileName 删除失败',
  };
}

final class ManagedLogSnapshot {
  ManagedLogSnapshot({
    required this.totalBytes,
    required this.managedFileCount,
    required List<ManagedLogIssue> issues,
  }) : issues = List<ManagedLogIssue>.unmodifiable(issues);

  final int totalBytes;
  final int managedFileCount;
  final List<ManagedLogIssue> issues;

  bool get complete => issues.isEmpty;
}

final class ManagedLogClearResult {
  ManagedLogClearResult({
    required List<String> deletedFileNames,
    required List<ManagedLogIssue> issues,
  }) : deletedFileNames = List<String>.unmodifiable(deletedFileNames),
       issues = List<ManagedLogIssue>.unmodifiable(issues);

  final List<String> deletedFileNames;
  final List<ManagedLogIssue> issues;

  bool get succeeded => issues.isEmpty;
}

abstract interface class ManagedLogFileSystem {
  Future<FileSystemEntityType> entityTypeNoFollow(String path);

  Future<List<String>> listChildren(String directory);

  Future<String> resolveDirectory(String path);

  Future<String> resolveFile(String path);

  Future<int> fileLength(String path);

  Future<void> deleteFile(String path);
}

final class LocalManagedLogFileSystem implements ManagedLogFileSystem {
  const LocalManagedLogFileSystem();

  @override
  Future<void> deleteFile(String path) => File(path).delete();

  @override
  Future<FileSystemEntityType> entityTypeNoFollow(String path) =>
      FileSystemEntity.type(path, followLinks: false);

  @override
  Future<int> fileLength(String path) => File(path).length();

  @override
  Future<List<String>> listChildren(String directory) async {
    final children = <String>[];
    await for (final entity in Directory(directory).list(followLinks: false)) {
      children.add(entity.path);
    }
    return children;
  }

  @override
  Future<String> resolveDirectory(String path) =>
      Directory(path).resolveSymbolicLinks();

  @override
  Future<String> resolveFile(String path) => File(path).resolveSymbolicLinks();
}

final class ManagedLogService {
  factory ManagedLogService({
    required String activeUserDataDirectory,
    ManagedLogFileSystem fileSystem = const LocalManagedLogFileSystem(),
  }) => ManagedLogService._(activeUserDataDirectory, fileSystem);

  ManagedLogService._(String activeUserDataDirectory, this._fileSystem)
    : _activeUserDataDirectory = _absoluteWindowsPath(activeUserDataDirectory);

  static final RegExp _managedFileName = RegExp(
    r'^(?:qi_day_flow|native-capture)\.log(?:\.[1-9][0-9]*)?$',
    caseSensitive: false,
  );

  final String _activeUserDataDirectory;
  final ManagedLogFileSystem _fileSystem;
  Future<void> _tail = Future<void>.value();

  String get logsDirectory => p.windows.join(_activeUserDataDirectory, 'logs');

  Future<ManagedLogSnapshot> inspect() => _serialize(_inspect);

  Future<int> sizeBytes() async => (await inspect()).totalBytes;

  Future<ManagedLogClearResult> clear() => _serialize(_clear);

  Future<ManagedLogSnapshot> _inspect() async {
    final prepared = await _prepareDirectory();
    if (prepared.directory == null) {
      return ManagedLogSnapshot(
        totalBytes: 0,
        managedFileCount: 0,
        issues: prepared.issues,
      );
    }
    final scan = await _scanCandidates(prepared.directory!);
    var totalBytes = 0;
    var managedFileCount = 0;
    final issues = <ManagedLogIssue>[...prepared.issues, ...scan.issues];
    for (final candidate in scan.candidates) {
      try {
        totalBytes += await _fileSystem.fileLength(candidate.path);
        managedFileCount++;
      } on Object {
        issues.add(
          ManagedLogIssue(
            fileName: candidate.fileName,
            kind: ManagedLogIssueKind.inaccessible,
          ),
        );
      }
    }
    return ManagedLogSnapshot(
      totalBytes: totalBytes,
      managedFileCount: managedFileCount,
      issues: issues,
    );
  }

  Future<ManagedLogClearResult> _clear() async {
    final prepared = await _prepareDirectory();
    if (prepared.directory == null) {
      return ManagedLogClearResult(
        deletedFileNames: const <String>[],
        issues: prepared.issues,
      );
    }
    final directory = prepared.directory!;
    final scan = await _scanCandidates(directory);
    final deleted = <String>[];
    final issues = <ManagedLogIssue>[...prepared.issues, ...scan.issues];
    for (final candidate in scan.candidates) {
      final revalidated = await _validateCandidate(
        directory,
        candidate.path,
        candidate.fileName,
      );
      final issue = revalidated.issue;
      if (issue != null) {
        issues.add(issue);
        continue;
      }
      if (revalidated.candidate == null) {
        continue;
      }
      try {
        await _fileSystem.deleteFile(candidate.path);
        deleted.add(candidate.fileName);
      } on Object {
        issues.add(
          ManagedLogIssue(
            fileName: candidate.fileName,
            kind: ManagedLogIssueKind.deletionFailed,
          ),
        );
      }
    }
    return ManagedLogClearResult(deletedFileNames: deleted, issues: issues);
  }

  Future<_PreparedDirectory> _prepareDirectory() async {
    final type = await _typeOrNull(logsDirectory);
    if (type == FileSystemEntityType.notFound) {
      return const _PreparedDirectory();
    }
    if (type == null) {
      return const _PreparedDirectory(
        issues: <ManagedLogIssue>[
          ManagedLogIssue(
            fileName: 'logs',
            kind: ManagedLogIssueKind.inaccessible,
          ),
        ],
      );
    }
    if (type != FileSystemEntityType.directory) {
      return const _PreparedDirectory(
        issues: <ManagedLogIssue>[
          ManagedLogIssue(
            fileName: 'logs',
            kind: ManagedLogIssueKind.unsafePath,
          ),
        ],
      );
    }
    try {
      final resolvedRoot = _normalize(
        await _fileSystem.resolveDirectory(_activeUserDataDirectory),
      );
      final resolvedLogs = _normalize(
        await _fileSystem.resolveDirectory(logsDirectory),
      );
      final expectedLogs = _normalize(p.windows.join(resolvedRoot, 'logs'));
      if (!_samePath(expectedLogs, resolvedLogs)) {
        return const _PreparedDirectory(
          issues: <ManagedLogIssue>[
            ManagedLogIssue(
              fileName: 'logs',
              kind: ManagedLogIssueKind.unsafePath,
            ),
          ],
        );
      }
      return _PreparedDirectory(
        directory: _SafeDirectory(
          lexicalPath: logsDirectory,
          resolvedPath: resolvedLogs,
        ),
      );
    } on Object {
      return const _PreparedDirectory(
        issues: <ManagedLogIssue>[
          ManagedLogIssue(
            fileName: 'logs',
            kind: ManagedLogIssueKind.inaccessible,
          ),
        ],
      );
    }
  }

  Future<_CandidateScan> _scanCandidates(_SafeDirectory directory) async {
    final children = <String>[];
    try {
      children.addAll(await _fileSystem.listChildren(directory.lexicalPath));
    } on Object {
      return const _CandidateScan(
        issues: <ManagedLogIssue>[
          ManagedLogIssue(
            fileName: 'logs',
            kind: ManagedLogIssueKind.inaccessible,
          ),
        ],
      );
    }
    children.sort(
      (left, right) => p.windows
          .basename(left)
          .toLowerCase()
          .compareTo(p.windows.basename(right).toLowerCase()),
    );
    final candidates = <_ManagedLogCandidate>[];
    final issues = <ManagedLogIssue>[];
    final seen = <String>{};
    for (final rawPath in children) {
      final path = _normalize(rawPath);
      final fileName = p.windows.basename(path);
      if (!_isManagedFileName(fileName)) {
        continue;
      }
      final key = path.toLowerCase();
      if (!seen.add(key)) {
        continue;
      }
      if (!_samePath(p.windows.dirname(path), directory.lexicalPath)) {
        issues.add(
          ManagedLogIssue(
            fileName: fileName,
            kind: ManagedLogIssueKind.unsafePath,
          ),
        );
        continue;
      }
      final validated = await _validateCandidate(directory, path, fileName);
      if (validated.issue != null) {
        issues.add(validated.issue!);
      } else if (validated.candidate != null) {
        candidates.add(validated.candidate!);
      }
    }
    return _CandidateScan(candidates: candidates, issues: issues);
  }

  Future<_CandidateValidation> _validateCandidate(
    _SafeDirectory directory,
    String path,
    String fileName,
  ) async {
    final type = await _typeOrNull(path);
    if (type == FileSystemEntityType.notFound) {
      return const _CandidateValidation();
    }
    if (type == null) {
      return _CandidateValidation(
        issue: ManagedLogIssue(
          fileName: fileName,
          kind: ManagedLogIssueKind.inaccessible,
        ),
      );
    }
    if (type != FileSystemEntityType.file) {
      return _CandidateValidation(
        issue: ManagedLogIssue(
          fileName: fileName,
          kind: ManagedLogIssueKind.notRegularFile,
        ),
      );
    }
    try {
      final resolved = _normalize(await _fileSystem.resolveFile(path));
      final expected = _normalize(
        p.windows.join(directory.resolvedPath, fileName),
      );
      if (!_samePath(expected, resolved)) {
        return _CandidateValidation(
          issue: ManagedLogIssue(
            fileName: fileName,
            kind: ManagedLogIssueKind.unsafePath,
          ),
        );
      }
      return _CandidateValidation(
        candidate: _ManagedLogCandidate(path: path, fileName: fileName),
      );
    } on Object {
      return _CandidateValidation(
        issue: ManagedLogIssue(
          fileName: fileName,
          kind: ManagedLogIssueKind.inaccessible,
        ),
      );
    }
  }

  Future<FileSystemEntityType?> _typeOrNull(String path) async {
    try {
      return await _fileSystem.entityTypeNoFollow(path);
    } on Object {
      return null;
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static bool _isManagedFileName(String fileName) {
    final match = _managedFileName.firstMatch(fileName);
    return match != null && match.start == 0 && match.end == fileName.length;
  }
}

final class _SafeDirectory {
  const _SafeDirectory({required this.lexicalPath, required this.resolvedPath});

  final String lexicalPath;
  final String resolvedPath;
}

final class _PreparedDirectory {
  const _PreparedDirectory({
    this.directory,
    this.issues = const <ManagedLogIssue>[],
  });

  final _SafeDirectory? directory;
  final List<ManagedLogIssue> issues;
}

final class _ManagedLogCandidate {
  const _ManagedLogCandidate({required this.path, required this.fileName});

  final String path;
  final String fileName;
}

final class _CandidateScan {
  const _CandidateScan({
    this.candidates = const <_ManagedLogCandidate>[],
    this.issues = const <ManagedLogIssue>[],
  });

  final List<_ManagedLogCandidate> candidates;
  final List<ManagedLogIssue> issues;
}

final class _CandidateValidation {
  const _CandidateValidation({this.candidate, this.issue});

  final _ManagedLogCandidate? candidate;
  final ManagedLogIssue? issue;
}

String _absoluteWindowsPath(String value) {
  final normalized = _normalize(value.trim());
  if (normalized.isEmpty || !p.windows.isAbsolute(normalized)) {
    throw ArgumentError.value(
      value,
      'activeUserDataDirectory',
      '必须是绝对 Windows 路径',
    );
  }
  return normalized;
}

String _normalize(String value) => p.windows.normalize(value);

bool _samePath(String left, String right) =>
    _normalize(left).toLowerCase() == _normalize(right).toLowerCase();
