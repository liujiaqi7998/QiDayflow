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

  late Directory root;
  late AppDatabase database;
  late SqliteDayFlowRepository repository;
  late NativeCaptureService native;
  late SecureSettingsService settingsService;
  late _FakeDailyReportService reportService;
  late AppController controller;
  const methodChannel = MethodChannel('qi_day_flow/test/report-controller');
  const eventChannel = EventChannel(
    'qi_day_flow/test/report-controller-events',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'qi_day_flow_report_controller_test_',
    );
    database = AppDatabase(
      path: p.join(root.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    repository = SqliteDayFlowRepository(database);
    await database.open();
    await repository.putSetting('api_key_ciphertext', 'test-ciphertext');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, (_) async => null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('qi_day_flow/test/report-controller-events'),
      (_) async => null,
    );
    native = NativeCaptureService(
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );
    settingsService = SecureSettingsService(
      repository: repository,
      platform: native,
      defaultCaptureDirectory: p.join(root.path, 'captures'),
    );
    reportService = _FakeDailyReportService(repository);
    controller = AppController(
      database: database,
      repository: repository,
      nativeService: native,
      settingsService: settingsService,
      dailyReportService: reportService,
      now: () => DateTime(2026, 7, 13, 12),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('qi_day_flow/test/report-controller-events'),
      null,
    );
    await root.delete(recursive: true);
  });

  test(
    'enqueue returns before AI and leaving report does not stop work',
    () async {
      reportService.loaded['2026-07-13'] = '旧日报';
      final generationStarted = Completer<void>();
      final generationRelease = Completer<void>();
      reportService.onGenerate = (date) async {
        generationStarted.complete();
        await generationRelease.future;
        reportService.loaded[date] = '新日报';
      };
      await controller.initialize();
      controller.selectSection(AppSection.report);
      await _waitUntil(() => controller.dailyReport == '旧日报');

      await controller.generateDailyReport().timeout(
        const Duration(milliseconds: 500),
      );
      await generationStarted.future.timeout(const Duration(seconds: 2));
      expect(controller.reportLoading, isTrue);
      expect(controller.dailyReport, '旧日报');

      controller.selectSection(AppSection.timeline);
      generationRelease.complete();
      await _waitUntil(
        () async => await repository.getDailyReportJob('2026-07-13') == null,
      );
      controller.selectSection(AppSection.report);
      await _waitUntil(() => controller.dailyReport == '新日报');
    },
  );

  test('generate retries a failed report job from the report page', () async {
    await repository.enqueueDailyReportJob('2026-07-13');
    await repository.claimNextDailyReportJob();
    await repository.markDailyReportJobFailed(
      '2026-07-13',
      category: 'provider',
      summary: '服务暂时不可用',
    );
    final generationStarted = Completer<void>();
    final generationRelease = Completer<void>();
    reportService.onGenerate = (_) async {
      generationStarted.complete();
      await generationRelease.future;
    };
    await controller.initialize();

    await controller.generateDailyReport();
    await generationStarted.future.timeout(const Duration(seconds: 2));

    expect(controller.reportLoading, isTrue);
    generationRelease.complete();
    await _waitUntil(
      () async => await repository.getDailyReportJob('2026-07-13') == null,
    );
  });

  test('initialize recovers an interrupted processing report job', () async {
    await repository.enqueueDailyReportJob('2026-07-13');
    await repository.claimNextDailyReportJob();
    final generated = Completer<void>();
    reportService.onGenerate = (_) async => generated.complete();

    await controller.initialize();
    await generated.future.timeout(const Duration(seconds: 2));
    await _waitUntil(
      () async => await repository.getDailyReportJob('2026-07-13') == null,
    );
  });

  test('late report load cannot overwrite a newly selected date', () async {
    final oldLoad = reportService.blockLoad('2026-07-13');
    final newLoad = reportService.blockLoad('2026-07-12');
    await controller.initialize();

    controller.selectSection(AppSection.report);
    final dateChange = controller.setTimelineDate(DateTime(2026, 7, 12));
    newLoad.complete('新日期日报');
    await dateChange;
    oldLoad.complete('旧日期迟到日报');
    await Future<void>.delayed(Duration.zero);

    expect(controller.timelineDate, DateTime(2026, 7, 12));
    expect(controller.dailyReport, '新日期日报');
  });

  test('analysis queue includes persistent daily report jobs', () async {
    await repository.enqueueDailyReportJob('2026-07-12');
    await repository.claimNextDailyReportJob();
    await repository.markDailyReportJobFailed(
      '2026-07-12',
      category: 'server',
      summary: '服务暂时不可用',
    );
    await controller.initialize();

    await controller.refreshAnalysisQueue();

    final item = controller.analysisQueue.items.single;
    expect(item.isDailyReport, isTrue);
    expect(item.reportDate, '2026-07-12');
    expect(item.status, ProcessingStatus.failed);
    expect(controller.analysisQueue.failedCount, 1);
  });
}

final class _FakeDailyReportService extends DailyReportService {
  _FakeDailyReportService(SqliteDayFlowRepository repository)
    : super(
        timelineRepository: repository,
        reportRepository: repository,
        serviceFactory: () async => throw UnimplementedError(),
        modelName: () async => 'test-model',
      );

  final Map<String, String> loaded = <String, String>{};
  final Map<String, Completer<String?>> _blockedLoads =
      <String, Completer<String?>>{};
  Future<void> Function(String reportDate)? onGenerate;

  Completer<String?> blockLoad(String date) =>
      _blockedLoads[date] = Completer<String?>();

  @override
  Future<String?> loadFresh(String reportDate) =>
      _blockedLoads[reportDate]?.future ?? Future.value(loaded[reportDate]);

  @override
  Future<String> generate(String reportDate) async {
    await onGenerate?.call(reportDate);
    return loaded[reportDate] ?? 'generated';
  }
}

Future<void> _waitUntil(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for state');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
