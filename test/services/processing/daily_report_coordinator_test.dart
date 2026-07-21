import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/services/processing/analysis_coordinator.dart';
import 'package:qi_day_flow/services/reports/daily_report_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late AppDatabase database;
  late SqliteDayFlowRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_report_coordinator_test_',
    );
    database = AppDatabase(
      path: p.join(temporaryDirectory.path, 'dayflow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    repository = SqliteDayFlowRepository(database);
    await database.open();
  });

  tearDown(() async {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  AnalysisCoordinator coordinator({
    required Future<void> Function(String reportDate) reportGenerator,
    Future<bool> Function(DailyReportJob job)? reportIsFresh,
    DailyReportJobRepository? jobRepository,
  }) {
    return AnalysisCoordinator(
      captureRepository: repository,
      analysisRepository: repository,
      timelineRepository: repository,
      serviceFactory: () async => throw StateError('no chunk service'),
      dailyReportJobRepository: jobRepository ?? repository,
      reportGenerator: reportGenerator,
      reportIsFresh: reportIsFresh ?? (_) async => false,
    );
  }

  test('report-only scheduling leaves pending chunks untouched', () async {
    final session = await repository.createSession(
      CaptureSession(
        captureScope: 'active-window-display',
        captureDirectory: temporaryDirectory.path,
        startedAtMs: 1000,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: p.join(temporaryDirectory.path, 'pending-frames'),
        metadataPath: p.join(temporaryDirectory.path, 'pending.json'),
        videoPath: p.join(temporaryDirectory.path, 'pending.mp4'),
        startedAtMs: 1000,
        endedAtMs: 2000,
        frameCount: 1,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );
    await repository.enqueueDailyReportJob('2026-07-13');
    var generationCalls = 0;
    final worker = coordinator(reportGenerator: (_) async => generationCalls++);

    worker.scheduleDailyReportsOnly();
    await _waitUntil(
      () async => await repository.getDailyReportJob('2026-07-13') == null,
    );
    await worker.stop();

    expect(generationCalls, 1);
    expect(
      (await repository.getChunk(chunk.id!))?.status,
      ProcessingStatus.pending,
    );
  });

  test(
    'report job runs in background and success clears active state',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final worker = coordinator(
        reportGenerator: (date) async {
          expect(date, '2026-07-13');
          entered.complete();
          await release.future;
        },
      );
      await repository.enqueueDailyReportJob('2026-07-13');

      worker.schedule();
      await entered.future.timeout(const Duration(seconds: 2));
      expect(
        (await repository.getDailyReportJob('2026-07-13'))?.status,
        DailyReportJobStatus.processing,
      );

      release.complete();
      await _waitUntil(
        () async => await repository.getDailyReportJob('2026-07-13') == null,
      );
      await worker.stop();
    },
  );

  test('report failure remains visible with a safe summary', () async {
    final worker = coordinator(
      reportGenerator: (_) async {
        throw StateError('api_key=super-secret provider payload');
      },
    );
    await repository.enqueueDailyReportJob('2026-07-13');

    worker.schedule();
    await _waitUntil(() async {
      final job = await repository.getDailyReportJob('2026-07-13');
      return job?.status == DailyReportJobStatus.failed;
    });
    await worker.stop();

    final failed = await repository.getDailyReportJob('2026-07-13');
    expect(failed?.errorSummary, isNot(contains('super-secret')));
    expect(failed?.errorSummary, '模型服务配置错误');
  });

  test(
    'stopping requeues an interrupted report instead of failing it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final worker = coordinator(
        reportGenerator: (_) async {
          entered.complete();
          await release.future;
          throw StateError('cancelled during shutdown');
        },
      );
      await repository.enqueueDailyReportJob('2026-07-13');

      worker.schedule();
      await entered.future.timeout(const Duration(seconds: 2));
      final stopping = worker.stop();
      release.complete();
      await stopping;

      final recovered = await repository.getDailyReportJob('2026-07-13');
      expect(recovered?.status, DailyReportJobStatus.pending);
      expect(recovered?.errorSummary, isNull);
    },
  );

  test(
    'fresh saved report completes a recovered job without another AI call',
    () async {
      var generationCalls = 0;
      final worker = coordinator(
        reportGenerator: (_) async => generationCalls++,
        reportIsFresh: (_) async => true,
      );
      await repository.enqueueDailyReportJob('2026-07-13');

      worker.schedule();
      await _waitUntil(
        () async => await repository.getDailyReportJob('2026-07-13') == null,
      );
      await worker.stop();

      expect(generationCalls, 0);
    },
  );

  test(
    'shutdown after report claim requeues without starting generation',
    () async {
      final claimEntered = Completer<void>();
      final releaseClaim = Completer<void>();
      final gatedJobs = _GatedDailyReportJobRepository(
        repository,
        claimEntered: claimEntered,
        releaseClaim: releaseClaim,
      );
      var generationCalls = 0;
      final worker = coordinator(
        jobRepository: gatedJobs,
        reportGenerator: (_) async => generationCalls++,
      );
      await repository.enqueueDailyReportJob('2026-07-13');

      worker.schedule();
      await claimEntered.future.timeout(const Duration(seconds: 2));
      final stopping = worker.stop();
      releaseClaim.complete();
      await stopping;

      expect(generationCalls, 0);
      expect(
        (await repository.getDailyReportJob('2026-07-13'))?.status,
        DailyReportJobStatus.pending,
      );
    },
  );

  test(
    'daily report gets a bounded turn before a fresh chunk backlog drains',
    () async {
      final session = await repository.createSession(
        CaptureSession(
          captureScope: 'active-window-display',
          captureDirectory: temporaryDirectory.path,
          startedAtMs: 1000,
          createdAtMs: 1000,
          updatedAtMs: 1000,
        ),
      );
      for (var index = 0; index < 6; index++) {
        await repository.addChunk(
          CaptureChunk(
            sessionId: session.id!,
            framesDirectory: p.join(temporaryDirectory.path, 'chunk-$index'),
            metadataPath: p.join(
              temporaryDirectory.path,
              'missing-$index.json',
            ),
            videoPath: p.join(temporaryDirectory.path, 'missing-$index.mp4'),
            startedAtMs: 1000 + index * 60000,
            endedAtMs: 61000 + index * 60000,
            frameCount: 1,
            createdAtMs: 1000 + index,
            updatedAtMs: 1000 + index,
          ),
        );
      }
      await repository.enqueueDailyReportJob('2026-07-13');
      final reportRan = Completer<void>();
      var pendingWhenReportRan = 0;
      final worker = coordinator(
        reportGenerator: (_) async {
          pendingWhenReportRan = (await repository.listChunks(
            statuses: const <ProcessingStatus>{ProcessingStatus.pending},
          )).length;
          reportRan.complete();
        },
      );

      worker.schedule();
      await reportRan.future.timeout(const Duration(seconds: 2));
      await worker.stop();

      expect(pendingWhenReportRan, greaterThan(0));
    },
  );

  test('a long report does not block the remaining chunk backlog', () async {
    final session = await repository.createSession(
      CaptureSession(
        captureScope: 'active-window-display',
        captureDirectory: temporaryDirectory.path,
        startedAtMs: 1000,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );
    for (var index = 0; index < 5; index++) {
      await repository.addChunk(
        CaptureChunk(
          sessionId: session.id!,
          framesDirectory: p.join(
            temporaryDirectory.path,
            'missing-frames-$index',
          ),
          metadataPath: p.join(temporaryDirectory.path, 'missing-$index.json'),
          videoPath: p.join(temporaryDirectory.path, 'missing-$index.mp4'),
          startedAtMs: 2000 + index * 1000,
          endedAtMs: 2500 + index * 1000,
          frameCount: 1,
          createdAtMs: 1000 + index,
          updatedAtMs: 1000 + index,
        ),
      );
    }
    await repository.enqueueDailyReportJob('2026-07-13');
    final reportStarted = Completer<void>();
    final releaseReport = Completer<void>();
    final worker = coordinator(
      reportGenerator: (_) async {
        reportStarted.complete();
        await releaseReport.future;
      },
    );
    worker.schedule();
    try {
      await reportStarted.future;
      await _waitUntil(
        () async => (await repository.listChunks(
          statuses: const <ProcessingStatus>{ProcessingStatus.pending},
        )).isEmpty,
      );
      expect(releaseReport.isCompleted, isFalse);
    } finally {
      if (!releaseReport.isCompleted) releaseReport.complete();
      await worker.stop();
    }
    await _waitUntil(
      () async => await repository.getDailyReportJob('2026-07-13') == null,
    );
  });

  test('fresh chunk work is drained before a report job', () async {
    final session = await repository.createSession(
      CaptureSession(
        captureScope: 'active-window-display',
        captureDirectory: temporaryDirectory.path,
        startedAtMs: 1000,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );
    final chunk = await repository.addChunk(
      CaptureChunk(
        sessionId: session.id!,
        framesDirectory: p.join(temporaryDirectory.path, 'chunk'),
        metadataPath: p.join(temporaryDirectory.path, 'missing.json'),
        videoPath: p.join(temporaryDirectory.path, 'missing.mp4'),
        startedAtMs: 1000,
        endedAtMs: 61000,
        frameCount: 1,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      ),
    );
    await repository.enqueueDailyReportJob('2026-07-13');
    final reportRan = Completer<void>();
    final worker = coordinator(
      reportGenerator: (_) async {
        expect(
          (await repository.getChunk(chunk.id!))?.status,
          ProcessingStatus.failed,
        );
        reportRan.complete();
      },
    );

    worker.schedule();
    await reportRan.future.timeout(const Duration(seconds: 2));
    await worker.stop();
  });

  test('single report retry runs only the selected failed date', () async {
    for (final date in <String>['2026-07-13', '2026-07-14']) {
      await repository.enqueueDailyReportJob(date);
      final claimed = await repository.claimNextDailyReportJob();
      expect(claimed?.reportDate, date);
      await repository.markDailyReportJobFailed(
        date,
        category: 'provider',
        summary: 'temporary failure',
      );
    }
    final generatedDates = <String>[];
    final worker = coordinator(
      reportGenerator: (date) async => generatedDates.add(date),
    );

    expect(
      await worker.retryFailedItem(chunkId: null, reportDate: '2026-07-14'),
      isTrue,
    );
    await _waitUntil(
      () async => await repository.getDailyReportJob('2026-07-14') == null,
    );
    await worker.stop();

    expect(generatedDates, <String>['2026-07-14']);
    expect(
      (await repository.getDailyReportJob('2026-07-13'))?.status,
      DailyReportJobStatus.failed,
    );
  });

  test('empty day report job completes successfully without AI', () async {
    var factoryCalls = 0;
    final reports = DailyReportService(
      timelineRepository: repository,
      reportRepository: repository,
      serviceFactory: () async {
        factoryCalls++;
        throw StateError('AI factory must not be called');
      },
      modelName: () async => 'test-model',
    );
    final worker = coordinator(
      reportGenerator: (date) async => reports.generate(date),
      reportIsFresh: (job) => reports.hasFreshReportGeneratedSince(
        job.reportDate,
        job.requestedAtMs,
      ),
    );
    await repository.enqueueDailyReportJob('2026-07-13');

    worker.schedule();
    await _waitUntil(
      () async => await repository.getDailyReportJob('2026-07-13') == null,
    );
    await worker.stop();

    expect(factoryCalls, 0);
    expect(
      (await repository.getDailyReport('2026-07-13'))?.content,
      '当日暂无可生成日报的活动',
    );
  });
}

final class _GatedDailyReportJobRepository implements DailyReportJobRepository {
  _GatedDailyReportJobRepository(
    this.delegate, {
    required this.claimEntered,
    required this.releaseClaim,
  });

  final DailyReportJobRepository delegate;
  final Completer<void> claimEntered;
  final Completer<void> releaseClaim;

  @override
  Future<DailyReportJob?> claimNextDailyReportJob() async {
    claimEntered.complete();
    await releaseClaim.future;
    return delegate.claimNextDailyReportJob();
  }

  @override
  Future<bool> completeDailyReportJob(String reportDate) =>
      delegate.completeDailyReportJob(reportDate);

  @override
  Future<DailyReportJob> enqueueDailyReportJob(String reportDate) =>
      delegate.enqueueDailyReportJob(reportDate);

  @override
  Future<DailyReportJob?> getDailyReportJob(String reportDate) =>
      delegate.getDailyReportJob(reportDate);

  @override
  Future<List<DailyReportJob>> listDailyReportJobs() =>
      delegate.listDailyReportJobs();

  @override
  Future<bool> markDailyReportJobFailed(
    String reportDate, {
    required String category,
    required String summary,
  }) => delegate.markDailyReportJobFailed(
    reportDate,
    category: category,
    summary: summary,
  );

  @override
  Future<int> recoverInterruptedDailyReportJobs() =>
      delegate.recoverInterruptedDailyReportJobs();

  @override
  Future<int> retryFailedDailyReportJobs() =>
      delegate.retryFailedDailyReportJobs();

  @override
  Future<bool> retryFailedDailyReportJob(String reportDate) =>
      delegate.retryFailedDailyReportJob(reportDate);

  @override
  Future<bool> deleteFailedDailyReportJob(String reportDate) =>
      delegate.deleteFailedDailyReportJob(reportDate);
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for worker');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
