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

  test('safe analysis error summary categorizes and hides sensitive text', () {
    final base64 = List<String>.filled(100, 'QUJD').join();
    final summary = safeAnalysisErrorSummary(
      'AnalysisException.network: Authorization: Bearer top-secret '
      'apiKey=test-key-placeholder request payload={"windowTitle":'
      '"Payroll - Alice","image":"data:image/jpeg;base64,/9j/$base64"} '
      r'C:\private\captures\chunk-1.mp4',
    );

    expect(summary, '网络连接失败');
    for (final secret in <String>[
      'top-secret',
      'test-key-placeholder',
      'Authorization',
      'payload',
      'Payroll',
      'data:image',
      '/9j/',
      base64,
      r'C:\private\captures\chunk-1.mp4',
    ]) {
      expect(summary, isNot(contains(secret)));
    }
    expect(
      safeAnalysisErrorSummary(
        'windowTitle=Confidential board meeting',
        maxLength: 12,
      ).length,
      lessThanOrEqualTo(12),
    );
    expect(
      safeAnalysisErrorSummary('totally unknown provider response'),
      '分析失败，详细信息已隐藏',
    );
  });

  test(
    'controller refresh maps the real queue and section selection reloads it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_queue_controller_test_',
      );
      final captureDirectory = Directory(p.join(root.path, 'captures'));
      await captureDirectory.create();
      final database = AppDatabase(
        path: p.join(root.path, 'dayflow.db'),
        databaseFactory: databaseFactoryFfi,
      );
      final repository = SqliteDayFlowRepository(database);
      await database.open();

      const methodChannel = MethodChannel(
        'qi_day_flow/test/queue-controller-methods',
      );
      const eventChannel = EventChannel(
        'qi_day_flow/test/queue-controller-events',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methodChannel, (_) async => null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('qi_day_flow/test/queue-controller-events'),
        (_) async => null,
      );
      final native = NativeCaptureService(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );
      final controller = AppController(
        database: database,
        repository: repository,
        nativeService: native,
        settingsService: SecureSettingsService(
          repository: repository,
          platform: native,
          defaultCaptureDirectory: captureDirectory.path,
        ),
      );
      addTearDown(() async {
        controller.dispose();
        await database.close();
        messenger.setMockMethodCallHandler(methodChannel, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('qi_day_flow/test/queue-controller-events'),
          null,
        );
        await root.delete(recursive: true);
      });

      await controller.initialize();
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final session = await repository.createSession(
        CaptureSession(
          captureScope: 'active-window-display',
          captureDirectory: captureDirectory.path,
          startedAtMs: now,
          endedAtMs: now + 900000,
          status: CaptureSessionStatus.stopped,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      );
      final pending = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'pending',
        startedAtMs: now + 60000,
        createdAtMs: now + 10,
      );
      final processingChunk = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'processing',
        startedAtMs: now + 120000,
        createdAtMs: now + 20,
      );
      final processingBatch = await repository.claimChunksForAnalysis([
        processingChunk.id!,
      ]);
      final failedChunk = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'failed',
        startedAtMs: now + 180000,
        createdAtMs: now + 30,
      );
      final failedBatch = await repository.claimChunksForAnalysis([
        failedChunk.id!,
      ]);
      await repository.markAnalysisFailed(
        failedBatch.id!,
        'AnalysisException.network: Authorization: Bearer secret-token '
        'windowTitle=Private roadmap',
      );
      await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'completed',
        startedAtMs: now + 240000,
        createdAtMs: now + 40,
        status: ProcessingStatus.completed,
      );

      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.refreshAnalysisQueue();

      expect(controller.analysisQueue.items.map((item) => item.chunkId), <int>[
        processingChunk.id!,
        pending.id!,
        failedChunk.id!,
      ]);
      expect(controller.analysisQueue.processingCount, 1);
      expect(controller.analysisQueue.pendingCount, 1);
      expect(controller.analysisQueue.failedCount, 1);
      expect(controller.pendingChunkCount, 2);
      expect(controller.failedChunkCount, 1);
      expect(notifications, greaterThan(0));

      final processing = controller.analysisQueue.items.first;
      expect(processing.batchId, processingBatch.id);
      expect(processing.recordedAt, isNotNull);
      expect(processing.recordingDuration, const Duration(minutes: 1));
      expect(processing.processingStartedAt, isNotNull);
      expect(processing.enqueuedAt, isNotNull);
      expect(processing.retryCount, 0);
      expect(processing.errorSummary, isNull);
      expect(controller.analysisQueue.items.last.errorSummary, '网络连接失败');

      final nextPending = await _addChunk(
        repository,
        sessionId: session.id!,
        suffix: 'next-pending',
        startedAtMs: now + 300000,
        createdAtMs: now + 50,
      );
      controller.selectSection(AppSection.analysisQueue);
      await _waitUntil(
        () => controller.analysisQueue.items.any(
          (item) => item.chunkId == nextPending.id,
        ),
      );

      expect(controller.section, AppSection.analysisQueue);
      expect(controller.analysisQueue.pendingCount, 2);
      expect(controller.pendingChunkCount, 3);
    },
  );
}

Future<CaptureChunk> _addChunk(
  SqliteDayFlowRepository repository, {
  required int sessionId,
  required String suffix,
  required int startedAtMs,
  required int createdAtMs,
  ProcessingStatus status = ProcessingStatus.pending,
}) {
  return repository.addChunk(
    CaptureChunk(
      sessionId: sessionId,
      framesDirectory: 'C:/test-only/$suffix',
      metadataPath: 'C:/test-only/$suffix/metadata.json',
      videoPath: 'C:/test-only/$suffix/video.mp4',
      startedAtMs: startedAtMs,
      endedAtMs: startedAtMs + 60000,
      frameCount: 5,
      status: status,
      completedAtMs: status == ProcessingStatus.completed
          ? startedAtMs + 60000
          : null,
      createdAtMs: createdAtMs,
      updatedAtMs: createdAtMs,
    ),
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for controller refresh');
}
