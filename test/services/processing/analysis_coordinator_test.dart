import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/openai/analysis_models.dart';
import 'package:qi_day_flow/services/openai/chat_transport.dart';
import 'package:qi_day_flow/services/openai/openai_analysis_service.dart';
import 'package:qi_day_flow/services/processing/analysis_coordinator.dart';
import 'package:qi_day_flow/services/processing/chunk_evidence.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('successful analysis keeps MP4 and JSON evidence', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_coordinator_test_',
    );
    final captureRoot = Directory(p.join(temporaryDirectory.path, 'captures'));
    await captureRoot.create();
    final database = AppDatabase(
      path: p.join(temporaryDirectory.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    await database.open();
    addTearDown(() async {
      await database.close();
      await temporaryDirectory.delete(recursive: true);
    });

    final session = await repository.createSession(
      CaptureSession(
        captureScope: 'all-displays',
        captureDirectory: captureRoot.path,
        startedAtMs: 1000,
        status: CaptureSessionStatus.stopped,
        endedAtMs: 62000,
        createdAtMs: 1000,
        updatedAtMs: 62000,
      ),
    );
    const stem = 'chunk_1_1000_1';
    final video = File(p.join(captureRoot.path, '$stem.mp4'));
    final metadata = File(p.join(captureRoot.path, '$stem.json'));
    final executable = File(p.join(captureRoot.path, 'Code.exe'));
    final otherExecutable = File(p.join(captureRoot.path, 'OtherCode.exe'));
    await video.writeAsBytes(<int>[0, 0, 0, 1]);
    await executable.writeAsBytes(<int>[0x4d, 0x5a]);
    await otherExecutable.writeAsBytes(<int>[0x4d, 0x5a]);
    await metadata.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 2,
        'captureScope': 'all-displays',
        'startTimeMs': 1000,
        'endTimeMs': 61000,
        'video': <String, Object?>{
          'path': video.path,
          'codec': 'h264',
          'container': 'mp4',
          'frameCount': 60,
        },
        'windowRecords': <Object?>[
          <String, Object?>{
            'offsetMs': 0,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'analysis_coordinator.dart - first',
            'processPath': executable.path,
            'cpuUsagePercent': null,
            'memoryCommitBytes': 100 * 1024 * 1024,
          },
          <String, Object?>{
            'offsetMs': 10000,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'analysis_coordinator.dart - second',
            'processPath': executable.path,
            'cpuUsagePercent': 10.0,
            'memoryCommitBytes': 200 * 1024 * 1024,
          },
          <String, Object?>{
            'offsetMs': 20000,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'analysis_coordinator.dart - third',
            'processPath': executable.path,
            'cpuUsagePercent': 30.0,
            'memoryCommitBytes': 300 * 1024 * 1024,
          },
          <String, Object?>{
            'offsetMs': 30000,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'Different executable with the same app name',
            'processPath': otherExecutable.path,
            'cpuUsagePercent': 80.0,
            'memoryCommitBytes': 800 * 1024 * 1024,
          },
          <String, Object?>{
            'offsetMs': 45000,
            'processName': 'msedge.exe',
            'appName': 'Microsoft Edge',
            'windowTitle': 'Unrelated window',
            'cpuUsagePercent': 90.0,
            'memoryCommitBytes': 1024 * 1024 * 1024,
          },
        ],
      }),
    );
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: captureRoot.path,
        metadataPath: metadata.path,
        videoPath: video.path,
        startedAtMs: 1000,
        endedAtMs: 61000,
        frameCount: 60,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );

    const channel = MethodChannel('qi_day_flow/test/coordinator');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'extractVideoFrames');
      return <Object?>[
        <String, Object?>{
          'offsetMs': 0,
          'jpegBytes': Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final transport = _FakeTransport()
      ..enqueue(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content':
                  '{"observations":[{"start_ts":0,"end_ts":30,"text":"编辑代码"}]}',
            },
          },
        ],
      })
      ..enqueue(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'cards': <Object?>[
                  <String, Object?>{
                    'category': '工作',
                    'title': '完成分析',
                    'summary': '分析结果已写入数据库。',
                    'start_offset_seconds': 0,
                    'end_offset_seconds': 60,
                    'app_sites': <Object?>[
                      <String, Object?>{
                        'name': 'Visual Studio Code',
                        'duration_seconds': 60,
                      },
                    ],
                    'distractions': <Object?>[],
                    'productivity_score': 80,
                  },
                ],
              }),
            },
          },
        ],
      });
    final messages = <String>[];
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: ChunkEvidenceReader(
        nativeService: NativeCaptureService(methodChannel: channel),
      ),
      serviceFactory: () async => OpenAiAnalysisService(
        config: const OpenAiAnalysisConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'secret',
          model: 'vision-model',
        ),
        transport: transport,
      ),
      onMessage: messages.add,
    );

    coordinator.schedule();
    for (var attempt = 0; attempt < 200; attempt++) {
      if ((await repository.getChunk(chunk.id!))?.status ==
          ProcessingStatus.completed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await coordinator.stop();

    expect(
      (await repository.getChunk(chunk.id!))?.status,
      ProcessingStatus.completed,
      reason: messages.join('\n'),
    );
    expect(video.existsSync(), isTrue);
    expect(metadata.existsSync(), isTrue);
    expect((await repository.getChunk(chunk.id!))?.evidencePurgedAtMs, isNull);
    final canonicalExecutable = p.normalize(
      executable.resolveSymbolicLinksSync(),
    );
    final batch = (await repository.listBatches()).single;
    expect(
      (await repository.listObservationsForBatch(batch.id!)).single.processPath,
      canonicalExecutable,
    );
    final storedUsage = (await repository.listCardsForReportDate(
      '1970-01-01',
    )).single.appUsages.single;
    expect(storedUsage.executablePath, canonicalExecutable);
    expect(storedUsage.averageCpuUsagePercent, 20);
    expect(storedUsage.peakCpuUsagePercent, 30);
    expect(storedUsage.averageMemoryCommitBytes, 200 * 1024 * 1024);
    expect(storedUsage.peakMemoryCommitBytes, 300 * 1024 * 1024);
    final serializedRequests = jsonEncode(transport.requests);
    expect(serializedRequests, isNot(contains(canonicalExecutable)));
    expect(serializedRequests, isNot(contains('process_path')));
    expect(serializedRequests, isNot(contains('cpuUsagePercent')));
    expect(serializedRequests, isNot(contains('memoryCommitBytes')));
    expect(serializedRequests, isNot(contains('cpu_usage_percent')));
    expect(serializedRequests, isNot(contains('memory_commit_bytes')));
  });

  test('notifies immediately after claiming a pending chunk', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_coordinator_queue_test_',
    );
    final database = AppDatabase(
      path: p.join(temporaryDirectory.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    await database.open();
    final session = await repository.createSession(
      CaptureSession(
        captureScope: 'active-window-display',
        captureDirectory: temporaryDirectory.path,
        startedAtMs: 1000,
        endedAtMs: 62000,
        status: CaptureSessionStatus.stopped,
        createdAtMs: 1000,
        updatedAtMs: 62000,
      ),
    );
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: p.join(temporaryDirectory.path, 'chunk'),
        metadataPath: p.join(temporaryDirectory.path, 'chunk', 'chunk.json'),
        videoPath: p.join(temporaryDirectory.path, 'chunk', 'chunk.mp4'),
        startedAtMs: 1000,
        endedAtMs: 61000,
        frameCount: 60,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );
    final evidenceReader = _BlockingEvidenceReader();
    var changes = 0;
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: evidenceReader,
      serviceFactory: () async => throw StateError('test service stopped'),
      onChanged: () => changes++,
    );

    ProcessingStatus? statusWhileBlocked;
    int? changesWhileBlocked;
    coordinator.schedule();
    try {
      await evidenceReader.entered.future.timeout(const Duration(seconds: 2));
      statusWhileBlocked = (await repository.getChunk(chunk.id!))?.status;
      changesWhileBlocked = changes;
    } finally {
      evidenceReader.release();
      await coordinator.stop();
      await database.close();
      await temporaryDirectory.delete(recursive: true);
    }

    expect(statusWhileBlocked, ProcessingStatus.processing);
    expect(changesWhileBlocked, 1);
    expect(changes, 2);
  });

  test('retry backlog is paged and cannot starve fresh pending work', () async {
    final repository = _SchedulingRepository(retryCount: 101);
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: const _EmptyEvidenceReader(),
      serviceFactory: () async => throw StateError('expected test failure'),
    );

    await coordinator.retryFailed();
    await _waitUntil(
      () =>
          repository.processedBatchIds.contains(101) &&
          repository.claimedFreshChunks == 1,
    );
    await coordinator.stop();

    expect(repository.batchPageLimits, isNotEmpty);
    expect(repository.batchPageLimits, everyElement(lessThanOrEqualTo(100)));
    expect(repository.batchPageLimits.length, greaterThanOrEqualTo(2));
    expect(repository.processedBatchIds.toSet().length, 102);
    expect(repository.processedBatchIds.length, 102);
    expect(repository.processedBatchIds.indexOf(10000), lessThanOrEqualTo(1));
    expect(repository.retriedBatchIds.toSet().length, 101);
    expect(repository.retriedBatchIds.length, 101);
  });

  test(
    'concurrent retry initialization cannot scan an empty snapshot',
    () async {
      final repository = _SchedulingRepository(retryCount: 1);
      final maxIdGate = repository.maxAnalysisBatchIdGate = Completer<int>();
      final coordinator = AnalysisCoordinator(
        captureRepository: repository,
        analysisRepository: repository,
        timelineRepository: repository,
        evidenceReader: const _EmptyEvidenceReader(),
        serviceFactory: () async => throw StateError('expected test failure'),
      );

      final first = coordinator.retryFailed();
      await Future<void>.delayed(Duration.zero);
      final second = coordinator.retryFailed();
      await Future<void>.delayed(Duration.zero);
      maxIdGate.complete(1);
      await Future.wait(<Future<void>>[first, second]);
      await _waitUntil(() => repository.retriedBatchIds.isNotEmpty);
      await coordinator.stop();

      expect(repository.retriedBatchIds, <int>[1]);
    },
  );

  test('stop waits for an in-flight retry initialization', () async {
    final repository = _SchedulingRepository(retryCount: 1);
    final maxIdGate = repository.maxAnalysisBatchIdGate = Completer<int>();
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: const _EmptyEvidenceReader(),
      serviceFactory: () async => throw StateError('expected test failure'),
    );

    final retrying = coordinator.retryFailed();
    await Future<void>.delayed(Duration.zero);
    var stopCompleted = false;
    final stopping = coordinator.stop().then((_) => stopCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopCompleted, isFalse);

    maxIdGate.complete(1);
    await Future.wait(<Future<void>>[retrying, stopping]);
    expect(stopCompleted, isTrue);
    expect(repository.retriedBatchIds, isEmpty);
  });

  test('standalone retry backlog cannot starve fresh pending work', () async {
    final repository = _SchedulingRepository(
      retryCount: 0,
      standaloneRetryCount: 101,
    );
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: const _EmptyEvidenceReader(),
      serviceFactory: () async => throw StateError('expected test failure'),
    );

    await coordinator.retryFailed();
    await _waitUntil(
      () => repository.claimedChunkIds.contains(_SchedulingRepository.freshId),
    );
    await coordinator.stop();

    expect(
      repository.claimedChunkIds.indexOf(_SchedulingRepository.freshId),
      lessThanOrEqualTo(1),
    );
    expect(repository.standalonePageLimits, isNotEmpty);
    expect(
      repository.standalonePageLimits,
      everyElement(lessThanOrEqualTo(100)),
    );
  });

  test('stop racing a single retry does not strand processing work', () async {
    final repository = _SchedulingRepository(retryCount: 1);
    final retryGate = repository.retryBatchGate = Completer<void>();
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: const _EmptyEvidenceReader(),
      serviceFactory: () async => throw StateError('must not start'),
    );

    final retrying = coordinator.retryFailedItem(chunkId: 1, batchId: 1);
    await _waitUntil(
      () => repository.batches[1]?.status == ProcessingStatus.processing,
    );
    await coordinator.stop();
    retryGate.complete();

    expect(await retrying, isFalse);
    expect(repository.batches[1]?.status, ProcessingStatus.failed);
    expect(repository.chunks[1]?.status, ProcessingStatus.failed);
  });

  test('stop recovers a targeted retry queued behind normal work', () async {
    final repository = _SchedulingRepository(retryCount: 1);
    final evidenceReader = _ConcurrencyTrackingEvidenceReader();
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: evidenceReader,
      serviceFactory: () async => throw StateError('must not start'),
    );

    coordinator.schedule();
    await evidenceReader.firstEntered.future.timeout(
      const Duration(seconds: 2),
    );
    expect(await coordinator.retryFailedItem(chunkId: 1, batchId: 1), isTrue);
    expect(repository.batches[1]?.status, ProcessingStatus.processing);

    final stopping = coordinator.stop();
    evidenceReader.release();
    await stopping;

    expect(repository.batches[1]?.status, ProcessingStatus.failed);
    expect(repository.chunks[1]?.status, ProcessingStatus.failed);
  });

  test('single retry preempts the remaining normal backlog', () async {
    final repository = _SchedulingRepository(
      retryCount: 1,
      freshPendingCount: 2,
    );
    final evidenceReader = _ConcurrencyTrackingEvidenceReader();
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: evidenceReader,
      serviceFactory: () async => throw StateError('expected test failure'),
    );

    coordinator.schedule();
    await evidenceReader.firstEntered.future.timeout(
      const Duration(seconds: 2),
    );
    expect(await coordinator.retryFailedItem(chunkId: 1, batchId: 1), isTrue);
    evidenceReader.release();
    await _waitUntil(() => evidenceReader.readChunkIds.length >= 2);
    await coordinator.stop();

    expect(evidenceReader.readChunkIds.take(2), <int>[
      _SchedulingRepository.freshId,
      1,
    ]);
  });

  test(
    'single retry does not run concurrently with the normal analysis worker',
    () async {
      final repository = _SchedulingRepository(retryCount: 1);
      final evidenceReader = _ConcurrencyTrackingEvidenceReader();
      final coordinator = AnalysisCoordinator(
        captureRepository: repository,
        analysisRepository: repository,
        timelineRepository: repository,
        evidenceReader: evidenceReader,
        serviceFactory: () async => throw StateError('expected test failure'),
      );

      coordinator.schedule();
      try {
        await evidenceReader.firstEntered.future.timeout(
          const Duration(seconds: 2),
        );
        expect(
          await coordinator.retryFailedItem(chunkId: 1, batchId: 1),
          isTrue,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(evidenceReader.maxConcurrentReads, 1);
      } finally {
        evidenceReader.release();
        await coordinator.stop();
      }
    },
  );

  test('single retry schedules only the selected failed item', () async {
    final repository = _SchedulingRepository(retryCount: 2);
    final coordinator = AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      evidenceReader: const _EmptyEvidenceReader(),
      serviceFactory: () async => throw StateError('expected test failure'),
    );

    expect(await coordinator.retryFailedItem(chunkId: 1, batchId: 1), isTrue);
    await _waitUntil(() => repository.processedBatchIds.contains(1));
    await coordinator.stop();

    expect(repository.retriedBatchIds, <int>[1]);
    expect(repository.processedBatchIds, <int>[1]);
    expect(repository.batches[2]?.status, ProcessingStatus.failed);
    expect(repository.chunks[2]?.status, ProcessingStatus.failed);
    expect(
      repository.claimedChunkIds,
      isNot(contains(_SchedulingRepository.freshId)),
    );
    expect(repository.batchPageLimits, isEmpty);
    expect(repository.standalonePageLimits, isEmpty);
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for analysis scheduling');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _SchedulingRepository
    implements CaptureRepository, AnalysisRepository, TimelineRepository {
  _SchedulingRepository({
    required int retryCount,
    int standaloneRetryCount = 0,
    int freshPendingCount = 1,
  }) {
    for (var id = 1; id <= retryCount; id++) {
      final chunk = _chunk(id, ProcessingStatus.failed);
      chunks[id] = chunk;
      batches[id] = _batch(id, chunk.id!, ProcessingStatus.failed);
    }
    for (var id = 1; id <= standaloneRetryCount; id++) {
      chunks[id] = _chunk(id, ProcessingStatus.failed);
    }
    for (var offset = 0; offset < freshPendingCount; offset++) {
      final id = freshId + offset;
      chunks[id] = _chunk(id, ProcessingStatus.pending);
    }
  }

  static const int freshId = 10000;
  final Map<int, CaptureChunk> chunks = <int, CaptureChunk>{};
  final Map<int, AnalysisBatch> batches = <int, AnalysisBatch>{};
  final List<int> batchPageLimits = <int>[];
  final List<int> standalonePageLimits = <int>[];
  final List<int> retriedBatchIds = <int>[];
  final List<int> processedBatchIds = <int>[];
  final List<int> claimedChunkIds = <int>[];
  final Set<int> _processingBatchIds = <int>{};
  Completer<int>? maxAnalysisBatchIdGate;
  Completer<void>? retryBatchGate;
  var claimedFreshChunks = 0;
  var _nextClaimedBatchId = 100000;

  @override
  Future<List<AnalysisBatch>> listBatches({
    Set<ProcessingStatus>? statuses,
    int? afterId,
    int? beforeOrAtId,
    int? updatedBeforeOrAtMs,
    int limit = 100,
  }) async {
    batchPageLimits.add(limit);
    return batches.values
        .where(
          (batch) =>
              (afterId == null || batch.id! > afterId) &&
              (beforeOrAtId == null || batch.id! <= beforeOrAtId) &&
              (statuses == null || statuses.contains(batch.status)),
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<int> getMaxAnalysisBatchId() async {
    final gate = maxAnalysisBatchIdGate;
    if (gate != null) return gate.future;
    return batches.keys.fold<int>(
      0,
      (current, next) => current > next ? current : next,
    );
  }

  @override
  Future<bool> retryBatch(int batchId) async {
    final batch = batches[batchId];
    if (batch?.status != ProcessingStatus.failed) return false;
    retriedBatchIds.add(batchId);
    batches[batchId] = _batch(
      batchId,
      batch!.chunkIds.single,
      ProcessingStatus.processing,
    );
    final chunkId = batch.chunkIds.single;
    chunks[chunkId] = _chunk(chunkId, ProcessingStatus.processing);
    final gate = retryBatchGate;
    if (gate != null) await gate.future;
    return true;
  }

  @override
  Future<AnalysisBatch?> getBatch(int id) async {
    if (_processingBatchIds.add(id)) processedBatchIds.add(id);
    return batches[id];
  }

  @override
  Future<CaptureChunk?> getChunk(int id) async => chunks[id];

  @override
  Future<List<CaptureChunk>> listChunks({
    Set<ProcessingStatus>? statuses,
    int? dueAtMs,
    bool? evidencePurged,
    int? afterId,
    int limit = 100,
  }) async => chunks.values
      .where(
        (chunk) =>
            (afterId == null || chunk.id! > afterId) &&
            (statuses == null || statuses.contains(chunk.status)),
      )
      .take(limit)
      .toList(growable: false);

  @override
  Future<AnalysisBatch> claimChunksForAnalysis(List<int> chunkIds) async {
    claimedFreshChunks++;
    final chunkId = chunkIds.single;
    claimedChunkIds.add(chunkId);
    chunks[chunkId] = _chunk(chunkId, ProcessingStatus.processing);
    final batch = _batch(
      _nextClaimedBatchId++,
      chunkId,
      ProcessingStatus.processing,
    );
    batches[batch.id!] = batch;
    return batch;
  }

  @override
  Future<bool> retryChunk(int id) async {
    final chunk = chunks[id];
    if (chunk?.status != ProcessingStatus.failed) return false;
    chunks[id] = _chunk(id, ProcessingStatus.pending);
    return true;
  }

  @override
  Future<void> markAnalysisFailed(
    int batchId,
    String errorMessage, {
    int? nextRetryAtMs,
  }) async {
    _processingBatchIds.remove(batchId);
    final batch = batches[batchId]!;
    batches[batchId] = _batch(
      batchId,
      batch.chunkIds.single,
      ProcessingStatus.failed,
    );
    final chunkId = batch.chunkIds.single;
    chunks[chunkId] = _chunk(chunkId, ProcessingStatus.failed);
  }

  @override
  Future<List<int>> listStandaloneFailedChunkIds({
    required int updatedBeforeOrAtMs,
    int? afterId,
    int limit = 100,
  }) async {
    standalonePageLimits.add(limit);
    return chunks.values
        .where(
          (chunk) =>
              chunk.status == ProcessingStatus.failed &&
              !batches.values.any(
                (batch) => batch.chunkIds.contains(chunk.id),
              ) &&
              (afterId == null || chunk.id! > afterId),
        )
        .map((chunk) => chunk.id!)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<TimelineCard>> getRecentCards({int limit = 10}) async =>
      const <TimelineCard>[];

  static CaptureChunk _chunk(int id, ProcessingStatus status) => CaptureChunk(
    id: id,
    sessionId: 1,
    framesDirectory: 'C:/test/$id',
    metadataPath: 'C:/test/$id.json',
    videoPath: 'C:/test/$id.mp4',
    startedAtMs: id * 1000,
    endedAtMs: id * 1000 + 500,
    frameCount: 1,
    status: status,
    createdAtMs: id * 1000,
    updatedAtMs: id * 1000,
  );

  static AnalysisBatch _batch(int id, int chunkId, ProcessingStatus status) =>
      AnalysisBatch(
        id: id,
        chunkIds: <int>[chunkId],
        status: status,
        createdAtMs: id * 1000,
        updatedAtMs: id * 1000,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EmptyEvidenceReader extends ChunkEvidenceReader {
  const _EmptyEvidenceReader();

  @override
  Future<ChunkEvidence> read(CaptureChunk chunk) async => const ChunkEvidence(
    keyFrames: <AnalysisKeyFrame>[],
    windowContexts: <WindowContextSegment>[],
    resourceSamples: <WindowResourceSample>[],
  );
}

final class _ConcurrencyTrackingEvidenceReader extends ChunkEvidenceReader {
  final Completer<void> firstEntered = Completer<void>();
  final Completer<void> _release = Completer<void>();
  int _activeReads = 0;
  int maxConcurrentReads = 0;
  final List<int> readChunkIds = <int>[];

  @override
  Future<ChunkEvidence> read(CaptureChunk chunk) async {
    readChunkIds.add(chunk.id!);
    _activeReads++;
    if (_activeReads > maxConcurrentReads) {
      maxConcurrentReads = _activeReads;
    }
    if (!firstEntered.isCompleted) firstEntered.complete();
    try {
      await _release.future;
      return const ChunkEvidence(
        keyFrames: <AnalysisKeyFrame>[],
        windowContexts: <WindowContextSegment>[],
        resourceSamples: <WindowResourceSample>[],
      );
    } finally {
      _activeReads--;
    }
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

final class _FakeTransport implements ChatTransport {
  final Queue<Map<String, Object?>> _responses = Queue<Map<String, Object?>>();
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  void enqueue(Map<String, Object?> response) => _responses.add(response);

  @override
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    requests.add(body);
    return _responses.removeFirst();
  }

  @override
  void close() {}
}

final class _BlockingEvidenceReader extends ChunkEvidenceReader {
  final Completer<void> entered = Completer<void>();
  final Completer<ChunkEvidence> _release = Completer<ChunkEvidence>();

  @override
  Future<ChunkEvidence> read(CaptureChunk chunk) {
    if (!entered.isCompleted) entered.complete();
    return _release.future;
  }

  void release() {
    if (_release.isCompleted) return;
    _release.complete(
      const ChunkEvidence(
        keyFrames: <AnalysisKeyFrame>[],
        windowContexts: <WindowContextSegment>[],
        resourceSamples: <WindowResourceSample>[],
      ),
    );
  }
}
