import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'tray commands route only stable states through the controller',
    () async {
      final harness = await _ControllerHarness.create();
      addTearDown(harness.dispose);
      await harness.controller.initialize();

      harness.native.emitTray(NativeTrayCommand.startCapture);
      await _waitFor(
        () =>
            harness.controller.recordingStatus == RecordingViewStatus.recording,
      );
      expect(harness.native.startCalls, 1);
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);

      harness.native.emitState(NativeCaptureStatus.paused);
      await _flushEvents();
      harness.native.emitTray(NativeTrayCommand.stopCapture);
      await _waitFor(
        () => harness.controller.recordingStatus == RecordingViewStatus.stopped,
      );
      expect(harness.native.stopCalls, 1);
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopped);

      harness.native.emitState(NativeCaptureStatus.starting);
      harness.native.emitTray(NativeTrayCommand.stopCapture);
      harness.native.emitState(NativeCaptureStatus.stopping);
      harness.native.emitTray(NativeTrayCommand.stopCapture);
      await _flushEvents();
      expect(harness.native.stopCalls, 1);

      harness.native.failNextStart = true;
      harness.native.emitState(NativeCaptureStatus.error);
      harness.native.emitTray(NativeTrayCommand.startCapture);
      await _waitFor(() => harness.native.startCalls == 2);
      await _waitFor(
        () => harness.controller.recordingStatus == RecordingViewStatus.error,
      );
      expect(harness.native.startCalls, 2);
      expect(harness.controller.recordingStatus, RecordingViewStatus.error);
    },
  );

  test(
    'duplicate tray commands cannot overlap sessions or stop operations',
    () async {
      final harness = await _ControllerHarness.create();
      addTearDown(harness.dispose);
      await harness.controller.initialize();

      final startGate = Completer<void>();
      harness.native.startGate = startGate;
      harness.native.emitTray(NativeTrayCommand.startCapture);
      harness.native.emitTray(NativeTrayCommand.startCapture);
      await _waitFor(() => harness.native.startCalls > 0);
      expect(harness.native.startCalls, 1);
      expect(harness.controller.recordingStatus, RecordingViewStatus.starting);
      expect(await harness.repository.getActiveSession(), isNotNull);

      startGate.complete();
      await _waitFor(
        () =>
            harness.controller.recordingStatus == RecordingViewStatus.recording,
      );
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);

      final stopGate = Completer<void>();
      harness.native.stopGate = stopGate;
      harness.native.emitTray(NativeTrayCommand.stopCapture);
      harness.native.emitTray(NativeTrayCommand.stopCapture);
      await _waitFor(() => harness.native.stopCalls > 0);
      expect(harness.native.stopCalls, 1);
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopping);

      harness.native.emitState(NativeCaptureStatus.stopped);
      await _flushEvents();
      final stoppedAcknowledgements = harness.native.trayStates
          .where((state) => state == NativeTrayCaptureState.stopped)
          .length;
      harness.native.emitTray(NativeTrayCommand.startCapture);
      await _flushEvents();
      expect(harness.native.startCalls, 1);
      await _waitFor(
        () =>
            harness.native.trayStates
                .where((state) => state == NativeTrayCaptureState.stopped)
                .length >
            stoppedAcknowledgements,
      );

      final acknowledgementsBeforeStopCompleted = harness.native.trayStates
          .where((state) => state == NativeTrayCaptureState.stopped)
          .length;
      stopGate.complete();
      await _waitFor(
        () =>
            harness.native.trayStates
                .where((state) => state == NativeTrayCaptureState.stopped)
                .length >
            acknowledgementsBeforeStopCompleted,
      );
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopped);
      expect(
        harness.native.trayStates,
        containsAllInOrder(<NativeTrayCaptureState>[
          NativeTrayCaptureState.stopped,
          NativeTrayCaptureState.starting,
          NativeTrayCaptureState.recording,
          NativeTrayCaptureState.stopping,
          NativeTrayCaptureState.stopped,
        ]),
      );
    },
  );

  test(
    'stop waits for the native stopped event without blocking its request',
    () async {
      final harness = await _ControllerHarness.create();
      addTearDown(harness.dispose);
      await harness.controller.initialize();
      await harness.controller.startCapture();
      harness.native.autoEmitStopped = false;

      var completed = false;
      final stop = harness.controller.stopCapture().whenComplete(() {
        completed = true;
      });
      await _waitFor(() => harness.native.stopCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(harness.controller.recordingStatus, RecordingViewStatus.stopping);
      expect(completed, isFalse);
      harness.native.emitState(NativeCaptureStatus.stopped);
      await stop;
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopped);
    },
  );

  test(
    'non-recoverable native stop error completes without an async leak',
    () async {
      final harness = await _ControllerHarness.create();
      addTearDown(harness.dispose);
      await harness.controller.initialize();
      await harness.controller.startCapture();
      harness.native.autoEmitStopped = false;

      final stop = harness.controller.stopCapture();
      await _waitFor(() => harness.native.stopCalls == 1);
      harness.native.emitError('finalize failed');
      await stop;

      expect(harness.controller.recordingStatus, RecordingViewStatus.error);
      expect(harness.controller.statusMessage, contains('finalize failed'));
    },
  );

  test(
    'stop timeout reports an error and a late stopped event recovers',
    () async {
      final harness = await _ControllerHarness.create(
        stopTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(harness.dispose);
      await harness.controller.initialize();
      await harness.controller.startCapture();
      harness.native.autoEmitStopped = false;

      await harness.controller.stopCapture();

      expect(harness.controller.recordingStatus, RecordingViewStatus.error);
      expect(harness.controller.statusMessage, contains('停止采集失败'));
      harness.native.emitState(NativeCaptureStatus.stopped);
      await _flushEvents();
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopped);
    },
  );

  test('native state query cannot clear a timed-out stop tombstone', () async {
    final harness = await _ControllerHarness.create(
      stopTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(harness.dispose);
    await harness.controller.initialize();
    await harness.controller.startCapture();
    harness.native.autoEmitStopped = false;
    harness.native.queriedStatus = NativeCaptureStatus.stopped;

    await harness.controller.stopCapture();
    await harness.controller.startCapture();

    expect(harness.native.stateQueries, 0);
    expect(harness.native.startCalls, 1);
    expect(harness.controller.recordingStatus, RecordingViewStatus.error);

    harness.native.emitState(NativeCaptureStatus.stopped);
    await _flushEvents();
    await harness.controller.startCapture();

    expect(harness.native.startCalls, 2);
    expect(harness.controller.recordingStatus, RecordingViewStatus.recording);
  });

  test(
    'fatal error followed by stopped finalizes the active session',
    () async {
      final harness = await _ControllerHarness.create();
      addTearDown(harness.dispose);
      await harness.controller.initialize();
      await harness.controller.startCapture();

      harness.native.emitError('capture pipeline failed');
      harness.native.emitState(NativeCaptureStatus.stopped);
      await _flushEvents();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await harness.controller.startCapture();

      expect(harness.native.startCalls, 2);
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);
    },
  );

  test(
    'late old session events cannot unblock or overwrite a newer session',
    () async {
      final harness = await _ControllerHarness.create(
        stopTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(harness.dispose);
      await harness.controller.initialize();
      await harness.controller.startCapture();
      final oldSessionId = harness.native.currentSessionId!;
      harness.native.autoEmitStopped = false;

      await harness.controller.stopCapture();
      expect(harness.controller.recordingStatus, RecordingViewStatus.error);

      await harness.controller.startCapture();
      expect(harness.native.startCalls, 1);

      harness.native.emitState(
        NativeCaptureStatus.stopped,
        sessionId: oldSessionId,
      );
      await _flushEvents();
      await harness.controller.startCapture();
      final newSessionId = harness.native.currentSessionId!;
      expect(harness.native.startCalls, 2);
      expect(newSessionId, isNot(oldSessionId));
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);

      harness.native.emitState(
        NativeCaptureStatus.stopped,
        sessionId: oldSessionId,
      );
      harness.native.emitError('late old failure', sessionId: oldSessionId);
      await _flushEvents();
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);
      expect(
        harness.controller.statusMessage,
        isNot(contains('late old failure')),
      );

      var stopCompleted = false;
      final stop = harness.controller.stopCapture().whenComplete(() {
        stopCompleted = true;
      });
      await _waitFor(() => harness.native.stopCalls == 2);
      harness.native.emitState(
        NativeCaptureStatus.stopped,
        sessionId: oldSessionId,
      );
      await _flushEvents();
      expect(stopCompleted, isFalse);
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopping);

      harness.native.emitState(
        NativeCaptureStatus.stopped,
        sessionId: newSessionId,
      );
      await stop;
      expect(harness.controller.recordingStatus, RecordingViewStatus.stopped);
    },
  );

  test(
    'matching fatal error clears a timed-out native stop tombstone',
    () async {
      final harness = await _ControllerHarness.create(
        stopTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(harness.dispose);
      await harness.controller.initialize();
      await harness.controller.startCapture();
      final stoppedSessionId = harness.native.currentSessionId!;
      harness.native.autoEmitStopped = false;

      await harness.controller.stopCapture();
      await harness.controller.startCapture();
      expect(harness.native.startCalls, 1);

      harness.native.emitError(
        'late fatal stop failure',
        sessionId: stoppedSessionId,
      );
      await _flushEvents();
      await harness.controller.startCapture();

      expect(harness.native.startCalls, 2);
      expect(harness.controller.recordingStatus, RecordingViewStatus.recording);
    },
  );

  test('tray callbacks are ignored after controller disposal', () async {
    final harness = await _ControllerHarness.create();
    await harness.controller.initialize();
    harness.controller.dispose();

    harness.native.emitTray(NativeTrayCommand.startCapture);
    await _flushEvents();

    expect(harness.native.startCalls, 0);
    await harness.dispose(disposeController: false);
  });
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('controller condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _ControllerHarness {
  _ControllerHarness({
    required this.root,
    required this.database,
    required this.repository,
    required this.native,
    required this.controller,
  });

  static Future<_ControllerHarness> create({
    Duration stopTimeout = const Duration(seconds: 15),
  }) async {
    final root = await Directory.systemTemp.createTemp('qi_tray_controller_');
    final captures = Directory(p.join(root.path, 'captures'));
    await captures.create();
    final database = AppDatabase(
      path: p.join(root.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    final native = _FakeNativeCaptureService();
    final controller = AppController(
      database: database,
      repository: repository,
      nativeService: native,
      settingsService: SecureSettingsService(
        repository: repository,
        platform: native,
        defaultCaptureDirectory: captures.path,
      ),
      activeUserDataDirectory: root.path,
      stopTimeout: stopTimeout,
    );
    return _ControllerHarness(
      root: root,
      database: database,
      repository: repository,
      native: native,
      controller: controller,
    );
  }

  final Directory root;
  final AppDatabase database;
  final SqliteDayFlowRepository repository;
  final _FakeNativeCaptureService native;
  final AppController controller;

  Future<void> dispose({bool disposeController = true}) async {
    if (disposeController) controller.dispose();
    await native.close();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _FakeNativeCaptureService extends NativeCaptureService {
  _FakeNativeCaptureService()
    : super(
        methodChannel: const MethodChannel('qi_day_flow/test/tray-unused'),
        eventChannel: const EventChannel('qi_day_flow/test/tray-unused-events'),
      );

  final StreamController<NativeCaptureEvent> _events =
      StreamController<NativeCaptureEvent>.broadcast(sync: true);
  final List<NativeTrayCaptureState> trayStates = <NativeTrayCaptureState>[];
  int startCalls = 0;
  int stopCalls = 0;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  bool failNextStart = false;
  bool autoEmitStopped = true;
  String? currentSessionId;
  NativeCaptureStatus queriedStatus = NativeCaptureStatus.stopping;
  int stateQueries = 0;

  @override
  Stream<NativeCaptureEvent> get events => _events.stream;

  void emitTray(NativeTrayCommand command) {
    _events.add(NativeTrayCommandEvent(command: command));
  }

  void emitState(NativeCaptureStatus status, {String? sessionId}) {
    _events.add(
      NativeCaptureStateEvent(
        status: status,
        sessionId: sessionId ?? currentSessionId!,
      ),
    );
  }

  void emitError(String message, {String? sessionId}) {
    _events.add(
      NativeCaptureErrorEvent(
        code: 'testStopFailure',
        message: message,
        recoverable: false,
        sessionId: sessionId ?? currentSessionId!,
      ),
    );
  }

  @override
  Future<void> configureLogging({
    required AppLogLevel level,
    required String logDirectory,
    int maxBytes = 1024 * 1024,
    int maxBackups = 3,
  }) async {}

  @override
  Future<void> updateTrayCaptureState(NativeTrayCaptureState state) async {
    trayStates.add(state);
  }

  @override
  Future<void> start(NativeCaptureConfiguration configuration) async {
    startCalls++;
    currentSessionId = configuration.sessionId;
    await startGate?.future;
    startGate = null;
    if (failNextStart) {
      failNextStart = false;
      throw StateError('test start failure');
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await stopGate?.future;
    stopGate = null;
    if (autoEmitStopped) emitState(NativeCaptureStatus.stopped);
  }

  @override
  Future<Map<Object?, Object?>> getState() async {
    stateQueries++;
    return <Object?, Object?>{
      'status': queriedStatus.name,
      'sessionId': currentSessionId,
    };
  }

  Future<void> close() => _events.close();
}
