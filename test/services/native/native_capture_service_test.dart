import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/services/native/capture_video_spec.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('capture configuration uses the fixed active-display video spec', () {
    const configuration = NativeCaptureConfiguration(
      outputDirectory: r'C:\QiDayFlow\captures',
      sessionId: '42',
    );

    expect(configuration.toMap(), <String, Object>{
      'outputDirectory': r'C:\QiDayFlow\captures',
      'sessionId': '42',
      'fps': 1,
      'chunkDurationSeconds': 60,
      'maxWidth': 1920,
      'maxHeight': 1080,
      'idlePauseEnabled': true,
      'idleTimeoutSeconds': 600,
    });
    expect(configuration.toMap().containsKey('displayId'), isFalse);
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
    expect(chunk.windowRecords, hasLength(2));
    expect(chunk.windowRecords.first.timestampMs, 1000);
    expect(chunk.windowRecords.first.processId, 42);
    expect(chunk.windowRecords.first.cpuUsagePercent, isNull);
    expect(chunk.windowRecords.first.memoryCommitBytes, 256 * 1024 * 1024);
    expect(chunk.windowRecords.last.cpuUsagePercent, 12.5);
    expect(chunk.windowRecords.last.memoryCommitBytes, isNull);
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

  test('regular chunks rotate exactly at the sixtieth frame', () {
    expect(calculateRegularChunkFrameCount(), 60);
    expect(hasReachedRegularChunkBoundary(59), isFalse);
    expect(hasReachedRegularChunkBoundary(60), isTrue);
    expect(hasReachedRegularChunkBoundary(61), isTrue);
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
}
