import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/processing/chunk_evidence.dart';

void main() {
  late Directory root;
  late Directory captures;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'qi_day_flow_failed_evidence_cleanup_',
    );
    captures = Directory(p.join(root.path, 'captures'));
    await captures.create();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('later chunk staging failure rolls every earlier chunk back', () async {
    final first = await _flatChunk(captures, id: 1);
    final second = await _flatChunk(captures, id: 2);
    var databaseCalls = 0;
    final store = EvidenceStore(
      renameArtifact: (source, destination) async {
        if (source == second.videoPath) {
          throw const FileSystemException('injected later chunk failure');
        }
        await File(source).rename(destination);
      },
    );

    final result = await store.deleteFailedEvidence(
      chunks: <CaptureChunk>[first, second],
      allowedCaptureRoot: captures.path,
      deleteDatabaseRecords: () async {
        databaseCalls++;
        return true;
      },
    );

    expect(result.deleted, isFalse);
    expect(databaseCalls, 0);
    await _expectArtifactsExist(<CaptureChunk>[first, second]);
    expect(await _readyCleanupDirectories(captures), isEmpty);
  });

  test(
    'later artifact staging failure rolls the complete group back',
    () async {
      final chunk = await _nestedLegacyChunk(captures, id: 1, frameCount: 2);
      final secondFrame = p.join(chunk.framesDirectory, 'frame_2.jpg');
      var databaseCalls = 0;
      final store = EvidenceStore(
        renameArtifact: (source, destination) async {
          if (source == secondFrame) {
            throw const FileSystemException('injected later artifact failure');
          }
          await File(source).rename(destination);
        },
      );

      final result = await store.deleteFailedEvidence(
        chunks: <CaptureChunk>[chunk],
        allowedCaptureRoot: captures.path,
        deleteDatabaseRecords: () async {
          databaseCalls++;
          return true;
        },
      );

      expect(result.deleted, isFalse);
      expect(databaseCalls, 0);
      expect(await File(chunk.metadataPath).exists(), isTrue);
      expect(
        await File(p.join(chunk.framesDirectory, 'frame_1.jpg')).exists(),
        isTrue,
      );
      expect(await File(secondFrame).exists(), isTrue);
    },
  );

  test(
    'quarantine commit failure rolls back before database deletion',
    () async {
      final chunk = await _flatChunk(captures, id: 1);
      var databaseCalls = 0;
      final store = EvidenceStore(
        renameQuarantine: (source, destination) async {
          throw const FileSystemException('injected quarantine commit failure');
        },
      );

      final result = await store.deleteFailedEvidence(
        chunks: <CaptureChunk>[chunk],
        allowedCaptureRoot: captures.path,
        deleteDatabaseRecords: () async {
          databaseCalls++;
          return true;
        },
      );

      expect(result.deleted, isFalse);
      expect(databaseCalls, 0);
      await _expectArtifactsExist(<CaptureChunk>[chunk]);
      expect(await _readyCleanupDirectories(captures), isEmpty);
    },
  );

  test('database failure rolls all staged artifacts back', () async {
    final flat = await _flatChunk(captures, id: 1);
    final nested = await _nestedLegacyChunk(captures, id: 2, frameCount: 2);
    var stagedBeforeDatabase = false;

    final result = await const EvidenceStore().deleteFailedEvidence(
      chunks: <CaptureChunk>[flat, nested],
      allowedCaptureRoot: captures.path,
      deleteDatabaseRecords: () async {
        stagedBeforeDatabase =
            !await File(flat.metadataPath).exists() &&
            !await File(flat.videoPath!).exists() &&
            !await File(nested.metadataPath).exists();
        throw StateError('injected database failure');
      },
    );

    expect(stagedBeforeDatabase, isTrue);
    expect(result.deleted, isFalse);
    await _expectArtifactsExist(<CaptureChunk>[flat, nested]);
  });

  test(
    'success deletes flat and nested multi-chunk evidence after DB',
    () async {
      final flat = await _flatChunk(captures, id: 1);
      final nested = await _nestedLegacyChunk(captures, id: 2, frameCount: 2);
      var databaseCalls = 0;

      final result = await const EvidenceStore().deleteFailedEvidence(
        chunks: <CaptureChunk>[flat, nested],
        allowedCaptureRoot: captures.path,
        deleteDatabaseRecords: () async {
          databaseCalls++;
          expect(await File(flat.videoPath!).exists(), isFalse);
          expect(await File(flat.metadataPath).exists(), isFalse);
          expect(await File(nested.metadataPath).exists(), isFalse);
          return true;
        },
      );

      expect(result.deleted, isTrue);
      expect(result.quarantineRetained, isFalse);
      expect(databaseCalls, 1);
      expect(await File(flat.videoPath!).exists(), isFalse);
      expect(await File(flat.metadataPath).exists(), isFalse);
      expect(await Directory(nested.framesDirectory).exists(), isFalse);
      expect(await _readyCleanupDirectories(captures), isEmpty);
    },
  );

  test(
    'junction-backed capture root supports failed-evidence deletion',
    () async {
      final junction = Directory(p.join(root.path, 'captures-junction'));
      final created = await Process.run('cmd.exe', <String>[
        '/c',
        'mklink',
        '/J',
        junction.path,
        captures.path,
      ]);
      expect(
        created.exitCode,
        0,
        reason: '${created.stdout}\n${created.stderr}',
      );
      final chunk = await _flatChunk(junction, id: 1);
      var databaseCalls = 0;
      final store = EvidenceStore(
        purgeQuarantine: (_) async {
          throw const FileSystemException('injected retained junction cleanup');
        },
      );

      final result = await store.deleteFailedEvidence(
        chunks: <CaptureChunk>[chunk],
        allowedCaptureRoot: junction.path,
        deleteDatabaseRecords: () async {
          databaseCalls++;
          return true;
        },
      );

      expect(result.deleted, isTrue);
      expect(result.quarantineRetained, isTrue);
      expect(databaseCalls, 1);
      expect(await File(chunk.videoPath!).exists(), isFalse);
      expect(await File(chunk.metadataPath).exists(), isFalse);
      expect(await _readyCleanupDirectories(junction), hasLength(1));

      final recovery = await const EvidenceStore().retryPendingCleanup(
        junction.path,
        hasAnyChunkRecords: (_) async => false,
      );
      expect(recovery.deletedDirectories, 1);
      expect(recovery.failedDirectories, 0);
      expect(await _readyCleanupDirectories(junction), isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test('post-DB purge failure remains discoverable and is retried', () async {
    final chunk = await _flatChunk(captures, id: 1);
    String? retainedPath;
    final store = EvidenceStore(
      purgeQuarantine: (path) async {
        retainedPath = path;
        throw const FileSystemException('injected final purge failure');
      },
    );

    final result = await store.deleteFailedEvidence(
      chunks: <CaptureChunk>[chunk],
      allowedCaptureRoot: captures.path,
      deleteDatabaseRecords: () async => true,
    );

    expect(result.deleted, isTrue);
    expect(result.quarantineRetained, isTrue);
    expect(retainedPath, isNotNull);
    expect(await Directory(retainedPath!).exists(), isTrue);
    expect(
      p.isWithin(
        p.join(captures.path, EvidenceStore.cleanupDirectoryName),
        retainedPath!,
      ),
      isTrue,
    );

    final recovery = await const EvidenceStore().retryPendingCleanup(
      captures.path,
      hasAnyChunkRecords: (_) async => false,
    );

    expect(recovery.deletedDirectories, 1);
    expect(recovery.failedDirectories, 0);
    expect(await Directory(retainedPath!).exists(), isFalse);
  });

  test(
    'partial staging with retained DB row restores moved artifacts',
    () async {
      final chunk = await _flatChunk(captures, id: 11);
      final operation = await _createRecoveryOperation(
        captures: captures,
        chunk: chunk,
        prefix: 'staging',
        movedArtifacts: 1,
      );

      final recovery = await const EvidenceStore().retryPendingCleanup(
        captures.path,
        hasAnyChunkRecords: (ids) async => ids.contains(11),
      );

      expect(recovery.deletedDirectories, 1);
      expect(recovery.failedDirectories, 0);
      await _expectArtifactsExist(<CaptureChunk>[chunk]);
      expect(await operation.exists(), isFalse);
    },
  );

  test(
    'ready quarantine with retained DB row restores all artifacts',
    () async {
      final chunk = await _flatChunk(captures, id: 12);
      final operation = await _createRecoveryOperation(
        captures: captures,
        chunk: chunk,
        prefix: 'ready',
        movedArtifacts: 2,
      );

      final recovery = await const EvidenceStore().retryPendingCleanup(
        captures.path,
        hasAnyChunkRecords: (ids) async => ids.contains(12),
      );

      expect(recovery.deletedDirectories, 1);
      expect(recovery.failedDirectories, 0);
      await _expectArtifactsExist(<CaptureChunk>[chunk]);
      expect(await operation.exists(), isFalse);
    },
  );

  test('quarantine with absent DB rows is purged without restoring', () async {
    final chunk = await _flatChunk(captures, id: 13);
    final operation = await _createRecoveryOperation(
      captures: captures,
      chunk: chunk,
      prefix: 'ready',
      movedArtifacts: 2,
    );

    final recovery = await const EvidenceStore().retryPendingCleanup(
      captures.path,
      hasAnyChunkRecords: (_) async => false,
    );

    expect(recovery.deletedDirectories, 1);
    expect(recovery.failedDirectories, 0);
    expect(await File(chunk.metadataPath).exists(), isFalse);
    expect(await File(chunk.videoPath!).exists(), isFalse);
    expect(await operation.exists(), isFalse);
  });

  test('traversal manifest is retained and counted as failure', () async {
    final cleanup = Directory(
      p.join(captures.path, EvidenceStore.cleanupDirectoryName),
    );
    final operation = Directory(p.join(cleanup.path, 'staging-malformed'));
    await operation.create(recursive: true);
    await File(p.join(operation.path, 'manifest.json')).writeAsString(
      jsonEncode(<String, Object>{
        'version': 1,
        'chunk_ids': <int>[14],
        'moves': <Object>[
          <String, String>{
            'source': p.join('..', 'outside.json'),
            'quarantine': 'artifact.json',
          },
        ],
      }),
    );

    final recovery = await const EvidenceStore().retryPendingCleanup(
      captures.path,
      hasAnyChunkRecords: (_) async => true,
    );

    expect(recovery.deletedDirectories, 0);
    expect(recovery.failedDirectories, 1);
    expect(await operation.exists(), isTrue);
  });

  test(
    'rollback failure retains quarantine for later reconciliation',
    () async {
      final chunk = await _flatChunk(captures, id: 15);
      final store = EvidenceStore(
        renameArtifact: (source, destination) async {
          if (p.isWithin(
                p.join(captures.path, EvidenceStore.cleanupDirectoryName),
                source,
              ) &&
              destination == chunk.metadataPath) {
            throw const FileSystemException('injected rollback failure');
          }
          await File(source).rename(destination);
        },
      );

      final result = await store.deleteFailedEvidence(
        chunks: <CaptureChunk>[chunk],
        allowedCaptureRoot: captures.path,
        deleteDatabaseRecords: () async => false,
      );

      expect(result.deleted, isFalse);
      expect(result.message, contains('回滚失败'));
      expect(await _readyCleanupDirectories(captures), hasLength(1));

      final recovery = await const EvidenceStore().retryPendingCleanup(
        captures.path,
        hasAnyChunkRecords: (_) async => true,
      );
      expect(recovery.failedDirectories, 0);
      await _expectArtifactsExist(<CaptureChunk>[chunk]);
    },
  );
}

Future<Directory> _createRecoveryOperation({
  required Directory captures,
  required CaptureChunk chunk,
  required String prefix,
  required int movedArtifacts,
}) async {
  final cleanup = Directory(
    p.join(captures.path, EvidenceStore.cleanupDirectoryName),
  );
  final operation = Directory(p.join(cleanup.path, '$prefix-${chunk.id}'));
  final group = Directory(p.join(operation.path, 'group-0'));
  await group.create(recursive: true);
  final artifacts = <String>[chunk.metadataPath, chunk.videoPath!];
  final moves = <Map<String, String>>[];
  for (var index = 0; index < artifacts.length; index++) {
    final source = artifacts[index];
    final destination = p.join(group.path, '$index-${p.basename(source)}');
    moves.add(<String, String>{
      'source': p.relative(source, from: captures.path),
      'quarantine': p.relative(destination, from: operation.path),
    });
  }
  await File(p.join(operation.path, 'manifest.json')).writeAsString(
    jsonEncode(<String, Object>{
      'version': 1,
      'chunk_ids': <int>[chunk.id!],
      'moves': moves,
    }),
    flush: true,
  );
  for (var index = 0; index < movedArtifacts; index++) {
    final source = artifacts[index];
    await File(
      source,
    ).rename(p.join(group.path, '$index-${p.basename(source)}'));
  }
  return operation;
}

Future<CaptureChunk> _flatChunk(Directory captures, {required int id}) async {
  final stem = 'chunk_$id';
  final metadata = File(p.join(captures.path, '$stem.json'));
  final video = File(p.join(captures.path, '$stem.mp4'));
  await metadata.writeAsString('{}');
  await video.writeAsBytes(<int>[id]);
  return _chunk(
    id: id,
    directory: captures.path,
    metadataPath: metadata.path,
    videoPath: video.path,
  );
}

Future<CaptureChunk> _nestedLegacyChunk(
  Directory captures, {
  required int id,
  required int frameCount,
}) async {
  final directory = Directory(p.join(captures.path, 'legacy_$id'));
  await directory.create();
  final framePaths = <String>[];
  for (var index = 1; index <= frameCount; index++) {
    final frame = File(p.join(directory.path, 'frame_$index.jpg'));
    await frame.writeAsBytes(<int>[id, index]);
    framePaths.add(frame.path);
  }
  final metadata = File(p.join(directory.path, 'metadata.json'));
  await metadata.writeAsString(
    jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'keyframes': framePaths
          .map((path) => <String, Object?>{'path': path})
          .toList(growable: false),
    }),
  );
  return _chunk(id: id, directory: directory.path, metadataPath: metadata.path);
}

CaptureChunk _chunk({
  required int id,
  required String directory,
  required String metadataPath,
  String? videoPath,
}) => CaptureChunk(
  id: id,
  sessionId: 1,
  framesDirectory: directory,
  metadataPath: metadataPath,
  videoPath: videoPath,
  startedAtMs: id * 1000,
  endedAtMs: id * 1000 + 500,
  frameCount: 1,
  status: ProcessingStatus.failed,
  createdAtMs: id * 1000,
  updatedAtMs: id * 1000,
);

Future<void> _expectArtifactsExist(List<CaptureChunk> chunks) async {
  for (final chunk in chunks) {
    expect(await File(chunk.metadataPath).exists(), isTrue);
    final videoPath = chunk.videoPath;
    if (videoPath != null) expect(await File(videoPath).exists(), isTrue);
    if (videoPath == null) {
      expect(
        await Directory(chunk.framesDirectory).list().length,
        greaterThan(1),
      );
    }
  }
}

Future<List<Directory>> _readyCleanupDirectories(Directory captures) async {
  final cleanup = Directory(
    p.join(captures.path, EvidenceStore.cleanupDirectoryName),
  );
  if (!await cleanup.exists()) return <Directory>[];
  return cleanup
      .list()
      .where(
        (entity) =>
            entity is Directory && p.basename(entity.path).startsWith('ready-'),
      )
      .cast<Directory>()
      .toList();
}
