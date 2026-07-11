import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/core/utils/formatters.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/services/logging/app_logger.dart';
import 'package:qi_day_flow/services/native/capture_video_spec.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'card edit refreshes timeline/statistics/report and proxies native tools',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qi_day_flow_controller_test_',
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
        'qi_day_flow/test/controller-methods',
      );
      const eventChannel = EventChannel('qi_day_flow/test/controller-events');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        nativeCalls.add(call);
        return switch (call.method) {
          'getExecutableIcon' => Uint8List.fromList(<int>[
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ]),
          'revealExecutableInExplorer' => true,
          _ => null,
        };
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('qi_day_flow/test/controller-events'),
        (_) async => null,
      );

      final native = NativeCaptureService(
        methodChannel: methodChannel,
        eventChannel: eventChannel,
      );
      final settingsService = SecureSettingsService(
        repository: repository,
        platform: native,
        defaultCaptureDirectory: captureDirectory.path,
      );
      final appLogger = AppLogger(logDirectory: p.join(root.path, 'logs'));
      final controller = AppController(
        database: database,
        repository: repository,
        nativeService: native,
        settingsService: settingsService,
        logger: appLogger,
      );
      addTearDown(() async {
        controller.dispose();
        await appLogger.close();
        await database.close();
        messenger.setMockMethodCallHandler(methodChannel, null);
        messenger.setMockMethodCallHandler(
          const MethodChannel('qi_day_flow/test/controller-events'),
          null,
        );
        await root.delete(recursive: true);
      });

      final now = DateTime.now();
      final localStart = DateTime(now.year, now.month, now.day, 9);
      final startMs = localStart.toUtc().millisecondsSinceEpoch;
      final session = await repository.createSession(
        CaptureSession(
          captureScope: activeWindowDisplayCaptureScope,
          captureDirectory: captureDirectory.path,
          startedAtMs: startMs,
          endedAtMs: startMs + Duration.millisecondsPerHour,
          status: CaptureSessionStatus.stopped,
          createdAtMs: startMs,
          updatedAtMs: startMs,
        ),
      );
      final chunk = await repository.addChunk(
        CaptureChunk(
          sessionId: session.id!,
          framesDirectory: captureDirectory.path,
          metadataPath: p.join(captureDirectory.path, 'chunk.json'),
          startedAtMs: startMs,
          endedAtMs: startMs + Duration.millisecondsPerHour,
          frameCount: 1,
          createdAtMs: startMs,
          updatedAtMs: startMs,
        ),
      );
      final batch = await repository.claimChunksForAnalysis([chunk.id!]);
      final reportDate = formatIsoDate(localStart);
      final commit = await repository.completeAnalysis(
        batchId: batch.id!,
        observations: [
          Observation(
            batchId: batch.id,
            chunkId: chunk.id!,
            startedAtMs: startMs,
            endedAtMs: startMs + Duration.millisecondsPerHour,
            description: '编辑控制器',
            appName: 'Editor',
            processName: 'Editor.exe',
            processPath: r'C:\Apps\Editor.exe',
            createdAtMs: startMs,
          ),
        ],
        cards: [
          TimelineCard(
            batchId: batch.id,
            reportDate: reportDate,
            category: '工作',
            title: '旧标题',
            summary: '旧摘要',
            startedAtMs: startMs,
            endedAtMs: startMs + Duration.millisecondsPerHour,
            appUsages: [
              AppUsage(
                name: 'Editor',
                durationMs: Duration.millisecondsPerHour,
                executablePath: r'C:\Apps\Editor.exe',
                averageCpuUsagePercent: 12.5,
                peakCpuUsagePercent: 25,
                averageMemoryCommitBytes: 384 * 1024 * 1024,
                peakMemoryCommitBytes: 512 * 1024 * 1024,
              ),
            ],
            distractions: const [],
            productivityScore: 50,
            createdAtMs: startMs,
            updatedAtMs: startMs,
          ),
        ],
      );
      await repository.saveDailyReport(
        reportDate: reportDate,
        content: '缓存日报',
        model: 'test-model',
      );

      await controller.initialize();
      expect(controller.settings.logLevel, AppLogLevel.info);
      await controller.updateLogLevel(AppLogLevel.debug);
      expect(controller.settings.logLevel, AppLogLevel.debug);
      expect(appLogger.level, AppLogLevel.debug);
      expect((await settingsService.load()).logLevel, AppLogLevel.debug);
      final loggingCall = nativeCalls.lastWhere(
        (call) => call.method == 'configureLogging',
      );
      expect(loggingCall.arguments, containsPair('level', 'DEBUG'));
      expect(controller.timelineCards.single.title, '旧标题');
      expect(controller.statistics.weightedProductivity, 50);
      expect(controller.dailyReport, isNull);

      await controller.updateTimelineCard(
        TimelineCardEditDraft(
          id: commit.cardIds.single.toString(),
          category: '编程',
          title: '新标题',
          summary: '',
          productivityScore: 90,
        ),
      );

      expect(controller.timelineCards.single.title, '新标题');
      expect(
        controller.timelineCards.single.appUsages.single.executablePath,
        r'C:\Apps\Editor.exe',
      );
      final viewUsage = controller.timelineCards.single.appUsages.single;
      expect(viewUsage.averageCpuUsagePercent, 12.5);
      expect(viewUsage.peakCpuUsagePercent, 25);
      expect(viewUsage.averageMemoryCommitBytes, 384 * 1024 * 1024);
      expect(viewUsage.peakMemoryCommitBytes, 512 * 1024 * 1024);
      expect(controller.statistics.weightedProductivity, 90);
      expect((await repository.getDailyReport(reportDate))?.isStale, isTrue);
      expect(controller.dailyReport, isNull);

      await controller.updateDailyGoalHours(10);
      expect(controller.statistics.dailyGoalHours, 10);
      expect(await settingsService.loadDailyGoalHours(), 10);
      expect(await controller.loadApiKeyForEditing(), '');

      final nextUserDataDirectory = p.join(root.path, 'next-data');
      await controller.saveSettings(
        SettingsDraft(
          apiUrl: controller.settings.apiUrl,
          apiKey: '',
          model: controller.settings.model,
          userDataDirectory: nextUserDataDirectory,
          cacheLimitGb: controller.settings.cacheLimitGb,
          idlePauseEnabled: controller.settings.idlePauseEnabled,
          idleTimeoutMinutes: controller.settings.idleTimeoutMinutes,
          themeMode: controller.settings.themeMode,
        ),
      );
      expect(controller.settings.userDataDirectory, nextUserDataDirectory);
      expect(controller.settings.dataDirectoryRestartRequired, isTrue);

      expect(
        await controller.loadApplicationIcon(r'C:\Apps\Editor.exe'),
        isNotNull,
      );
      await controller.revealExecutableInExplorer(r'C:\Apps\Editor.exe');
      expect(
        nativeCalls.map((call) => call.method),
        containsAll(<String>[
          'getExecutableIcon',
          'revealExecutableInExplorer',
        ]),
      );

      await controller.startCapture();
      final activeSession = await repository.getActiveSession();
      expect(activeSession?.captureScope, activeWindowDisplayCaptureScope);
      final startCall = nativeCalls.lastWhere(
        (call) => call.method == 'startCapture',
      );
      expect(
        startCall.arguments,
        containsPair(
          'outputDirectory',
          p.windows.join(nextUserDataDirectory, 'captures'),
        ),
      );
      expect(startCall.arguments, containsPair('fps', 1));
      expect(startCall.arguments, containsPair('chunkDurationSeconds', 60));
      expect(startCall.arguments, containsPair('maxWidth', 1920));
      expect(startCall.arguments, containsPair('maxHeight', 1080));
      await controller.stopCapture();
    },
  );
}
