import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _TestClock implements Clock {
  _TestClock(this.now);

  int now;

  @override
  int nowUtcEpochMs() => now;
}

void main() {
  const baseTime = 1783900800000;
  late Directory temporaryDirectory;
  late AppDatabase database;
  late _TestClock clock;
  late SqliteDayFlowRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_report_job_test_',
    );
    database = AppDatabase(
      path: '${temporaryDirectory.path}${Platform.pathSeparator}dayflow.db',
      databaseFactory: databaseFactoryFfi,
    );
    clock = _TestClock(baseTime);
    repository = SqliteDayFlowRepository(database, clock: clock);
    await database.open();
  });

  tearDown(() async {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('schema 9 creates persistent daily report jobs', () async {
    final db = await database.open();
    final columns = await db.rawQuery('PRAGMA table_info(daily_report_jobs)');

    expect(AppDatabase.schemaVersion, 9);
    expect(
      columns.map((row) => row['name']),
      containsAll(<String>{
        'report_date',
        'status',
        'retry_count',
        'error_category',
        'error_summary',
        'requested_at_ms',
        'updated_at_ms',
        'processing_started_at_ms',
      }),
    );
  });

  test('same date is deduplicated and claim is exclusive', () async {
    final first = await repository.enqueueDailyReportJob('2026-07-13');
    clock.now++;
    final duplicate = await repository.enqueueDailyReportJob('2026-07-13');

    expect(duplicate.reportDate, first.reportDate);
    expect(await repository.listDailyReportJobs(), hasLength(1));

    final claimed = await repository.claimNextDailyReportJob();
    expect(claimed?.status, DailyReportJobStatus.processing);
    expect(claimed?.processingStartedAtMs, baseTime + 1);
    expect(await repository.claimNextDailyReportJob(), isNull);
  });

  test('reenqueue resets only a failed job to pending', () async {
    await repository.enqueueDailyReportJob('2026-07-13');
    await repository.claimNextDailyReportJob();
    clock.now += 1000;
    await repository.markDailyReportJobFailed(
      '2026-07-13',
      category: 'provider',
      summary: 'temporary provider failure',
    );

    clock.now += 1000;
    final pending = await repository.enqueueDailyReportJob('2026-07-13');

    expect(pending.status, DailyReportJobStatus.pending);
    expect(pending.retryCount, 0);
    expect(pending.errorCategory, isNull);
    expect(pending.errorSummary, isNull);
    expect(pending.requestedAtMs, baseTime + 2000);
    expect(pending.processingStartedAtMs, isNull);
    expect(
      (await repository.claimNextDailyReportJob())?.reportDate,
      '2026-07-13',
    );
  });

  test('claims only the requested pending report date', () async {
    await repository.enqueueDailyReportJob('2026-07-13');
    await repository.enqueueDailyReportJob('2026-07-14');

    final claimed = await repository.claimPendingDailyReportJob('2026-07-14');

    expect(claimed?.reportDate, '2026-07-14');
    expect(claimed?.status, DailyReportJobStatus.processing);
    expect(await repository.claimPendingDailyReportJob('2026-07-14'), isNull);
    expect(
      (await repository.getDailyReportJob('2026-07-13'))?.status,
      DailyReportJobStatus.pending,
    );
  });

  test('processing jobs recover to pending after restart', () async {
    await repository.enqueueDailyReportJob('2026-07-13');
    await repository.claimNextDailyReportJob();

    clock.now += 1000;
    expect(await repository.recoverInterruptedDailyReportJobs(), 1);
    final recovered = await repository.getDailyReportJob('2026-07-13');

    expect(recovered?.status, DailyReportJobStatus.pending);
    expect(recovered?.processingStartedAtMs, isNull);
  });

  test('failed jobs expose safe fields and can be retried', () async {
    await repository.enqueueDailyReportJob('2026-07-13');
    await repository.claimNextDailyReportJob();
    clock.now += 1000;
    await repository.markDailyReportJobFailed(
      '2026-07-13',
      category: 'provider',
      summary: 'temporary provider failure',
    );

    final failed = await repository.getDailyReportJob('2026-07-13');
    expect(failed?.status, DailyReportJobStatus.failed);
    expect(failed?.retryCount, 1);
    expect(failed?.errorCategory, 'provider');
    expect(failed?.errorSummary, 'temporary provider failure');

    clock.now += 1000;
    expect(await repository.retryFailedDailyReportJobs(), 1);
    final pending = await repository.getDailyReportJob('2026-07-13');
    expect(pending?.status, DailyReportJobStatus.pending);
    expect(pending?.errorCategory, isNull);
    expect(pending?.errorSummary, isNull);

    await repository.claimNextDailyReportJob();
    expect(await repository.completeDailyReportJob('2026-07-13'), isTrue);
    expect(await repository.getDailyReportJob('2026-07-13'), isNull);
  });

  test(
    'single daily report retry and delete are scoped and failed-only',
    () async {
      for (final date in <String>['2026-07-13', '2026-07-14']) {
        await repository.enqueueDailyReportJob(date);
        await repository.claimNextDailyReportJob();
        await repository.markDailyReportJobFailed(
          date,
          category: 'provider',
          summary: 'temporary failure',
        );
      }
      await repository.enqueueDailyReportJob('2026-07-15');

      expect(await repository.retryFailedDailyReportJob('2026-07-13'), isTrue);
      expect(await repository.retryFailedDailyReportJob('2026-07-13'), isFalse);
      expect(
        (await repository.getDailyReportJob('2026-07-13'))?.status,
        DailyReportJobStatus.processing,
      );
      expect(
        (await repository.getDailyReportJob('2026-07-14'))?.status,
        DailyReportJobStatus.failed,
      );
      expect(
        await repository.deleteFailedDailyReportJob('2026-07-13'),
        isFalse,
      );
      expect(
        await repository.deleteFailedDailyReportJob('2026-07-15'),
        isFalse,
      );
      expect(await repository.deleteFailedDailyReportJob('2026-07-14'), isTrue);
      expect(
        await repository.deleteFailedDailyReportJob('2026-07-14'),
        isFalse,
      );
      expect(await repository.getDailyReportJob('2026-07-14'), isNull);
      expect(
        (await repository.getDailyReportJob('2026-07-15'))?.status,
        DailyReportJobStatus.pending,
      );
    },
  );
}
