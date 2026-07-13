import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/native/capture_video_spec.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('capture configuration sends an integer capture interval', () {
    const configuration = NativeCaptureConfiguration(
      outputDirectory: r'C:\QiDayFlow\captures',
      sessionId: '42',
      captureIntervalSeconds: 20,
    );

    expect(configuration.toMap(), <String, Object>{
      'outputDirectory': r'C:\QiDayFlow\captures',
      'sessionId': '42',
      'captureIntervalSeconds': 20,
      'chunkDurationSeconds': 60,
      'maxWidth': 1920,
      'maxHeight': 1080,
      'idlePauseEnabled': true,
      'idleTimeoutSeconds': 600,
    });
    expect(configuration.toMap().containsKey('displayId'), isFalse);
    expect(configuration.toMap().containsKey('fps'), isFalse);
  });

  test('parses a flat MP4 and JSON chunk event', () {
    final event = NativeCaptureEvent.fromMap(<Object?, Object?>{
      'type': 'chunkCompleted',
      'schemaVersion': 3,
      'captureScope': 'active-window-display',
      'sessionId': '42',
      'chunkId': 'chunk_42_1000_1',
      'directoryPath': r'C:\captures',
      'videoPath': r'C:\captures\chunk_42_1000_1.mp4',
      'metadataPath': r'C:\captures\chunk_42_1000_1.json',
      'startTimeMs': 1000,
      'endTimeMs': 61000,
      'frameCount': 60,
      'videoWidth': 1920,
      'videoHeight': 1080,
      'windowRecords': <Object?>[
        <String, Object?>{
          'timestampMs': 1000,
          'offsetMs': 0,
          'processId': 42,
          'appName': 'Visual Studio Code',
          'processName': 'Code.exe',
          'processPath': r'C:\Apps\Code.exe',
          'windowTitle': 'capture_service.cpp',
          'cpuUsagePercent': null,
          'memoryCommitBytes': 256 * 1024 * 1024,
        },
        <String, Object?>{
          'timestampMs': 2000,
          'offsetMs': 1000,
          'processId': 42,
          'appName': 'Visual Studio Code',
          'processName': 'Code.exe',
          'processPath': r'C:\Apps\Code.exe',
          'windowTitle': 'capture_service.cpp',
          'cpuUsagePercent': 12.5,
          'memoryCommitBytes': null,
        },
      ],
    });

    expect(event, isA<NativeChunkCompletedEvent>());
    final chunk = event as NativeChunkCompletedEvent;
    expect(chunk.schemaVersion, 3);
    expect(chunk.frameCount, 60);
    expect(chunk.directoryPath, r'C:\captures');
    expect(chunk.videoPath, r'C:\captures\chunk_42_1000_1.mp4');
    expect(chunk.metadataPath, r'C:\captures\chunk_42_1000_1.json');
    expect(chunk.captureScope, activeWindowDisplayCaptureScope);
    expect(chunk.videoWidth, 1920);
    expect(chunk.videoHeight, 1080);
    expect(chunk.captureIntervalSeconds, 1);
    expect(chunk.videoFrameRateNumerator, 1);
    expect(chunk.videoFrameRateDenominator, 1);
    expect(chunk.videoFrameDurationTicks, 10000000);
    expect(chunk.windowRecords, hasLength(2));
    expect(chunk.windowRecords.first.timestampMs, 1000);
    expect(chunk.windowRecords.first.processId, 42);
    expect(chunk.windowRecords.first.cpuUsagePercent, isNull);
    expect(chunk.windowRecords.first.memoryCommitBytes, 256 * 1024 * 1024);
    expect(chunk.windowRecords.last.cpuUsagePercent, 12.5);
    expect(chunk.windowRecords.last.memoryCommitBytes, isNull);
  });

  test('parses schema 4 interval and actual video timing', () {
    final event = NativeCaptureEvent.fromMap(<Object?, Object?>{
      'type': 'chunkCompleted',
      'schemaVersion': 4,
      'captureScope': 'active-window-display',
      'captureIntervalSeconds': 20,
      'sessionId': '42',
      'chunkId': 'chunk_42_1000_2',
      'directoryPath': r'C:\captures',
      'videoPath': r'C:\captures\chunk_42_1000_2.mp4',
      'metadataPath': r'C:\captures\chunk_42_1000_2.json',
      'startTimeMs': 1000,
      'endTimeMs': 61000,
      'durationMs': 60000,
      'frameCount': 3,
      'videoWidth': 1920,
      'videoHeight': 1080,
      'videoFrameRateNumerator': 1,
      'videoFrameRateDenominator': 20,
      'videoFrameDurationTicks': 200000000,
      'windowRecords': <Object?>[],
    });

    expect(event, isA<NativeChunkCompletedEvent>());
    final chunk = event as NativeChunkCompletedEvent;
    expect(chunk.schemaVersion, 4);
    expect(chunk.captureIntervalSeconds, 20);
    expect(chunk.videoFrameRateNumerator, 1);
    expect(chunk.videoFrameRateDenominator, 20);
    expect(chunk.videoFrameDurationTicks, 200000000);
  });

  test('schema 4 native event rejects inconsistent video timing', () {
    expect(
      () => NativeCaptureEvent.fromMap(<Object?, Object?>{
        'type': 'chunkCompleted',
        'schemaVersion': 4,
        'captureScope': 'active-window-display',
        'captureIntervalSeconds': 10,
        'sessionId': '42',
        'chunkId': 'chunk_42_1000_3',
        'directoryPath': r'C:\captures',
        'videoPath': r'C:\captures\chunk_42_1000_3.mp4',
        'metadataPath': r'C:\captures\chunk_42_1000_3.json',
        'startTimeMs': 1000,
        'endTimeMs': 61000,
        'frameCount': 6,
        'videoWidth': 1920,
        'videoHeight': 1080,
        'videoFrameRateNumerator': 1,
        'videoFrameRateDenominator': 1,
        'videoFrameDurationTicks': 10000000,
        'windowRecords': <Object?>[],
      }),
      throwsFormatException,
    );
  });

  test('schema 4 native event strictly validates chunk timing and count', () {
    for (final event in <Map<Object?, Object?>>[
      _schema4ChunkEvent(startTimeMs: 61000, endTimeMs: 1000),
      _schema4ChunkEvent(durationMs: 59000),
      _schema4ChunkEvent(endTimeMs: 61001, durationMs: 60001),
      _schema4ChunkEvent(captureIntervalSeconds: 30, frameCount: 3),
    ]) {
      expect(() => NativeCaptureEvent.fromMap(event), throwsFormatException);
    }
  });

  test('schema 4 native event accepts valid partial interval chunks', () {
    final twoSecond =
        NativeCaptureEvent.fromMap(
              _schema4ChunkEvent(
                endTimeMs: 3000,
                durationMs: 2000,
                captureIntervalSeconds: 30,
                frameCount: 1,
              ),
            )
            as NativeChunkCompletedEvent;
    final thirtyOneSecond =
        NativeCaptureEvent.fromMap(
              _schema4ChunkEvent(
                endTimeMs: 32000,
                durationMs: 31000,
                captureIntervalSeconds: 30,
                frameCount: 2,
              ),
            )
            as NativeChunkCompletedEvent;

    expect(twoSecond.frameCount, 1);
    expect(thirtyOneSecond.frameCount, 2);
  });

  test('schema 3 native event retains bounded compatible timing', () {
    final valid = _schema3ChunkEvent(
      endTimeMs: 3000,
      durationMs: 2000,
      frameCount: 1,
    );
    expect(NativeCaptureEvent.fromMap(valid), isA<NativeChunkCompletedEvent>());
    for (final event in <Map<Object?, Object?>>[
      _schema3ChunkEvent(startTimeMs: 3000, endTimeMs: 1000),
      _schema3ChunkEvent(endTimeMs: 3000, durationMs: 1999),
      _schema3ChunkEvent(endTimeMs: 61001, durationMs: 60001),
    ]) {
      expect(() => NativeCaptureEvent.fromMap(event), throwsFormatException);
    }
  });

  test('rejects legacy scope on a newly completed native event', () {
    expect(
      () => NativeCaptureEvent.fromMap(<Object?, Object?>{
        'type': 'chunkCompleted',
        'schemaVersion': 3,
        'captureScope': 'all-displays',
      }),
      throwsFormatException,
    );
  });

  test('parses explicit tray recording commands and rejects unknown ones', () {
    final start = NativeCaptureEvent.fromMap(<Object?, Object?>{
      'type': 'trayCommand',
      'command': 'startCapture',
    });
    final stop = NativeCaptureEvent.fromMap(<Object?, Object?>{
      'type': 'trayCommand',
      'command': 'stopCapture',
    });

    expect(
      start,
      isA<NativeTrayCommandEvent>().having(
        (event) => event.command,
        'command',
        NativeTrayCommand.startCapture,
      ),
    );
    expect(
      stop,
      isA<NativeTrayCommandEvent>().having(
        (event) => event.command,
        'command',
        NativeTrayCommand.stopCapture,
      ),
    );
    expect(
      () => NativeCaptureEvent.fromMap(<Object?, Object?>{
        'type': 'trayCommand',
        'command': 'toggleCapture',
      }),
      throwsFormatException,
    );
  });

  test('1920x1080 contain layout preserves common display ratios', () {
    expect(
      calculateCaptureContentLayout(sourceWidth: 1920, sourceHeight: 1080),
      isA<CaptureContentLayout>()
          .having((layout) => layout.left, 'left', 0)
          .having((layout) => layout.top, 'top', 0)
          .having((layout) => layout.width, 'width', 1920)
          .having((layout) => layout.height, 'height', 1080),
    );
    expect(
      calculateCaptureContentLayout(sourceWidth: 1920, sourceHeight: 1200),
      isA<CaptureContentLayout>()
          .having((layout) => layout.left, 'left', 96)
          .having((layout) => layout.top, 'top', 0)
          .having((layout) => layout.width, 'width', 1728)
          .having((layout) => layout.height, 'height', 1080),
    );
    expect(
      calculateCaptureContentLayout(sourceWidth: 1600, sourceHeight: 1200),
      isA<CaptureContentLayout>()
          .having((layout) => layout.left, 'left', 240)
          .having((layout) => layout.top, 'top', 0)
          .having((layout) => layout.width, 'width', 1440)
          .having((layout) => layout.height, 'height', 1080),
    );
    expect(
      calculateCaptureContentLayout(sourceWidth: 1080, sourceHeight: 1920),
      isA<CaptureContentLayout>()
          .having((layout) => layout.left, 'left', 656)
          .having((layout) => layout.top, 'top', 0)
          .having((layout) => layout.width, 'width', 608)
          .having((layout) => layout.height, 'height', 1080),
    );
  });

  test('regular chunks use interval counts but elapsed-time boundaries', () {
    expect(
      <int>[1, 10, 20, 30]
          .map(
            (interval) => calculateRegularChunkFrameCount(
              captureIntervalSeconds: interval,
            ),
          )
          .toList(),
      <int>[60, 6, 3, 2],
    );
    expect(hasReachedRegularChunkBoundary(elapsedMilliseconds: 59999), isFalse);
    expect(hasReachedRegularChunkBoundary(elapsedMilliseconds: 60000), isTrue);
  });

  test(
    'native logging configuration sends only non-sensitive fields',
    () async {
      const channel = MethodChannel('qi_day_flow/test/native-logging');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? receivedCall;
      messenger.setMockMethodCallHandler(channel, (call) async {
        receivedCall = call;
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = NativeCaptureService(methodChannel: channel);

      await service.configureLogging(
        level: AppLogLevel.debug,
        logDirectory: r'C:\QiDayFlow\logs',
        maxBytes: 1024 * 1024,
        maxBackups: 3,
      );

      expect(receivedCall?.method, 'configureLogging');
      expect(receivedCall?.arguments, <String, Object>{
        'level': 'DEBUG',
        'logDirectory': r'C:\QiDayFlow\logs',
        'maxBytes': 1024 * 1024,
        'maxBackups': 3,
      });
    },
  );

  test('tray state and logger close use narrow native methods', () async {
    const channel = MethodChannel('qi_day_flow/test/native-runtime-state');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = NativeCaptureService(methodChannel: channel);

    await service.updateTrayCaptureState(NativeTrayCaptureState.recording);
    await service.closeLogging();

    expect(calls, hasLength(2));
    expect(calls.first.method, 'updateTrayCaptureState');
    expect(calls.first.arguments, <String, Object>{'state': 'recording'});
    expect(calls.last.method, 'closeLogging');
    expect(calls.last.arguments, isNull);
  });

  test('extractVideoFrames returns bounded Uint8List frames', () async {
    const channel = MethodChannel('qi_day_flow/test/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? receivedCall;
    messenger.setMockMethodCallHandler(channel, (call) async {
      receivedCall = call;
      return <Object?>[
        <String, Object?>{
          'offsetMs': 0,
          'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
        },
        <String, Object?>{
          'offsetMs': 1000,
          'jpegBytes': Uint8List.fromList(<int>[0xFF, 0xD8, 0xFE, 0xFF, 0xD9]),
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = NativeCaptureService(methodChannel: channel);

    final frames = await service.extractVideoFrames(
      videoPath: r'C:\captures\session_42\chunk_1\chunk_1.mp4',
      captureRoot: r'C:\captures\session_42\chunk_1',
      expectedFrameCount: 60,
    );

    expect(frames, hasLength(2));
    expect(frames.last.offsetMs, 1000);
    expect(frames.first.jpegBytes, isA<Uint8List>());
    expect(receivedCall?.method, 'extractVideoFrames');
    final arguments = receivedCall?.arguments as Map<Object?, Object?>;
    expect(arguments['maxFrames'], 8);
    expect(arguments['maxWidth'], 1920);
    expect(arguments['maxHeight'], 1080);
    expect(arguments['jpegQuality'], 85);
    expect(arguments['maxFrameBytes'], 2 * 1024 * 1024);
    expect(arguments['maxTotalBytes'], 12 * 1024 * 1024);
  });

  test('extractVideoFrames rejects limits before calling native code', () {
    final service = NativeCaptureService(
      methodChannel: const MethodChannel('qi_day_flow/test/unused'),
    );

    expect(
      () => service.extractVideoFrames(
        videoPath: r'C:\captures\chunk_1.mp4',
        captureRoot: r'C:\captures',
        expectedFrameCount: 60,
        maxFrames: 9,
      ),
      throwsArgumentError,
    );
  });

  test(
    'executable icon validates arguments and caches the native Future',
    () async {
      const channel = MethodChannel('qi_day_flow/test/executable-icon');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'getExecutableIcon');
        expect(call.arguments, <String, Object>{
          'executablePath': r'C:\Apps\Editor.exe',
          'size': 32,
        });
        return Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ]);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = NativeCaptureService(methodChannel: channel);

      final first = await service.getExecutableIcon(r'C:\Apps\Editor.exe');
      final second = await service.getExecutableIcon(r'C:\Apps\Editor.exe');

      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      expect(calls, 1);
      expect(
        () => service.getExecutableIcon(r'.\Editor.exe'),
        throwsArgumentError,
      );
      expect(
        () => service.getExecutableIcon(r'C:\Apps\notes.txt'),
        throwsArgumentError,
      );
      expect(
        () => service.getExecutableIcon(r'C:\Apps\Editor.exe', size: 64),
        throwsArgumentError,
      );
    },
  );

  test(
    'Explorer selection passes a structured absolute executable path',
    () async {
      const channel = MethodChannel('qi_day_flow/test/explorer');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'revealExecutableInExplorer');
        expect(call.arguments, <String, Object>{
          'executablePath': r'C:\Program Files\Editor\Editor.exe',
        });
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = NativeCaptureService(methodChannel: channel);

      expect(
        await service.revealExecutableInExplorer(
          r'C:\Program Files\Editor\Editor.exe',
        ),
        isTrue,
      );
      await expectLater(
        () => service.revealExecutableInExplorer('Editor.exe'),
        throwsArgumentError,
      );
    },
  );

  test(
    'directory Explorer request uses the exact method and path map',
    () async {
      const channel = MethodChannel('qi_day_flow/test/open-directory');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'openDirectoryInExplorer');
        expect(call.arguments, <String, Object>{
          'directoryPath': r'C:\QiDayFlow',
        });
        return calls == 1 ? <String, Object>{'opened': true} : true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = NativeCaptureService(methodChannel: channel);

      expect(await service.openDirectoryInExplorer(r'C:\QiDayFlow'), isTrue);
      expect(await service.openDirectoryInExplorer(r'C:\QiDayFlow'), isTrue);
      expect(calls, 2);
    },
  );

  test('directory Explorer request rejects a relative Windows path', () async {
    final service = NativeCaptureService(
      methodChannel: const MethodChannel('qi_day_flow/test/unused-directory'),
    );

    await expectLater(
      service.openDirectoryInExplorer(r'.\QiDayFlow'),
      throwsArgumentError,
    );
  });

  test('directory Explorer request rejects an embedded NUL', () async {
    final service = NativeCaptureService(
      methodChannel: const MethodChannel(
        'qi_day_flow/test/unused-nul-directory',
      ),
    );

    await expectLater(
      service.openDirectoryInExplorer('C:\\QiDayFlow\u0000\\elsewhere'),
      throwsArgumentError,
    );
  });
}

Map<Object?, Object?> _schema4ChunkEvent({
  int startTimeMs = 1000,
  int endTimeMs = 61000,
  int durationMs = 60000,
  int captureIntervalSeconds = 30,
  int frameCount = 2,
}) => <Object?, Object?>{
  'type': 'chunkCompleted',
  'schemaVersion': 4,
  'captureScope': 'active-window-display',
  'captureIntervalSeconds': captureIntervalSeconds,
  'sessionId': '42',
  'chunkId': 'chunk_42_1000_strict',
  'directoryPath': r'C:\captures',
  'videoPath': r'C:\captures\chunk_42_1000_strict.mp4',
  'metadataPath': r'C:\captures\chunk_42_1000_strict.json',
  'startTimeMs': startTimeMs,
  'endTimeMs': endTimeMs,
  'durationMs': durationMs,
  'frameCount': frameCount,
  'videoWidth': 1920,
  'videoHeight': 1080,
  'videoFrameRateNumerator': 1,
  'videoFrameRateDenominator': captureIntervalSeconds,
  'videoFrameDurationTicks': captureIntervalSeconds * 10000000,
  'windowRecords': <Object?>[],
};

Map<Object?, Object?> _schema3ChunkEvent({
  int startTimeMs = 1000,
  int endTimeMs = 61000,
  int? durationMs,
  int frameCount = 60,
}) {
  final event = <Object?, Object?>{
    'type': 'chunkCompleted',
    'schemaVersion': 3,
    'captureScope': 'active-window-display',
    'sessionId': '42',
    'chunkId': 'chunk_42_1000_legacy',
    'directoryPath': r'C:\captures',
    'videoPath': r'C:\captures\chunk_42_1000_legacy.mp4',
    'metadataPath': r'C:\captures\chunk_42_1000_legacy.json',
    'startTimeMs': startTimeMs,
    'endTimeMs': endTimeMs,
    'frameCount': frameCount,
    'videoWidth': 1920,
    'videoHeight': 1080,
    'windowRecords': <Object?>[],
  };
  if (durationMs != null) {
    event['durationMs'] = durationMs;
  }
  return event;
}
