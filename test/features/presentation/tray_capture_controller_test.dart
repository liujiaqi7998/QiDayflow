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

  static Future<_ControllerHarness> create() async {
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

  @override
  Stream<NativeCaptureEvent> get events => _events.stream;

  void emitTray(NativeTrayCommand command) {
    _events.add(NativeTrayCommandEvent(command: command));
  }

  void emitState(NativeCaptureStatus status) {
    _events.add(NativeCaptureStateEvent(status: status));
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
  }

  Future<void> close() => _events.close();
}
