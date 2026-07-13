import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/processing/chunk_evidence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qi_day_flow_evidence_test_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('only matching legacy and active-display metadata scopes are valid', () {
    expect(
      isSupportedVideoMetadataScope(
        schemaVersion: 2,
        captureScope: 'all-displays',
      ),
      isTrue,
    );
    expect(
      isSupportedVideoMetadataScope(
        schemaVersion: 3,
        captureScope: 'active-window-display',
      ),
      isTrue,
    );
    expect(
      isSupportedVideoMetadataScope(
        schemaVersion: 4,
        captureScope: 'active-window-display',
      ),
      isTrue,
    );
    expect(
      isSupportedVideoMetadataScope(
        schemaVersion: 2,
        captureScope: 'active-window-display',
      ),
      isFalse,
    );
    expect(
      isSupportedVideoMetadataScope(
        schemaVersion: 3,
        captureScope: 'all-displays',
      ),
      isFalse,
    );
  });

  test('legacy schema 1 JPEG evidence remains retryable', () async {
    final directory = Directory(p.join(root.path, 'session_1', 'chunk_1'));
    await directory.create(recursive: true);
    final firstFrame = File(p.join(directory.path, 'frame_01.jpg'));
    final secondFrame = File(p.join(directory.path, 'frame_02.jpg'));
    await firstFrame.writeAsBytes(<int>[1, 2, 3]);
    await secondFrame.writeAsBytes(<int>[4, 5, 6]);
    final metadata = File(p.join(directory.path, 'metadata.json'));
    await metadata.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'startTimeMs': 1000,
        'endTimeMs': 61000,
        'keyframes': <Object?>[
          <String, Object?>{'offsetMs': 0, 'path': firstFrame.path},
          <String, Object?>{'offsetMs': 30000, 'path': secondFrame.path},
        ],
        'windowRecords': <Object?>[],
      }),
    );
    final chunk = _chunk(
      directory: directory.path,
      metadataPath: metadata.path,
      frameCount: 2,
      status: ProcessingStatus.failed,
    );

    final evidence = await const ChunkEvidenceReader().read(chunk);

    expect(evidence.keyFrames, hasLength(2));
    expect(await evidence.keyFrames.first.readBytes(), <int>[1, 2, 3]);
  });

  test('legacy schema 2 all-displays MP4 remains retryable', () async {
    final directory = Directory(p.join(root.path, 'session_2', 'chunk_2'));
    await directory.create(recursive: true);
    final video = File(p.join(directory.path, 'chunk_2000_1.mp4'));
    final executable = File(p.join(root.path, 'Code.exe'));
    await video.writeAsBytes(<int>[0, 0, 0, 1]);
    await executable.writeAsBytes(<int>[0x4d, 0x5a]);
    final metadata = File(p.join(directory.path, 'metadata.json'));
    await metadata.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 2,
        'captureScope': 'all-displays',
        'startTimeMs': 2000,
        'endTimeMs': 62000,
        'video': <String, Object?>{
          'path': video.path,
          'codec': 'h264',
          'container': 'mp4',
          'frameCount': 60,
        },
        'windowRecords': <Object?>[
          <String, Object?>{
            'timestampMs': 2000,
            'offsetMs': 0,
            'processId': 42,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'capture_service.cpp',
            'processPath': executable.path,
          },
          <String, Object?>{
            'offsetMs': 30000,
            'processName': 'fake.exe',
            'appName': 'Untrusted App',
            'windowTitle': 'relative path',
            'processPath': r'.\fake.exe',
          },
        ],
      }),
    );
    const channel = MethodChannel('qi_day_flow/test/evidence');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'extractVideoFrames');
      return <Object?>[
        <String, Object?>{
          'offsetMs': 0,
          'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
        },
        <String, Object?>{
          'offsetMs': 59000,
          'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFE, 0xFF, 0xD9]),
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final chunk = _chunk(
      directory: directory.path,
      metadataPath: metadata.path,
      videoPath: video.path,
      frameCount: 60,
      startedAtMs: 2000,
      endedAtMs: 62000,
    );
    final reader = ChunkEvidenceReader(
      nativeService: NativeCaptureService(methodChannel: channel),
    );

    final evidence = await reader.read(chunk);

    expect(evidence.keyFrames, hasLength(2));
    expect(evidence.windowContexts.first.friendlyAppName, 'Visual Studio Code');
    expect(
      evidence.windowContexts.first.executablePath,
      p.normalize(executable.resolveSymbolicLinksSync()),
    );
    expect(evidence.windowContexts.last.executablePath, isNull);
    expect(await evidence.keyFrames.last.readBytes(), <int>[
      0xFF,
      0xD8,
      0xFE,
      0xFF,
      0xD9,
    ]);

    final deletion = await const EvidenceStore().deleteEvidenceGroup(
      chunk: chunk,
      allowedCaptureRoot: root.path,
    );
    expect(deletion.deleted, isTrue);
    expect(await directory.exists(), isFalse);
  });

  test('schema 3 active-display partial MP4 is extracted in memory', () async {
    final directory = Directory(p.join(root.path, 'captures'));
    await directory.create(recursive: true);
    final video = File(p.join(directory.path, 'chunk_3000_1.mp4'));
    final metadata = File(p.join(directory.path, 'chunk_3000_1.json'));
    await video.writeAsBytes(<int>[0, 0, 0, 1]);
    await metadata.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 3,
        'captureScope': 'active-window-display',
        'startTimeMs': 3000,
        'endTimeMs': 15000,
        'virtualDesktop': <String, Object?>{
          'left': -1600,
          'top': 0,
          'width': 1600,
          'height': 1200,
        },
        'video': <String, Object?>{
          'path': video.path,
          'codec': 'h264',
          'container': 'mp4',
          'fps': 1,
          'frameCount': 12,
          'width': 1920,
          'height': 1080,
        },
        'displays': <Object?>[
          <String, Object?>{
            'id': r'\\.\DISPLAY1',
            'left': -1600,
            'top': 0,
            'width': 1600,
            'height': 1200,
          },
          <String, Object?>{
            'id': r'\\.\DISPLAY2',
            'left': 0,
            'top': 0,
            'width': 1920,
            'height': 1080,
          },
        ],
        'sourceChanges': <Object?>[
          <String, Object?>{
            'timestampMs': 3050,
            'offsetMs': 50,
            'displayId': r'\\.\DISPLAY1',
            'left': -1600,
            'top': 0,
            'width': 1600,
            'height': 1200,
          },
          <String, Object?>{
            'timestampMs': 9000,
            'offsetMs': 6000,
            'displayId': r'\\.\DISPLAY2',
            'left': 0,
            'top': 0,
            'width': 1920,
            'height': 1080,
          },
        ],
        'windowRecords': <Object?>[
          <String, Object?>{
            'timestampMs': 3000,
            'offsetMs': 0,
            'processId': 42,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'capture_service.cpp',
            'cpuUsagePercent': null,
            'memoryCommitBytes': 256 * 1024 * 1024,
          },
          <String, Object?>{
            'timestampMs': 9000,
            'offsetMs': 6000,
            'processId': 42,
            'processName': 'Code.exe',
            'appName': 'Visual Studio Code',
            'windowTitle': 'capture_service.cpp',
            'cpuUsagePercent': 12.5,
            'memoryCommitBytes': 320 * 1024 * 1024,
          },
        ],
      }),
    );
    const channel = MethodChannel('qi_day_flow/test/schema-3-evidence');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'extractVideoFrames');
      expect(
        (call.arguments as Map<Object?, Object?>)['expectedFrameCount'],
        12,
      );
      return <Object?>[
        <String, Object?>{
          'offsetMs': 11000,
          'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final chunk = _chunk(
      directory: directory.path,
      metadataPath: metadata.path,
      videoPath: video.path,
      frameCount: 12,
      startedAtMs: 3000,
      endedAtMs: 15000,
    );
    final reader = ChunkEvidenceReader(
      nativeService: NativeCaptureService(methodChannel: channel),
    );

    final evidence = await reader.read(chunk);

    expect(evidence.keyFrames, hasLength(1));
    expect(evidence.keyFrames.single.offsetSeconds, 11);
    expect(evidence.windowContexts, hasLength(1));
    expect(evidence.windowContexts.first.startSeconds, 0);
    expect(evidence.windowContexts.first.endSeconds, 12);
    expect(evidence.resourceSamples, hasLength(2));
    expect(evidence.resourceSamples.first.timestampMs, 3000);
    expect(evidence.resourceSamples.first.processId, 42);
    expect(evidence.resourceSamples.first.offsetSeconds, 0);
    expect(evidence.resourceSamples.first.cpuUsagePercent, isNull);
    expect(evidence.resourceSamples.first.memoryCommitBytes, 256 * 1024 * 1024);
    expect(evidence.resourceSamples.last.offsetSeconds, 6);
    expect(evidence.resourceSamples.last.timestampMs, 9000);
    expect(evidence.resourceSamples.last.cpuUsagePercent, 12.5);
    expect(evidence.resourceSamples.last.memoryCommitBytes, 320 * 1024 * 1024);
  });

  test(
    'schema 4 interval MP4 validates rational timing and extracts',
    () async {
      final directory = Directory(p.join(root.path, 'schema-4'));
      await directory.create(recursive: true);
      final video = File(p.join(directory.path, 'chunk_5000_1.mp4'));
      final metadata = File(p.join(directory.path, 'chunk_5000_1.json'));
      await video.writeAsBytes(<int>[0, 0, 0, 1]);
      await metadata.writeAsString(
        jsonEncode(<String, Object?>{
          'schemaVersion': 4,
          'captureScope': 'active-window-display',
          'captureIntervalSeconds': 20,
          'startTimeMs': 5000,
          'endTimeMs': 65000,
          'durationMs': 60000,
          'virtualDesktop': <String, Object?>{
            'left': 0,
            'top': 0,
            'width': 1920,
            'height': 1080,
          },
          'video': <String, Object?>{
            'path': video.path,
            'codec': 'h264',
            'container': 'mp4',
            'frameRateNumerator': 1,
            'frameRateDenominator': 20,
            'frameDurationTicks': 200000000,
            'frameCount': 3,
            'width': 1920,
            'height': 1080,
          },
          'displays': <Object?>[
            <String, Object?>{
              'id': r'\\.\DISPLAY1',
              'left': 0,
              'top': 0,
              'width': 1920,
              'height': 1080,
            },
          ],
          'sourceChanges': <Object?>[
            <String, Object?>{
              'timestampMs': 5000,
              'offsetMs': 0,
              'displayId': r'\\.\DISPLAY1',
              'left': 0,
              'top': 0,
              'width': 1920,
              'height': 1080,
            },
          ],
          'windowRecords': <Object?>[
            for (var second = 0; second < 60; second++)
              <String, Object?>{
                'timestampMs': 5000 + second * 1000,
                'offsetMs': second * 1000,
                'processId': 42,
                'processName': 'Code.exe',
                'appName': 'Visual Studio Code',
                'windowTitle': 'capture_runtime_test.cpp',
                'cpuUsagePercent': second == 0 ? null : 4.5,
                'memoryCommitBytes': 256 * 1024 * 1024,
              },
          ],
        }),
      );
      const channel = MethodChannel('qi_day_flow/test/schema-4-evidence');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'extractVideoFrames');
        expect(
          (call.arguments as Map<Object?, Object?>)['expectedFrameCount'],
          3,
        );
        return <Object?>[
          <String, Object?>{
            'offsetMs': 0,
            'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
          },
          <String, Object?>{
            'offsetMs': 40000,
            'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
          },
        ];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final chunk = _chunk(
        directory: directory.path,
        metadataPath: metadata.path,
        videoPath: video.path,
        frameCount: 3,
        startedAtMs: 5000,
        endedAtMs: 65000,
      );

      final evidence = await ChunkEvidenceReader(
        nativeService: NativeCaptureService(methodChannel: channel),
      ).read(chunk);

      expect(evidence.keyFrames, hasLength(2));
      expect(evidence.keyFrames.last.offsetSeconds, 40);
      expect(evidence.resourceSamples, hasLength(60));
      expect(evidence.resourceSamples.last.offsetSeconds, 59);
    },
  );

  test('schema 4 evidence strictly validates chunk timing and count', () async {
    final invalidChunks = <CaptureChunk>[
      await _writeStrictVideoChunk(
        root: root,
        label: 'inverted',
        schemaVersion: 4,
        startTimeMs: 3000,
        endTimeMs: 1000,
        durationMs: -2000,
        chunkStartTimeMs: 1000,
        chunkEndTimeMs: 3000,
        frameCount: 1,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'mismatch',
        schemaVersion: 4,
        durationMs: 59000,
        frameCount: 2,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'too-long',
        schemaVersion: 4,
        endTimeMs: 61001,
        durationMs: 60001,
        frameCount: 2,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'too-many-frames',
        schemaVersion: 4,
        captureIntervalSeconds: 10,
        frameCount: 8,
      ),
    ];

    for (final chunk in invalidChunks) {
      await expectLater(
        const ChunkEvidenceReader().read(chunk),
        throwsFormatException,
      );
    }
  });

  test('schema 4 evidence accepts valid partial interval chunks', () async {
    const channel = MethodChannel('qi_day_flow/test/partial-schema-4');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'extractVideoFrames');
      return <Object?>[
        <String, Object?>{
          'offsetMs': 0,
          'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final chunks = <CaptureChunk>[
      await _writeStrictVideoChunk(
        root: root,
        label: 'partial-2s',
        schemaVersion: 4,
        endTimeMs: 3000,
        durationMs: 2000,
        captureIntervalSeconds: 30,
        frameCount: 1,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'partial-31s',
        schemaVersion: 4,
        endTimeMs: 32000,
        durationMs: 31000,
        captureIntervalSeconds: 30,
        frameCount: 2,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'phase-shifted-9.5s',
        schemaVersion: 4,
        endTimeMs: 10500,
        durationMs: 9500,
        captureIntervalSeconds: 10,
        frameCount: 2,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'exact-boundary-60s',
        schemaVersion: 4,
        captureIntervalSeconds: 30,
        frameCount: 3,
      ),
    ];
    final reader = ChunkEvidenceReader(
      nativeService: NativeCaptureService(methodChannel: channel),
    );

    for (final chunk in chunks) {
      final evidence = await reader.read(chunk);
      expect(evidence.keyFrames, hasLength(1));
    }
  });

  test('schema 3 evidence rejects invalid bounded timing', () async {
    final invalidChunks = <CaptureChunk>[
      await _writeStrictVideoChunk(
        root: root,
        label: 'v3-inverted',
        schemaVersion: 3,
        startTimeMs: 3000,
        endTimeMs: 1000,
        chunkStartTimeMs: 1000,
        chunkEndTimeMs: 3000,
        frameCount: 1,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'v3-mismatch',
        schemaVersion: 3,
        endTimeMs: 3000,
        durationMs: 1999,
        includeDuration: true,
        frameCount: 1,
      ),
      await _writeStrictVideoChunk(
        root: root,
        label: 'v3-too-long',
        schemaVersion: 3,
        endTimeMs: 61001,
        durationMs: 60001,
        includeDuration: true,
        frameCount: 60,
      ),
    ];

    for (final chunk in invalidChunks) {
      await expectLater(
        const ChunkEvidenceReader().read(chunk),
        throwsFormatException,
      );
    }
  });

  test('schema 3 rejects a source change for an unknown display', () async {
    final directory = Directory(p.join(root.path, 'invalid-source'));
    await directory.create(recursive: true);
    final video = File(p.join(directory.path, 'chunk_4000_1.mp4'));
    final metadata = File(p.join(directory.path, 'chunk_4000_1.json'));
    await video.writeAsBytes(<int>[0, 0, 0, 1]);
    await metadata.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 3,
        'captureScope': 'active-window-display',
        'startTimeMs': 4000,
        'endTimeMs': 5000,
        'virtualDesktop': <String, Object?>{
          'left': 0,
          'top': 0,
          'width': 1920,
          'height': 1080,
        },
        'video': <String, Object?>{
          'path': video.path,
          'codec': 'h264',
          'container': 'mp4',
          'fps': 1,
          'frameCount': 1,
          'width': 1920,
          'height': 1080,
        },
        'displays': <Object?>[
          <String, Object?>{
            'id': r'\\.\DISPLAY1',
            'left': 0,
            'top': 0,
            'width': 1920,
            'height': 1080,
          },
        ],
        'sourceChanges': <Object?>[
          <String, Object?>{
            'timestampMs': 4050,
            'offsetMs': 50,
            'displayId': r'\\.\MISSING',
            'left': 0,
            'top': 0,
            'width': 1920,
            'height': 1080,
          },
        ],
        'windowRecords': <Object?>[],
      }),
    );
    final chunk = _chunk(
      directory: directory.path,
      metadataPath: metadata.path,
      videoPath: video.path,
      frameCount: 1,
      startedAtMs: 4000,
      endedAtMs: 5000,
    );

    await expectLater(
      const ChunkEvidenceReader().read(chunk),
      throwsFormatException,
    );
  });
}

CaptureChunk _chunk({
  required String directory,
  required String metadataPath,
  String? videoPath,
  required int frameCount,
  int startedAtMs = 1000,
  int endedAtMs = 61000,
  ProcessingStatus status = ProcessingStatus.pending,
}) {
  return CaptureChunk(
    sessionId: 1,
    framesDirectory: directory,
    metadataPath: metadataPath,
    videoPath: videoPath,
    startedAtMs: startedAtMs,
    endedAtMs: endedAtMs,
    frameCount: frameCount,
    status: status,
    createdAtMs: startedAtMs,
    updatedAtMs: startedAtMs,
  );
}

Future<CaptureChunk> _writeStrictVideoChunk({
  required Directory root,
  required String label,
  required int schemaVersion,
  int startTimeMs = 1000,
  int endTimeMs = 61000,
  int? durationMs,
  bool includeDuration = false,
  int? chunkStartTimeMs,
  int? chunkEndTimeMs,
  int captureIntervalSeconds = 30,
  int frameCount = 2,
}) async {
  final directory = Directory(p.join(root.path, label));
  await directory.create(recursive: true);
  final video = File(p.join(directory.path, 'chunk_$label.mp4'));
  final metadata = File(p.join(directory.path, 'chunk_$label.json'));
  await video.writeAsBytes(<int>[0, 0, 0, 1]);
  final json = <String, Object?>{
    'schemaVersion': schemaVersion,
    'captureScope': 'active-window-display',
    'startTimeMs': startTimeMs,
    'endTimeMs': endTimeMs,
    'virtualDesktop': <String, Object?>{
      'left': 0,
      'top': 0,
      'width': 1920,
      'height': 1080,
    },
    'video': <String, Object?>{
      'path': video.path,
      'codec': 'h264',
      'container': 'mp4',
      'frameCount': frameCount,
      'width': 1920,
      'height': 1080,
    },
    'displays': <Object?>[
      <String, Object?>{
        'id': r'\\.\DISPLAY1',
        'left': 0,
        'top': 0,
        'width': 1920,
        'height': 1080,
      },
    ],
    'sourceChanges': <Object?>[],
    'windowRecords': <Object?>[],
  };
  final videoJson = json['video']! as Map<String, Object?>;
  if (schemaVersion == 4) {
    json['captureIntervalSeconds'] = captureIntervalSeconds;
    json['durationMs'] = durationMs ?? endTimeMs - startTimeMs;
    videoJson['frameRateNumerator'] = 1;
    videoJson['frameRateDenominator'] = captureIntervalSeconds;
    videoJson['frameDurationTicks'] = captureIntervalSeconds * 10000000;
  } else {
    videoJson['fps'] = 1;
    if (includeDuration) {
      json['durationMs'] = durationMs;
    }
  }
  await metadata.writeAsString(jsonEncode(json));
  return _chunk(
    directory: directory.path,
    metadataPath: metadata.path,
    videoPath: video.path,
    frameCount: frameCount,
    startedAtMs: chunkStartTimeMs ?? startTimeMs,
    endedAtMs: chunkEndTimeMs ?? endTimeMs,
  );
}
