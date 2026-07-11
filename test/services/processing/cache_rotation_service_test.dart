import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/services/processing/cache_rotation_service.dart';
import 'package:qi_day_flow/services/processing/chunk_evidence.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _TestClock implements Clock {
  _TestClock(this.now);

  int now;

  @override
  int nowUtcEpochMs() => now++;
}

void main() {
  late Directory temporaryDirectory;
  late Directory captureRoot;
  late AppDatabase database;
  late SqliteDayFlowRepository repository;
  late CacheRotationService rotation;
  late CaptureSession session;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_rotation_test_',
    );
    captureRoot = Directory(p.join(temporaryDirectory.path, 'captures'));
    await captureRoot.create();
    database = AppDatabase(
      path: p.join(temporaryDirectory.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    repository = SqliteDayFlowRepository(database, clock: _TestClock(100000));
    await database.open();
    session = await repository.createSession(
      CaptureSession(
        captureScope: 'active-window-display',
        captureDirectory: captureRoot.path,
        startedAtMs: 1000,
        status: CaptureSessionStatus.stopped,
        endedAtMs: 9000,
        createdAtMs: 1000,
        updatedAtMs: 9000,
      ),
    );
    rotation = CacheRotationService(
      captureRepository: repository,
      evidenceStore: const EvidenceStore(),
      clock: _TestClock(200000),
    );
  });

  tearDown(() async {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('purges only the oldest completed flat MP4 and JSON pair', () async {
    final old = await _addFlatChunk(
      repository: repository,
      sessionId: session.id!,
      root: captureRoot,
      stem: 'chunk_1_1000_1',
      startedAtMs: 1000,
      status: ProcessingStatus.completed,
    );
    final recent = await _addFlatChunk(
      repository: repository,
      sessionId: session.id!,
      root: captureRoot,
      stem: 'chunk_1_3000_2',
      startedAtMs: 3000,
      status: ProcessingStatus.completed,
    );

    final result = await rotation.rotate(
      captureDirectory: captureRoot.path,
      limitBytes: 15,
    );

    expect(result.purgedChunkIds, <int>[old.id!]);
    expect(result.finalBytes, 10);
    expect(File(old.videoPath!).existsSync(), isFalse);
    expect(File(old.metadataPath).existsSync(), isFalse);
    expect(File(recent.videoPath!).existsSync(), isTrue);
    expect(File(recent.metadataPath).existsSync(), isTrue);
    expect((await repository.getChunk(old.id!))?.evidencePurgedAtMs, isNotNull);
    expect((await repository.getChunk(recent.id!))?.evidencePurgedAtMs, isNull);
  });

  test('manual clear removes only completed MP4 and JSON evidence', () async {
    final completed = await _addFlatChunk(
      repository: repository,
      sessionId: session.id!,
      root: captureRoot,
      stem: 'chunk_1_1000_completed',
      startedAtMs: 1000,
      status: ProcessingStatus.completed,
    );
    final pending = await _addFlatChunk(
      repository: repository,
      sessionId: session.id!,
      root: captureRoot,
      stem: 'chunk_1_2000_pending',
      startedAtMs: 2000,
      status: ProcessingStatus.pending,
    );
    final processing = await _addFlatChunk(
      repository: repository,
      sessionId: session.id!,
      root: captureRoot,
      stem: 'chunk_1_3000_processing',
      startedAtMs: 3000,
      status: ProcessingStatus.processing,
    );
    final failed = await _addFlatChunk(
      repository: repository,
      sessionId: session.id!,
      root: captureRoot,
      stem: 'chunk_1_4000_failed',
      startedAtMs: 4000,
      status: ProcessingStatus.failed,
      nextRetryAtMs: 9000,
    );
    final legacyDirectory = Directory(p.join(captureRoot.path, 'legacy'));
    await legacyDirectory.create();
    final legacyMetadata = File(p.join(legacyDirectory.path, 'metadata.json'));
    await legacyMetadata.writeAsString('{}');
    final legacy = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: legacyDirectory.path,
        metadataPath: legacyMetadata.path,
        startedAtMs: 5000,
        endedAtMs: 6000,
        frameCount: 1,
        status: ProcessingStatus.completed,
        completedAtMs: 6100,
        createdAtMs: 5000,
        updatedAtMs: 6100,
      ),
    );

    final result = await rotation.clearCompletedVideos(
      captureDirectory: captureRoot.path,
    );

    expect(result.deletedChunkIds, <int>[completed.id!]);
    expect(File(completed.videoPath!).existsSync(), isFalse);
    expect(File(completed.metadataPath).existsSync(), isFalse);
    for (final protected in <CaptureChunk>[pending, processing, failed]) {
      expect(File(protected.videoPath!).existsSync(), isTrue);
      expect(File(protected.metadataPath).existsSync(), isTrue);
      expect(
        (await repository.getChunk(protected.id!))?.evidencePurgedAtMs,
        isNull,
      );
    }
    expect(
      (await repository.getChunk(completed.id!))?.evidencePurgedAtMs,
      isNotNull,
    );
    expect(legacyMetadata.existsSync(), isTrue);
    expect((await repository.getChunk(legacy.id!))?.evidencePurgedAtMs, isNull);
  });

  test('manual clear reports a rejected path without changing state', () async {
    final outside = Directory(p.join(temporaryDirectory.path, 'outside'));
    await outside.create();
    final video = File(p.join(outside.path, 'chunk_outside.mp4'));
    final metadata = File(p.join(outside.path, 'chunk_outside.json'));
    await video.writeAsBytes(List<int>.filled(6, 1));
    await metadata.writeAsBytes(List<int>.filled(4, 2));
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: outside.path,
        metadataPath: metadata.path,
        videoPath: video.path,
        startedAtMs: 1000,
        endedAtMs: 2000,
        frameCount: 1,
        status: ProcessingStatus.completed,
        completedAtMs: 2100,
        createdAtMs: 1000,
        updatedAtMs: 2100,
      ),
    );

    final result = await rotation.clearCompletedVideos(
      captureDirectory: captureRoot.path,
    );

    expect(result.deletedChunkIds, isEmpty);
    expect(result.skippedChunkIds, <int>[chunk.id!]);
    expect(result.messages.single, contains('校验'));
    expect(video.existsSync(), isTrue);
    expect(metadata.existsSync(), isTrue);
    expect((await repository.getChunk(chunk.id!))?.evidencePurgedAtMs, isNull);
  });

  test(
    'retains pending and failed evidence and reports an unmet limit',
    () async {
      final pending = await _addFlatChunk(
        repository: repository,
        sessionId: session.id!,
        root: captureRoot,
        stem: 'chunk_1_1000_pending',
        startedAtMs: 1000,
        status: ProcessingStatus.pending,
      );
      final failed = await _addFlatChunk(
        repository: repository,
        sessionId: session.id!,
        root: captureRoot,
        stem: 'chunk_1_3000_failed',
        startedAtMs: 3000,
        status: ProcessingStatus.failed,
      );

      final result = await rotation.rotate(
        captureDirectory: captureRoot.path,
        limitBytes: 10,
      );

      expect(result.purgedChunkIds, isEmpty);
      expect(result.unableToReachLimit, isTrue);
      expect(result.finalBytes, 20);
      expect(result.messages.last, contains('受保护'));
      expect(File(pending.videoPath!).existsSync(), isTrue);
      expect(File(pending.metadataPath).existsSync(), isTrue);
      expect(File(failed.videoPath!).existsSync(), isTrue);
      expect(File(failed.metadataPath).existsSync(), isTrue);
    },
  );

  test('purges a completed legacy nested JPEG evidence group', () async {
    final directory = Directory(
      p.join(captureRoot.path, 'session_legacy', 'chunk_legacy'),
    );
    await directory.create(recursive: true);
    final frame = File(p.join(directory.path, 'frame_01.jpg'));
    await frame.writeAsBytes(<int>[1, 2, 3, 4, 5]);
    final metadata = File(p.join(directory.path, 'metadata.json'));
    await metadata.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'startTimeMs': 1000,
        'endTimeMs': 2000,
        'keyframes': <Object?>[
          <String, Object?>{'offsetMs': 0, 'path': frame.path},
        ],
      }),
    );
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: directory.path,
        metadataPath: metadata.path,
        startedAtMs: 1000,
        endedAtMs: 2000,
        frameCount: 1,
        status: ProcessingStatus.completed,
        completedAtMs: 2100,
        createdAtMs: 1000,
        updatedAtMs: 2100,
      ),
    );
    final initialBytes = await const EvidenceStore().sizeOf(captureRoot.path);

    final result = await rotation.rotate(
      captureDirectory: captureRoot.path,
      limitBytes: initialBytes,
    );

    expect(result.purgedChunkIds, <int>[chunk.id!]);
    expect(result.finalBytes, 0);
    expect(directory.existsSync(), isFalse);
  });

  test('rejects an out-of-root completed group without deleting it', () async {
    await File(
      p.join(captureRoot.path, 'protected.partial.mp4'),
    ).writeAsBytes(<int>[1]);
    final outside = Directory(p.join(temporaryDirectory.path, 'outside'));
    await outside.create();
    final video = File(p.join(outside.path, 'chunk_outside.mp4'));
    final metadata = File(p.join(outside.path, 'chunk_outside.json'));
    await video.writeAsBytes(List<int>.filled(6, 1));
    await metadata.writeAsBytes(List<int>.filled(4, 2));
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: outside.path,
        metadataPath: metadata.path,
        videoPath: video.path,
        startedAtMs: 1000,
        endedAtMs: 2000,
        frameCount: 1,
        status: ProcessingStatus.completed,
        completedAtMs: 2100,
        createdAtMs: 1000,
        updatedAtMs: 2100,
      ),
    );

    final result = await rotation.rotate(
      captureDirectory: captureRoot.path,
      limitBytes: 1,
    );

    expect(result.skippedChunkIds, <int>[chunk.id!]);
    expect(result.unableToReachLimit, isTrue);
    expect(video.existsSync(), isTrue);
    expect(metadata.existsSync(), isTrue);
    expect((await repository.getChunk(chunk.id!))?.evidencePurgedAtMs, isNull);
  });

  test('rejects a mismatched flat MP4 and JSON pair', () async {
    final video = File(p.join(captureRoot.path, 'chunk_pair_a.mp4'));
    final metadata = File(p.join(captureRoot.path, 'chunk_pair_b.json'));
    await video.writeAsBytes(List<int>.filled(6, 1));
    await metadata.writeAsBytes(List<int>.filled(4, 2));
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: captureRoot.path,
        metadataPath: metadata.path,
        videoPath: video.path,
        startedAtMs: 1000,
        endedAtMs: 2000,
        frameCount: 1,
        status: ProcessingStatus.completed,
        completedAtMs: 2100,
        createdAtMs: 1000,
        updatedAtMs: 2100,
      ),
    );

    final result = await rotation.rotate(
      captureDirectory: captureRoot.path,
      limitBytes: 10,
    );

    expect(result.skippedChunkIds, <int>[chunk.id!]);
    expect(video.existsSync(), isTrue);
    expect(metadata.existsSync(), isTrue);
    expect(captureRoot.existsSync(), isTrue);
  });
}

Future<CaptureChunk> _addFlatChunk({
  required SqliteDayFlowRepository repository,
  required int sessionId,
  required Directory root,
  required String stem,
  required int startedAtMs,
  required ProcessingStatus status,
  int? nextRetryAtMs,
}) async {
  final video = File(p.join(root.path, '$stem.mp4'));
  final metadata = File(p.join(root.path, '$stem.json'));
  await video.writeAsBytes(List<int>.filled(6, 1));
  await metadata.writeAsBytes(List<int>.filled(4, 2));
  return repository.addChunk(
    CaptureChunk(
      sessionId: sessionId,
      framesDirectory: root.path,
      metadataPath: metadata.path,
      videoPath: video.path,
      startedAtMs: startedAtMs,
      endedAtMs: startedAtMs + 1000,
      frameCount: 1,
      status: status,
      nextRetryAtMs: nextRetryAtMs,
      completedAtMs: status == ProcessingStatus.completed
          ? startedAtMs + 1100
          : null,
      createdAtMs: startedAtMs,
      updatedAtMs: startedAtMs + 1100,
    ),
  );
}
