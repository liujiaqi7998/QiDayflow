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
