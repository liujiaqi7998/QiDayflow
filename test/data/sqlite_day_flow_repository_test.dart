import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _TestClock implements Clock {
  _TestClock(this.now);

  int now;

  @override
  int nowUtcEpochMs() => now;
}

void main() {
  const baseTime = 1773300000000;
  late Directory temporaryDirectory;
  late AppDatabase appDatabase;
  late _TestClock clock;
  late SqliteDayFlowRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_repository_test_',
    );
    appDatabase = AppDatabase(
      path: '${temporaryDirectory.path}${Platform.pathSeparator}dayflow.db',
      databaseFactory: databaseFactoryFfi,
    );
    clock = _TestClock(baseTime);
    repository = SqliteDayFlowRepository(appDatabase, clock: clock);
    await appDatabase.open();
  });

  tearDown(() async {
    await appDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('AppUsage JSON remains backward compatible with resource metrics', () {
    final legacy = AppUsage.fromJson(<String, Object>{
      'name': 'Legacy App',
      'duration_ms': 1000,
    });
    final current = AppUsage.fromJson(<String, Object>{
      'name': 'Editor',
      'duration_ms': 2000,
      'executable_path': r'C:\Apps\Editor.exe',
      'average_cpu_usage_percent': 12.25,
      'peak_cpu_usage_percent': 25.5,
      'average_memory_commit_bytes': 384 * 1024 * 1024,
      'peak_memory_commit_bytes': 512 * 1024 * 1024,
    });

    expect(legacy.executablePath, isNull);
    expect(legacy.averageCpuUsagePercent, isNull);
    expect(legacy.peakCpuUsagePercent, isNull);
    expect(legacy.averageMemoryCommitBytes, isNull);
    expect(legacy.peakMemoryCommitBytes, isNull);
    expect(current.executablePath, r'C:\Apps\Editor.exe');
    expect(current.averageCpuUsagePercent, 12.25);
    expect(current.peakCpuUsagePercent, 25.5);
    expect(current.averageMemoryCommitBytes, 384 * 1024 * 1024);
    expect(current.peakMemoryCommitBytes, 512 * 1024 * 1024);
    expect(current.toJson()['executable_path'], r'C:\Apps\Editor.exe');
    expect(current.toJson()['average_cpu_usage_percent'], 12.25);
    expect(current.toJson()['peak_cpu_usage_percent'], 25.5);
    expect(current.toJson()['average_memory_commit_bytes'], 384 * 1024 * 1024);
    expect(current.toJson()['peak_memory_commit_bytes'], 512 * 1024 * 1024);
  });

  test('stores settings and capture chunks using epoch milliseconds', () async {
    await repository.putSetting('theme', 'dark');
    final setting = await repository.getSetting('theme');
    expect(setting?.value, 'dark');
    expect(setting?.updatedAtMs, baseTime);
    await expectLater(
      repository.putSetting('api_key', 'must-not-be-plaintext'),
      throwsArgumentError,
    );

    final session = await _createSession(repository, baseTime);
    final chunk = await _createChunk(
      repository,
      session.id!,
      baseTime,
      videoPath: 'C:/QiDayFlow/captures/chunk_$baseTime/chunk_$baseTime.mp4',
    );

    expect(chunk.startedAtMs, baseTime);
    expect(chunk.endedAtMs, baseTime + 60000);
    expect(chunk.status, ProcessingStatus.pending);
    expect(
      chunk.videoPath,
      'C:/QiDayFlow/captures/chunk_$baseTime/chunk_$baseTime.mp4',
    );
    expect(
      await repository.listChunks(statuses: {ProcessingStatus.pending}),
      hasLength(1),
    );
  });

  test('daily goal uses settings storage with an 8 hour default', () async {
    final service = SecureSettingsService(
      repository: repository,
      platform: NativeCaptureService(),
      defaultCaptureDirectory: r'C:\QiDayFlow\captures',
    );

    expect(await service.loadDailyGoalHours(), 8);
    await service.saveDailyGoalHours(12);
    expect(await service.loadDailyGoalHours(), 12);
    expect(() => service.saveDailyGoalHours(17), throwsRangeError);
  });

  test('evidence purge marker accepts only completed chunks', () async {
    final session = await _createSession(repository, baseTime);
    final pending = await _createChunk(
      repository,
      session.id!,
      baseTime,
      videoPath: 'C:/QiDayFlow/captures/chunk_pending.mp4',
    );
    final completed = await _createChunk(
      repository,
      session.id!,
      baseTime + 1,
      videoPath: 'C:/QiDayFlow/captures/chunk_completed.mp4',
      status: ProcessingStatus.completed,
    );

    expect(
      await repository.markChunkEvidencePurged(
        pending.id!,
        purgedAtMs: baseTime + 100,
      ),
      isFalse,
    );
    expect(
      await repository.markChunkEvidencePurged(
        completed.id!,
        purgedAtMs: baseTime + 100,
      ),
      isTrue,
    );
    expect(
      (await repository.getChunk(pending.id!))?.evidencePurgedAtMs,
      isNull,
    );
    expect(
      (await repository.getChunk(completed.id!))?.evidencePurgedAtMs,
      baseTime + 100,
    );
  });

  test('failure is retained and the same batch can be retried', () async {
    final session = await _createSession(repository, baseTime);
    final chunk = await _createChunk(repository, session.id!, baseTime);
    final batch = await repository.claimChunksForAnalysis([chunk.id!]);

    clock.now += 1000;
    await repository.markAnalysisFailed(
      batch.id!,
      'network unavailable',
      nextRetryAtMs: clock.now + 30000,
    );

    final failedChunk = await repository.getChunk(chunk.id!);
    final failedBatch = await repository.getBatch(batch.id!);
    expect(failedChunk?.status, ProcessingStatus.failed);
    expect(failedChunk?.retryCount, 1);
    expect(failedChunk?.framesDirectory, chunk.framesDirectory);
    expect(failedChunk?.nextRetryAtMs, clock.now + 30000);
    expect(failedBatch?.status, ProcessingStatus.failed);
    expect(failedBatch?.retryCount, 1);

    clock.now += 1000;
    expect(await repository.retryBatch(batch.id!), isTrue);
    expect(
      (await repository.getChunk(chunk.id!))?.status,
      ProcessingStatus.processing,
    );
    expect(
      (await repository.getBatch(batch.id!))?.status,
      ProcessingStatus.processing,
    );
  });

  test(
    'analysis success atomically stores results and invalidates reports',
    () async {
      final session = await _createSession(repository, baseTime);
      final chunk = await _createChunk(repository, session.id!, baseTime);
      final batch = await repository.claimChunksForAnalysis([chunk.id!]);
      final cachedReport = await repository.saveDailyReport(
        reportDate: '2026-03-12',
        content: 'old report',
        model: 'vision-model',
      );
      expect(cachedReport.isStale, isFalse);

      clock.now += 1000;
      final result = await repository.completeAnalysis(
        batchId: batch.id!,
        observations: [_observation(chunk.id!, clock.now)],
        cards: [_card(clock.now)],
      );

      expect(result.observationIds, hasLength(1));
      expect(result.cardIds, hasLength(1));
      expect(result.completedChunkIds, [chunk.id]);
      expect(
        (await repository.getChunk(chunk.id!))?.status,
        ProcessingStatus.completed,
      );
      expect(
        (await repository.getBatch(batch.id!))?.status,
        ProcessingStatus.completed,
      );
      final storedObservations = await repository.listObservationsForBatch(
        batch.id!,
      );
      expect(storedObservations, hasLength(1));
      expect(storedObservations.single.processPath, r'C:\Apps\Code.exe');
      final cards = await repository.listCardsForReportDate('2026-03-12');
      expect(cards.single.title, '实现数据库事务');
      expect(cards.single.appUsages.single.name, 'Visual Studio Code');
      expect(cards.single.appUsages.single.executablePath, r'C:\Apps\Code.exe');
      expect(cards.single.appUsages.single.averageCpuUsagePercent, 12.5);
      expect(cards.single.appUsages.single.peakCpuUsagePercent, 24.75);
      expect(
        cards.single.appUsages.single.averageMemoryCommitBytes,
        384 * 1024 * 1024,
      );
      expect(
        cards.single.appUsages.single.peakMemoryCommitBytes,
        512 * 1024 * 1024,
      );

      final staleReport = await repository.getDailyReport('2026-03-12');
      expect(staleReport?.sourceRevision, 0);
      expect(staleReport?.currentRevision, 1);
      expect(staleReport?.isStale, isTrue);

      final refreshed = await repository.saveDailyReport(
        reportDate: '2026-03-12',
        content: 'new report',
        model: 'vision-model',
      );
      expect(refreshed.sourceRevision, 1);
      expect(refreshed.isStale, isFalse);

      final original = cards.single;
      clock.now += 1000;
      expect(
        await repository.updateTimelineCard(
          id: original.id!,
          category: '编程',
          title: '实现并验证数据库事务',
          summary: '',
          productivityScore: 92,
        ),
        isTrue,
      );
      final edited = await repository.getCard(original.id!);
      expect(edited?.category, '编程');
      expect(edited?.title, '实现并验证数据库事务');
      expect(edited?.summary, '');
      expect(edited?.productivityScore, 92);
      expect(edited?.reportDate, original.reportDate);
      expect(edited?.startedAtMs, original.startedAtMs);
      expect(edited?.endedAtMs, original.endedAtMs);
      expect(edited?.appUsages.single.executablePath, r'C:\Apps\Code.exe');
      expect(edited?.createdAtMs, original.createdAtMs);
      expect(edited?.updatedAtMs, clock.now);
      expect((await repository.getDailyReport('2026-03-12'))?.isStale, isTrue);
      expect(await repository.getTimelineRevision('2026-03-12'), 2);
    },
  );

  test(
    'fifty continuous one-minute cards persist as one stable activity',
    () async {
      final session = await _createSession(repository, baseTime);
      const reportDate = '2026-03-12';
      for (var index = 0; index < 50; index++) {
        final startedAtMs = baseTime + index * 60000;
        final chunk = await _createChunk(repository, session.id!, startedAtMs);
        final batch = await repository.claimChunksForAnalysis(<int>[chunk.id!]);
        await repository.completeAnalysis(
          batchId: batch.id!,
          observations: <Observation>[
            Observation(
              chunkId: chunk.id!,
              startedAtMs: startedAtMs,
              endedAtMs: startedAtMs + 60000,
              description: '持续编写项目代码',
              appName: 'Visual Studio Code',
              processName: 'Code.exe',
              processPath: r'C:\Apps\Code.exe',
              createdAtMs: startedAtMs,
            ),
          ],
          cards: <TimelineCard>[
            TimelineCard(
              reportDate: reportDate,
              category: '编程',
              title: '实现 Qi Day Flow',
              summary: '持续实现功能',
              startedAtMs: startedAtMs,
              endedAtMs: startedAtMs + 60000,
              appUsages: <AppUsage>[
                AppUsage(
                  name: 'Visual Studio Code',
                  durationMs: 60000,
                  executablePath: r'C:\Apps\Code.exe',
                ),
              ],
              distractions: const <Distraction>[],
              productivityScore: 80,
              createdAtMs: startedAtMs,
              updatedAtMs: startedAtMs,
            ),
          ],
        );
      }

      var cards = await repository.listCardsForReportDate(reportDate);
      expect(cards, hasLength(1));
      expect(cards.single.startedAtMs, baseTime);
      expect(cards.single.endedAtMs, baseTime + 50 * 60000);
      expect(cards.single.appUsages.single.durationMs, 50 * 60000);
      final database = await appDatabase.open();
      final observationCount = await database.rawQuery(
        'SELECT COUNT(*) AS count FROM observations',
      );
      expect(observationCount.single['count'], 50);

      await appDatabase.close();
      cards = await repository.listCardsForReportDate(reportDate);
      expect(cards, hasLength(1));
      expect(cards.single.endedAtMs, baseTime + 50 * 60000);
    },
  );

  test(
    'merge weights scores and resources and deduplicates repeated details',
    () async {
      final session = await _createSession(repository, baseTime);
      final repeatedDistraction = Distraction(
        description: '查看消息',
        atMs: baseTime + 60000,
        durationMs: 1000,
      );
      await _completeSingleCard(
        repository: repository,
        sessionId: session.id!,
        startedAtMs: baseTime,
        durationMs: 60000,
        reportDate: '2026-03-12',
        category: '编程',
        title: 'Deep Work',
        summary: '实现核心逻辑',
        productivityScore: 30,
        distractions: <Distraction>[repeatedDistraction],
        appUsage: AppUsage(
          name: 'Editor',
          durationMs: 60000,
          executablePath: r'C:\Apps\Editor.exe',
          averageCpuUsagePercent: 10,
          peakCpuUsagePercent: 25,
          averageMemoryCommitBytes: 100,
          peakMemoryCommitBytes: 300,
        ),
      );
      await _completeSingleCard(
        repository: repository,
        sessionId: session.id!,
        startedAtMs: baseTime + 60000,
        durationMs: 120000,
        reportDate: '2026-03-12',
        category: '编程',
        title: '  deep   work  ',
        summary: '实现核心逻辑\n补充测试',
        productivityScore: 90,
        distractions: <Distraction>[repeatedDistraction],
        appUsage: AppUsage(
          name: 'Editor',
          durationMs: 120000,
          executablePath: r'C:\Apps\Editor.exe',
          averageCpuUsagePercent: 40,
          peakCpuUsagePercent: 50,
          averageMemoryCommitBytes: 400,
          peakMemoryCommitBytes: 600,
        ),
      );

      final cards = await repository.listCardsForReportDate('2026-03-12');
      expect(cards, hasLength(1));
      final merged = cards.single;
      expect(merged.durationMs, 180000);
      expect(merged.productivityScore, closeTo(70, 0.000001));
      expect(merged.summary, '实现核心逻辑\n补充测试');
      expect(merged.distractions, hasLength(1));
      final usage = merged.appUsages.single;
      expect(usage.durationMs, 180000);
      expect(usage.averageCpuUsagePercent, closeTo(30, 0.000001));
      expect(usage.peakCpuUsagePercent, 50);
      expect(usage.averageMemoryCommitBytes, 300);
      expect(usage.peakMemoryCommitBytes, 600);
    },
  );

  test('merge stays within conservative event and date boundaries', () async {
    final session = await _createSession(repository, baseTime);
    Future<void> add({
      required int start,
      required String date,
      required String category,
      required String title,
      required String app,
    }) => _completeSingleCard(
      repository: repository,
      sessionId: session.id!,
      startedAtMs: start,
      durationMs: 60000,
      reportDate: date,
      category: category,
      title: title,
      summary: '',
      productivityScore: 50,
      distractions: const <Distraction>[],
      appUsage: AppUsage(name: app, durationMs: 60000),
    );

    await add(
      start: baseTime,
      date: '2026-03-12',
      category: '工作',
      title: '相同任务',
      app: 'Editor',
    );
    await add(
      start: baseTime + 60000,
      date: '2026-03-12',
      category: '工作',
      title: '相同任务',
      app: 'Browser',
    );
    await add(
      start: baseTime + 500000,
      date: '2026-03-13',
      category: '工作',
      title: '分类边界',
      app: 'Editor',
    );
    await add(
      start: baseTime + 560000,
      date: '2026-03-13',
      category: '编程',
      title: '分类边界',
      app: 'Editor',
    );
    await add(
      start: baseTime + 1000000,
      date: '2026-03-14',
      category: '编程',
      title: '间隔边界',
      app: 'Editor',
    );
    await add(
      start: baseTime + 1180001,
      date: '2026-03-14',
      category: '编程',
      title: '间隔边界',
      app: 'Editor',
    );
    await add(
      start: baseTime + 2000000,
      date: '2026-03-15',
      category: '编程',
      title: '跨日边界',
      app: 'Editor',
    );
    await add(
      start: baseTime + 2060000,
      date: '2026-03-16',
      category: '编程',
      title: '跨日边界',
      app: 'Editor',
    );

    expect(await repository.listCardsForReportDate('2026-03-12'), hasLength(2));
    expect(await repository.listCardsForReportDate('2026-03-13'), hasLength(2));
    expect(await repository.listCardsForReportDate('2026-03-14'), hasLength(2));
    expect(await repository.listCardsForReportDate('2026-03-15'), hasLength(1));
    expect(await repository.listCardsForReportDate('2026-03-16'), hasLength(1));
  });

  test(
    'restricted timeline update validates id, title, category, and score',
    () async {
      await expectLater(
        repository.updateTimelineCard(
          id: 0,
          category: '工作',
          title: '有效标题',
          summary: '',
          productivityScore: 80,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.updateTimelineCard(
          id: 1,
          category: '工作',
          title: '   ',
          summary: '',
          productivityScore: 80,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.updateTimelineCard(
          id: 1,
          category: '伪造类别',
          title: '有效标题',
          summary: '',
          productivityScore: 80,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.updateTimelineCard(
          id: 1,
          category: '工作',
          title: '有效标题',
          summary: '',
          productivityScore: 101,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'database failure rolls back observations, cards, and statuses',
    () async {
      final session = await _createSession(repository, baseTime);
      final chunk = await _createChunk(repository, session.id!, baseTime);
      final batch = await repository.claimChunksForAnalysis([chunk.id!]);
      final database = await appDatabase.open();
      await database.execute('''
      CREATE TRIGGER reject_test_card
      BEFORE INSERT ON timeline_cards
      BEGIN
        SELECT RAISE(ABORT, 'test rejection');
      END
    ''');

      expect(
        () => repository.completeAnalysis(
          batchId: batch.id!,
          observations: [_observation(chunk.id!, baseTime)],
          cards: [_card(baseTime)],
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await repository.listObservationsForBatch(batch.id!), isEmpty);
      expect(await repository.listCardsForReportDate('2026-03-12'), isEmpty);
      expect(
        (await repository.getChunk(chunk.id!))?.status,
        ProcessingStatus.processing,
      );
      expect(
        (await repository.getBatch(batch.id!))?.status,
        ProcessingStatus.processing,
      );
      expect(await repository.getTimelineRevision('2026-03-12'), 0);
    },
  );

  test(
    'startup recovery turns interrupted work into retryable failures',
    () async {
      final session = await _createSession(repository, baseTime);
      final chunk = await _createChunk(repository, session.id!, baseTime);
      final batch = await repository.claimChunksForAnalysis([chunk.id!]);

      clock.now += 5000;
      final recovery = await repository.recoverInterruptedWork();

      expect(recovery.sessionsFailed, 1);
      expect(recovery.chunksFailed, 1);
      expect(recovery.batchesFailed, 1);
      expect(
        (await repository.getSession(session.id!))?.status,
        CaptureSessionStatus.failed,
      );
      expect(
        (await repository.getChunk(chunk.id!))?.status,
        ProcessingStatus.failed,
      );
      expect((await repository.getChunk(chunk.id!))?.retryCount, 1);
      expect(
        (await repository.getBatch(batch.id!))?.status,
        ProcessingStatus.failed,
      );
      expect(await repository.getActiveSession(), isNull);
      expect(await repository.retryBatch(batch.id!), isTrue);
    },
  );
}

Future<CaptureSession> _createSession(
  SqliteDayFlowRepository repository,
  int now,
) {
  return repository.createSession(
    CaptureSession(
      captureScope: 'active-window-display',
      captureDirectory: 'C:/QiDayFlow/captures',
      startedAtMs: now,
      createdAtMs: now,
      updatedAtMs: now,
    ),
  );
}

Future<CaptureChunk> _createChunk(
  SqliteDayFlowRepository repository,
  int sessionId,
  int now, {
  String? videoPath,
  ProcessingStatus status = ProcessingStatus.pending,
  int durationMs = 60000,
}) {
  return repository.addChunk(
    CaptureChunk(
      sessionId: sessionId,
      framesDirectory: 'C:/QiDayFlow/captures/chunk_$now',
      metadataPath: 'C:/QiDayFlow/captures/chunk_$now/metadata.json',
      videoPath: videoPath,
      startedAtMs: now,
      endedAtMs: now + durationMs,
      frameCount: 8,
      status: status,
      completedAtMs: status == ProcessingStatus.completed
          ? now + durationMs
          : null,
      createdAtMs: now,
      updatedAtMs: now,
    ),
  );
}

Future<void> _completeSingleCard({
  required SqliteDayFlowRepository repository,
  required int sessionId,
  required int startedAtMs,
  required int durationMs,
  required String reportDate,
  required String category,
  required String title,
  required String summary,
  required double productivityScore,
  required List<Distraction> distractions,
  required AppUsage appUsage,
}) async {
  final chunk = await _createChunk(
    repository,
    sessionId,
    startedAtMs,
    durationMs: durationMs,
  );
  final batch = await repository.claimChunksForAnalysis(<int>[chunk.id!]);
  await repository.completeAnalysis(
    batchId: batch.id!,
    observations: <Observation>[
      Observation(
        chunkId: chunk.id!,
        startedAtMs: startedAtMs,
        endedAtMs: startedAtMs + durationMs,
        description: title,
        appName: appUsage.name,
        processName: appUsage.name,
        processPath: appUsage.executablePath,
        createdAtMs: startedAtMs,
      ),
    ],
    cards: <TimelineCard>[
      TimelineCard(
        reportDate: reportDate,
        category: category,
        title: title,
        summary: summary,
        startedAtMs: startedAtMs,
        endedAtMs: startedAtMs + durationMs,
        appUsages: <AppUsage>[appUsage],
        distractions: distractions,
        productivityScore: productivityScore,
        createdAtMs: startedAtMs,
        updatedAtMs: startedAtMs,
      ),
    ],
  );
}

Observation _observation(int chunkId, int now) {
  return Observation(
    chunkId: chunkId,
    startedAtMs: baseObservationStart,
    endedAtMs: baseObservationStart + 30000,
    description: '在编辑 Flutter 数据层代码',
    appName: 'Visual Studio Code',
    processName: 'Code.exe',
    processPath: r'C:\Apps\Code.exe',
    windowTitle: 'sqlite_day_flow_repository.dart',
    confidence: 0.95,
    createdAtMs: now,
  );
}

const baseObservationStart = 1773300000000;

TimelineCard _card(int now) {
  return TimelineCard(
    reportDate: '2026-03-12',
    category: '工作',
    title: '实现数据库事务',
    summary: '完成 SQLite 原子提交与恢复语义。',
    startedAtMs: baseObservationStart,
    endedAtMs: baseObservationStart + 60000,
    appUsages: [
      AppUsage(
        name: 'Visual Studio Code',
        durationMs: 60000,
        executablePath: r'C:\Apps\Code.exe',
        averageCpuUsagePercent: 12.5,
        peakCpuUsagePercent: 24.75,
        averageMemoryCommitBytes: 384 * 1024 * 1024,
        peakMemoryCommitBytes: 512 * 1024 * 1024,
      ),
    ],
    distractions: const [],
    productivityScore: 90,
    createdAtMs: now,
    updatedAtMs: now,
  );
}
