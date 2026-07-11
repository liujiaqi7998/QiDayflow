import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _TestClock implements Clock {
  _TestClock(this.now);

  int now;

  @override
  int nowUtcEpochMs() => now;
}

void main() {
  const baseTime = 1783728000000;
  late Directory temporaryDirectory;
  late AppDatabase appDatabase;
  late _TestClock clock;
  late SqliteDayFlowRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_analysis_queue_test_',
    );
    appDatabase = AppDatabase(
      path: '${temporaryDirectory.path}${Platform.pathSeparator}dayflow.db',
      databaseFactory: databaseFactoryFfi,
    );
    clock = _TestClock(baseTime);
    repository = SqliteDayFlowRepository(appDatabase, clock: clock);
    await appDatabase.open();
  });

  tearDown(() async {
    await appDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'active analysis queue filters, sorts, joins batches, and maps fields',
    () async {
      final session = await repository.createSession(
        CaptureSession(
          captureScope: 'active-window-display',
          captureDirectory: 'C:/test-only/captures',
          startedAtMs: baseTime,
          createdAtMs: baseTime,
          updatedAtMs: baseTime,
        ),
      );

      final pendingNew = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'pending-new',
        startedAtMs: baseTime + 300000,
        createdAtMs: baseTime + 3000,
      );
      final failedOldChunk = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'failed-old',
        startedAtMs: baseTime + 400000,
        createdAtMs: baseTime + 4000,
      );
      clock.now = baseTime + 10000;
      final failedOldBatch = await repository.claimChunksForAnalysis([
        failedOldChunk.id!,
      ]);
      clock.now = baseTime + 11000;
      await repository.markAnalysisFailed(failedOldBatch.id!, 'older failure');

      final processingChunk = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'processing',
        startedAtMs: baseTime + 500000,
        createdAtMs: baseTime + 5000,
        durationMs: 90000,
      );
      clock.now = baseTime + 12000;
      final processingBatch = await repository.claimChunksForAnalysis([
        processingChunk.id!,
      ]);

      final pendingOld = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'pending-old',
        startedAtMs: baseTime + 100000,
        createdAtMs: baseTime + 1000,
      );
      final failedNewChunk = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'failed-new',
        startedAtMs: baseTime + 600000,
        createdAtMs: baseTime + 6000,
      );
      clock.now = baseTime + 13000;
      final failedNewBatch = await repository.claimChunksForAnalysis([
        failedNewChunk.id!,
      ]);
      clock.now = baseTime + 14000;
      await repository.markAnalysisFailed(failedNewBatch.id!, 'newer failure');
      final completed = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'completed',
        startedAtMs: baseTime + 700000,
        createdAtMs: baseTime + 7000,
        status: ProcessingStatus.completed,
      );

      final queue = await repository.listAnalysisQueue();

      expect(queue.map((item) => item.chunkId), <int>[
        processingChunk.id!,
        pendingOld.id!,
        pendingNew.id!,
        failedNewChunk.id!,
        failedOldChunk.id!,
      ]);
      expect(queue.map((item) => item.status), <ProcessingStatus>[
        ProcessingStatus.processing,
        ProcessingStatus.pending,
        ProcessingStatus.pending,
        ProcessingStatus.failed,
        ProcessingStatus.failed,
      ]);
      expect(queue.map((item) => item.chunkId), isNot(contains(completed.id)));

      final processing = queue.first;
      expect(processing.batchId, processingBatch.id);
      expect(processing.startedAtMs, processingChunk.startedAtMs);
      expect(processing.endedAtMs, processingChunk.endedAtMs);
      expect(processing.enqueuedAtMs, processingChunk.createdAtMs);
      expect(processing.processingStartedAtMs, baseTime + 12000);
      expect(processing.updatedAtMs, baseTime + 12000);
      expect(processing.retryCount, 0);
      expect(processing.errorMessage, isNull);

      final failed = queue[3];
      expect(failed.batchId, failedNewBatch.id);
      expect(failed.retryCount, 1);
      expect(failed.errorMessage, 'newer failure');
      expect(failed.processingStartedAtMs, isNull);
      expect(failed.updatedAtMs, baseTime + 14000);

      expect(
        (await repository.listAnalysisQueue(
          limit: 3,
        )).map((item) => item.chunkId),
        <int>[processingChunk.id!, pendingOld.id!, pendingNew.id!],
      );
    },
  );

  test(
    'active analysis queue is uncapped unless a limit is requested',
    () async {
      final session = await repository.createSession(
        CaptureSession(
          captureScope: 'active-window-display',
          captureDirectory: 'C:/test-only/captures',
          startedAtMs: baseTime,
          createdAtMs: baseTime,
          updatedAtMs: baseTime,
        ),
      );
      final database = await appDatabase.open();
      final batch = database.batch();
      for (var index = 0; index < 1001; index++) {
        final startedAtMs = baseTime + index * 60000;
        batch.insert('capture_chunks', <String, Object?>{
          'session_id': session.id!,
          'frames_directory': 'C:/test-only/captures/pending-$index',
          'metadata_path': 'C:/test-only/captures/pending-$index/metadata.json',
          'video_path': 'C:/test-only/captures/pending-$index/video.mp4',
          'started_at_ms': startedAtMs,
          'ended_at_ms': startedAtMs + 60000,
          'frame_count': 5,
          'status': ProcessingStatus.pending.name,
          'retry_count': 0,
          'created_at_ms': baseTime + index,
          'updated_at_ms': baseTime + index,
        });
      }
      await batch.commit(noResult: true);

      expect(await repository.listAnalysisQueue(), hasLength(1001));
      expect(await repository.listAnalysisQueue(limit: 10), hasLength(10));
    },
  );
}

Future<CaptureChunk> _addChunk(
  SqliteDayFlowRepository repository, {
  required int sessionId,
  required String suffix,
  required int startedAtMs,
  required int createdAtMs,
  int durationMs = 60000,
  ProcessingStatus status = ProcessingStatus.pending,
}) {
  return repository.addChunk(
    CaptureChunk(
      sessionId: sessionId,
      framesDirectory: 'C:/test-only/captures/$suffix',
      metadataPath: 'C:/test-only/captures/$suffix/metadata.json',
      videoPath: 'C:/test-only/captures/$suffix/video.mp4',
      startedAtMs: startedAtMs,
      endedAtMs: startedAtMs + durationMs,
      frameCount: 5,
      status: status,
      completedAtMs: status == ProcessingStatus.completed
          ? startedAtMs + durationMs
          : null,
      createdAtMs: createdAtMs,
      updatedAtMs: createdAtMs,
    ),
  );
}
