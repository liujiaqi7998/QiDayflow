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
import 'package:qi_day_flow/services/reports/daily_report_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'enqueue returns before generation and background work survives leaving report',
    () async {
      final harness = await _ControllerHarness.create();
      addTearDown(harness.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      harness.reportService.onGenerate = (reportDate) async {
        entered.complete();
        await release.future;
        await harness.repository.saveDailyReport(
          reportDate: reportDate,
          content: '后台日报',
          model: 'fake|daily-v1',
        );
        return '后台日报';
      };
      await harness.initialize();
      harness.controller.selectSection(AppSection.report);

      await harness.controller.generateDailyReport().timeout(
        const Duration(milliseconds: 500),
      );
      harness.controller.selectSection(AppSection.timeline);
      await entered.future.timeout(const Duration(seconds: 2));
      expect(harness.controller.section, AppSection.timeline);
      expect(
        (await harness.repository.getDailyReportJob('2026-07-13'))?.status,
        DailyReportJobStatus.processing,
      );

      release.complete();
      await _waitUntil(
        () async =>
            await harness.repository.getDailyReportJob('2026-07-13') == null,
      );
      expect(
        (await harness.repository.getDailyReport('2026-07-13'))?.content,
        '后台日报',
      );
    },
  );

  test('duplicate generate requests keep one active job', () async {
    final harness = await _ControllerHarness.create();
    addTearDown(harness.close);
    final entered = Completer<void>();
    final release = Completer<void>();
    harness.reportService.onGenerate = (_) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return '日报';
    };
    await harness.initialize();

    await Future.wait(<Future<void>>[
      harness.controller.generateDailyReport(),
      harness.controller.generateDailyReport(),
    ]);
    await entered.future.timeout(const Duration(seconds: 2));
    expect(await harness.repository.listDailyReportJobs(), hasLength(1));
    expect(harness.reportService.generateCalls, 1);

    release.complete();
    await _waitUntil(
      () async =>
          await harness.repository.getDailyReportJob('2026-07-13') == null,
    );
  });

  test('failed report job retries through the shared coordinator', () async {
    final harness = await _ControllerHarness.create();
    addTearDown(harness.close);
    harness.reportService.onGenerate = (reportDate) async {
      if (harness.reportService.generateCalls == 1) {
        throw StateError('Authorization: Bearer provider-secret');
      }
      await harness.repository.saveDailyReport(
        reportDate: reportDate,
        content: '重试成功',
        model: 'fake|daily-v1',
      );
      return '重试成功';
    };
    await harness.initialize();

    await harness.controller.generateDailyReport();
    await _waitUntil(() async {
      final job = await harness.repository.getDailyReportJob('2026-07-13');
      return job?.status == DailyReportJobStatus.failed;
    });
    final failed = await harness.repository.getDailyReportJob('2026-07-13');
    expect(failed?.errorSummary, '日报生成失败，详细信息已隐藏');
    expect(failed?.errorSummary, isNot(contains('provider-secret')));

    await harness.controller.retryFailedChunks();
    await _waitUntil(
      () async =>
          await harness.repository.getDailyReportJob('2026-07-13') == null,
    );
    expect(harness.reportService.generateCalls, 2);
  });

  test('initialize recovers an interrupted report and schedules it', () async {
    final harness = await _ControllerHarness.create();
    addTearDown(harness.close);
    await harness.repository.enqueueDailyReportJob('2026-07-13');
    await harness.repository.claimNextDailyReportJob();
    harness.reportService.onGenerate = (_) async => '恢复成功';

    await harness.initialize();

    await _waitUntil(
      () async =>
          await harness.repository.getDailyReportJob('2026-07-13') == null,
    );
    expect(harness.reportService.generateCalls, 1);
  });

  test('late report load cannot overwrite a newer timeline date', () async {
    final harness = await _ControllerHarness.create();
    addTearDown(harness.close);
    final older = Completer<String?>();
    final newer = Completer<String?>();
    harness.reportService.loadResults['2026-07-11'] = older.future;
    harness.reportService.loadResults['2026-07-12'] = newer.future;
    await harness.initialize();

    final olderLoad = harness.controller.setTimelineDate(DateTime(2026, 7, 11));
    await _waitUntilSync(
      () => harness.reportService.loadCalls.contains('2026-07-11'),
    );
    final newerLoad = harness.controller.setTimelineDate(DateTime(2026, 7, 12));
    await _waitUntilSync(
      () => harness.reportService.loadCalls.contains('2026-07-12'),
    );

    newer.complete('新日期日报');
    await newerLoad;
    older.complete('旧日期迟到日报');
    await olderLoad;

    expect(harness.controller.timelineDate, DateTime(2026, 7, 12));
    expect(harness.controller.dailyReport, '新日期日报');
    expect(harness.controller.reportLoading, isFalse);
  });
}

final class _ControllerHarness {
  _ControllerHarness._({
    required this.root,
    required this.database,
    required this.repository,
    required this.controller,
    required this.reportService,
    required this.methodChannel,
    required this.eventChannel,
  });

  final Directory root;
  final AppDatabase database;
  final SqliteDayFlowRepository repository;
  final AppController controller;
  final _FakeDailyReportService reportService;
  final MethodChannel methodChannel;
  final EventChannel eventChannel;

  static Future<_ControllerHarness> create() async {
    final root = await Directory.systemTemp.createTemp(
      'qi_day_flow_daily_report_controller_test_',
    );
    final database = AppDatabase(
      path: p.join(root.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = SqliteDayFlowRepository(database);
    await database.open();
    final suffix = root.path.hashCode.abs();
    final methodChannel = MethodChannel('qi_day_flow/test/report-$suffix');
    final eventChannel = EventChannel('qi_day_flow/test/report-events-$suffix');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      return switch (call.method) {
        'queryLaunchAtLogin' => false,
        'protectSecret' => 'ciphertext',
        'unprotectSecret' => 'test-api-key',
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      MethodChannel(eventChannel.name),
      (_) async => null,
    );
    final native = NativeCaptureService(
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );
    final settingsService = SecureSettingsService(
      repository: repository,
      platform: native,
      defaultUserDataDirectory: root.path,
    );
    final defaults = await settingsService.load();
    await settingsService.save(defaults, plaintextApiKey: 'test-api-key');
    final reportService = _FakeDailyReportService(repository);
    final controller = AppController(
      database: database,
      repository: repository,
      nativeService: native,
      settingsService: settingsService,
      activeUserDataDirectory: root.path,
      now: () => DateTime(2026, 7, 13, 12),
      dailyReportService: reportService,
    );
    return _ControllerHarness._(
      root: root,
      database: database,
      repository: repository,
      controller: controller,
      reportService: reportService,
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );
  }

  Future<void> initialize() => controller.initialize();

  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMethodCallHandler(MethodChannel(eventChannel.name), null);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _FakeDailyReportService extends DailyReportService {
  _FakeDailyReportService(SqliteDayFlowRepository repository)
    : super(
        timelineRepository: repository,
        reportRepository: repository,
        serviceFactory: () async => throw UnimplementedError(),
        modelName: () async => 'fake',
      );

  final Map<String, Future<String?>> loadResults = <String, Future<String?>>{};
  final List<String> loadCalls = <String>[];
  int generateCalls = 0;
  Future<String> Function(String reportDate)? onGenerate;

  @override
  Future<String?> loadFresh(String reportDate) {
    loadCalls.add(reportDate);
    return loadResults[reportDate] ?? Future<String?>.value();
  }

  @override
  Future<String> generate(String reportDate) {
    generateCalls++;
    return onGenerate?.call(reportDate) ?? Future<String>.value('日报');
  }
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for state');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _waitUntilSync(bool Function() condition) async {
  await _waitUntil(() async => condition());
}
