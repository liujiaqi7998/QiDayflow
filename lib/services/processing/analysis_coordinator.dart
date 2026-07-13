// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../../core/domain/domain.dart';
import '../openai/analysis_models.dart' as ai;
import '../openai/openai_analysis_service.dart';
import 'chunk_evidence.dart';

typedef AnalysisServiceFactory = Future<OpenAiAnalysisService> Function();
typedef DailyReportGenerator = Future<void> Function(String reportDate);
typedef DailyReportFreshnessChecker = Future<bool> Function(DailyReportJob job);

class AnalysisCoordinator {
  static const int _retryPageSize = 100;
  static const int _maxAnalysisWorkBeforeReport = 3;

  AnalysisCoordinator({
    required CaptureRepository captureRepository,
    required AnalysisRepository analysisRepository,
    required TimelineRepository timelineRepository,
    required AnalysisServiceFactory serviceFactory,
    DailyReportJobRepository? dailyReportJobRepository,
    DailyReportGenerator? reportGenerator,
    DailyReportFreshnessChecker? reportIsFresh,
    this.evidenceReader = const ChunkEvidenceReader(),
    this.onChanged,
    this.onMessage,
  }) : _captureRepository = captureRepository,
       _analysisRepository = analysisRepository,
       _timelineRepository = timelineRepository,
       _serviceFactory = serviceFactory,
       _dailyReportJobRepository = dailyReportJobRepository,
       _reportGenerator = reportGenerator,
       _reportIsFresh = reportIsFresh {
    final reportDependencies = <Object?>[
      dailyReportJobRepository,
      reportGenerator,
      reportIsFresh,
    ];
    final configuredCount = reportDependencies
        .where((item) => item != null)
        .length;
    if (configuredCount != 0 && configuredCount != reportDependencies.length) {
      throw ArgumentError(
        'dailyReportJobRepository, reportGenerator, and reportIsFresh '
        'must be provided together',
      );
    }
  }

  final CaptureRepository _captureRepository;
  final AnalysisRepository _analysisRepository;
  final TimelineRepository _timelineRepository;
  final AnalysisServiceFactory _serviceFactory;
  final DailyReportJobRepository? _dailyReportJobRepository;
  final DailyReportGenerator? _reportGenerator;
  final DailyReportFreshnessChecker? _reportIsFresh;
  final ChunkEvidenceReader evidenceReader;
  final VoidCallback? onChanged;
  final void Function(String message)? onMessage;

  final Queue<int> _retryBatchIds = Queue<int>();
  final Set<int> _queuedRetryBatchIds = <int>{};
  final Queue<int> _retryChunkIds = Queue<int>();
  Future<void>? _worker;
  Future<void>? _reportWorker;
  Future<void>? _retryInitialization;
  OpenAiAnalysisService? _activeService;
  bool _stopping = false;
  bool _retryScanActive = false;
  bool _retryBatchScanComplete = false;
  bool _retryChunkScanComplete = false;
  int _retryBatchCursor = 0;
  int _retryBatchUpperBound = 0;
  int _retryChunkCursor = 0;
  int _retryRequestedAtMs = 0;
  int _analysisWorkSinceReportCheck = 0;

  bool get isRunning => _worker != null || _reportWorker != null;

  void schedule() {
    if (_stopping || _worker != null) return;
    _worker = _drain()
        .catchError((Object error, StackTrace stackTrace) {
          onMessage?.call('分析队列异常：${_errorMessage(error)}');
        })
        .whenComplete(() {
          _worker = null;
          if (!_stopping) {
            unawaited(_scheduleAgainIfNeeded());
          }
        });
  }

  Future<void> retryFailed() async {
    final existingInitialization = _retryInitialization;
    if (existingInitialization != null) {
      await existingInitialization;
      return;
    }
    if (_retryScanActive) {
      onChanged?.call();
      schedule();
      return;
    }

    final initialization = _initializeRetryScan();
    _retryInitialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_retryInitialization, initialization)) {
        _retryInitialization = null;
      }
    }
  }

  Future<void> _initializeRetryScan() async {
    await _dailyReportJobRepository?.retryFailedDailyReportJobs();
    final requestedAtMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final batchUpperBound = await _analysisRepository.getMaxAnalysisBatchId();
    if (_stopping) return;

    _retryBatchScanComplete = false;
    _retryChunkScanComplete = false;
    _retryBatchCursor = 0;
    _retryBatchUpperBound = batchUpperBound;
    _retryChunkCursor = 0;
    _retryRequestedAtMs = requestedAtMs;
    _retryScanActive = true;
    onChanged?.call();
    schedule();
  }

  Future<void> stop() async {
    _stopping = true;
    _activeService?.close();
    final retryInitialization = _retryInitialization;
    if (retryInitialization != null) await retryInitialization;
    final worker = _worker;
    final reportWorker = _reportWorker;
    await Future.wait(
      <Future<void>?>[worker, reportWorker].whereType<Future<void>>(),
    );
  }

  Future<void> _scheduleAgainIfNeeded() async {
    if (_retryBatchIds.isNotEmpty ||
        _retryChunkIds.isNotEmpty ||
        _retryScanActive) {
      schedule();
      return;
    }
    final pending = await _captureRepository.listChunks(
      statuses: const <ProcessingStatus>{ProcessingStatus.pending},
      dueAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      limit: 1,
    );
    if (pending.isNotEmpty) {
      schedule();
      return;
    }
    final reportJobs = await _dailyReportJobRepository?.listDailyReportJobs();
    if (reportJobs?.any((job) => job.status == DailyReportJobStatus.pending) ??
        false) {
      schedule();
    }
  }

  Future<void> _drain() async {
    while (!_stopping) {
      if (_retryBatchIds.isEmpty &&
          _retryChunkIds.isEmpty &&
          _retryScanActive) {
        await _refillRetryWork();
      }
      if (_analysisWorkSinceReportCheck >= _maxAnalysisWorkBeforeReport) {
        _analysisWorkSinceReportCheck = 0;
        if (await _processOneDailyReport()) continue;
      }
      if (_retryBatchIds.isNotEmpty) {
        final batchId = _retryBatchIds.removeFirst();
        _queuedRetryBatchIds.remove(batchId);
        await _processBatch(batchId);
        _analysisWorkSinceReportCheck++;
        onChanged?.call();
        if (await _processOneFreshChunk()) _analysisWorkSinceReportCheck++;
        continue;
      }
      if (_retryChunkIds.isNotEmpty) {
        final chunkId = _retryChunkIds.removeFirst();
        if (await _captureRepository.retryChunk(chunkId)) {
          final batch = await _analysisRepository.claimChunksForAnalysis(<int>[
            chunkId,
          ]);
          onChanged?.call();
          await _processBatch(batch.id!);
          _analysisWorkSinceReportCheck++;
          onChanged?.call();
        }
        if (await _processOneFreshChunk()) _analysisWorkSinceReportCheck++;
        continue;
      }
      if (await _processOneFreshChunk()) {
        _analysisWorkSinceReportCheck++;
        continue;
      }
      if (await _processOneDailyReport()) {
        _analysisWorkSinceReportCheck = 0;
        continue;
      }
      return;
    }
  }

  Future<void> _refillRetryWork() async {
    while (_retryBatchIds.isEmpty && !_retryBatchScanComplete) {
      final page = await _analysisRepository.listBatches(
        statuses: const <ProcessingStatus>{ProcessingStatus.failed},
        afterId: _retryBatchCursor,
        beforeOrAtId: _retryBatchUpperBound,
        updatedBeforeOrAtMs: _retryRequestedAtMs,
        limit: _retryPageSize,
      );
      for (final batch in page) {
        final id = batch.id!;
        _retryBatchCursor = id;
        if (await _analysisRepository.retryBatch(id) &&
            _queuedRetryBatchIds.add(id)) {
          _retryBatchIds.add(id);
        }
      }
      if (page.length < _retryPageSize) _retryBatchScanComplete = true;
    }
    if (_retryBatchIds.isNotEmpty || !_retryBatchScanComplete) return;
    if (_retryChunkScanComplete) {
      _retryScanActive = false;
      return;
    }

    final chunkIds = await _analysisRepository.listStandaloneFailedChunkIds(
      updatedBeforeOrAtMs: _retryRequestedAtMs,
      afterId: _retryChunkCursor,
      limit: _retryPageSize,
    );
    for (final id in chunkIds) {
      _retryChunkCursor = id;
      _retryChunkIds.add(id);
    }
    if (chunkIds.length < _retryPageSize) {
      _retryChunkScanComplete = true;
      if (_retryChunkIds.isEmpty) _retryScanActive = false;
    }
  }

  Future<bool> _processOneFreshChunk() async {
    final pending = await _captureRepository.listChunks(
      statuses: const <ProcessingStatus>{ProcessingStatus.pending},
      dueAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      limit: 1,
    );
    if (pending.isEmpty) return false;
    final batch = await _analysisRepository.claimChunksForAnalysis(<int>[
      pending.single.id!,
    ]);
    onChanged?.call();
    await _processBatch(batch.id!);
    onChanged?.call();
    return true;
  }

  Future<bool> _processOneDailyReport() async {
    if (_reportWorker != null) return false;
    final repository = _dailyReportJobRepository;
    final generator = _reportGenerator;
    final isFresh = _reportIsFresh;
    if (repository == null || generator == null || isFresh == null) {
      return false;
    }
    final job = await repository.claimNextDailyReportJob();
    if (job == null) {
      return false;
    }
    onChanged?.call();
    if (_stopping) {
      await repository.recoverInterruptedDailyReportJobs();
      onChanged?.call();
      return false;
    }

    late final Future<void> reportWorker;
    reportWorker =
        _runDailyReportJob(
              repository: repository,
              generator: generator,
              isFresh: isFresh,
              job: job,
            )
            .catchError((Object error, StackTrace stackTrace) {
              onMessage?.call('日报队列异常：${_errorMessage(error)}');
            })
            .whenComplete(() {
              if (identical(_reportWorker, reportWorker)) {
                _reportWorker = null;
              }
              if (!_stopping) schedule();
            });
    _reportWorker = reportWorker;
    return true;
  }

  Future<void> _runDailyReportJob({
    required DailyReportJobRepository repository,
    required DailyReportGenerator generator,
    required DailyReportFreshnessChecker isFresh,
    required DailyReportJob job,
  }) async {
    try {
      if (await isFresh(job)) {
        if (!await repository.completeDailyReportJob(job.reportDate)) {
          throw StateError('日报任务完成状态已变化');
        }
        return;
      }
      if (_stopping) {
        await repository.recoverInterruptedDailyReportJobs();
        return;
      }
      await generator(job.reportDate);
      if (!await repository.completeDailyReportJob(job.reportDate)) {
        throw StateError('日报任务完成状态已变化');
      }
    } on Object catch (error) {
      if (_stopping) {
        await repository.recoverInterruptedDailyReportJobs();
      } else {
        final summary = _safeReportErrorSummary(error);
        await repository.markDailyReportJobFailed(
          job.reportDate,
          category: _reportErrorCategory(error),
          summary: summary,
        );
        onMessage?.call('日报生成失败：$summary');
      }
    } finally {
      onChanged?.call();
    }
  }

  Future<void> _processBatch(int batchId) async {
    AnalysisBatch? batch;
    OpenAiAnalysisService? service;
    try {
      batch = await _analysisRepository.getBatch(batchId);
      if (batch == null || batch.status != ProcessingStatus.processing) {
        return;
      }

      final chunks = <CaptureChunk>[];
      final evidenceByChunk = <int, ChunkEvidence>{};
      for (final chunkId in batch.chunkIds) {
        final chunk = await _captureRepository.getChunk(chunkId);
        if (chunk == null) {
          throw StateError('分析批次引用了不存在的切片 $chunkId');
        }
        chunks.add(chunk);
        evidenceByChunk[chunkId] = await evidenceReader.read(chunk);
      }

      service = await _serviceFactory();
      _activeService = service;
      final observations = <ai.AnalysisObservation>[];
      for (final chunk in chunks) {
        final evidence = evidenceByChunk[chunk.id!]!;
        observations.addAll(
          await service.analyzeChunk(
            ai.AnalysisChunkInput(
              chunkId: '${chunk.id}',
              startedAt: _utcTime(chunk.startedAtMs),
              durationSeconds: (chunk.endedAtMs - chunk.startedAtMs) / 1000,
              keyFrames: evidence.keyFrames,
              windowContexts: evidence.windowContexts,
            ),
          ),
        );
      }

      final batchStartMs = chunks
          .map((chunk) => chunk.startedAtMs)
          .reduce(math.min);
      final batchEndMs = chunks
          .map((chunk) => chunk.endedAtMs)
          .reduce(math.max);
      final recent = await _timelineRepository.getRecentCards(limit: 5);
      final cards = await service.generateCards(
        observations: observations,
        batchStart: _utcTime(batchStartMs),
        batchEnd: _utcTime(batchEndMs),
        recentCards: recent.map(_domainCardToAi).toList(growable: false),
      );

      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final chunksById = <int, CaptureChunk>{
        for (final chunk in chunks) chunk.id!: chunk,
      };
      final trustedWindows = <_TrustedWindowInterval>[];
      final resourceSamples = <_WindowResourceSample>[];
      for (final chunk in chunks) {
        final evidence = evidenceByChunk[chunk.id!]!;
        for (final sample in evidence.resourceSamples) {
          resourceSamples.add(
            _WindowResourceSample(
              timestampMs: sample.timestampMs,
              appName: sample.friendlyAppName,
              processName: sample.processName,
              executablePath: sample.executablePath,
              cpuUsagePercent: sample.cpuUsagePercent,
              memoryCommitBytes: sample.memoryCommitBytes,
            ),
          );
        }
        for (final window in evidence.windowContexts) {
          final executablePath = window.executablePath;
          if (executablePath == null) continue;
          trustedWindows.add(
            _TrustedWindowInterval(
              startedAtMs:
                  chunk.startedAtMs + (window.startSeconds * 1000).round(),
              endedAtMs: chunk.startedAtMs + (window.endSeconds * 1000).round(),
              appName: window.friendlyAppName,
              processName: window.processName,
              executablePath: executablePath,
            ),
          );
        }
      }
      final domainObservations = observations
          .map((item) {
            final chunkId = int.tryParse(item.chunkId);
            final chunk = chunkId == null ? null : chunksById[chunkId];
            if (chunkId == null || chunk == null) {
              throw FormatException('模型返回了未知切片 ID：${item.chunkId}');
            }
            final rawStart = item.startTime.toUtc().millisecondsSinceEpoch;
            final rawEnd = item.endTime.toUtc().millisecondsSinceEpoch;
            final startedAtMs = rawStart.clamp(
              chunk.startedAtMs,
              chunk.endedAtMs - 1,
            );
            final endedAtMs = math
                .max(rawEnd, startedAtMs + 1)
                .clamp(startedAtMs + 1, chunk.endedAtMs);
            return Observation(
              batchId: batch!.id,
              chunkId: chunkId,
              startedAtMs: startedAtMs,
              endedAtMs: endedAtMs,
              description: item.text,
              appName: item.appName,
              processName: item.processName,
              processPath: item.executablePath,
              windowTitle: item.windowTitle,
              createdAtMs: now,
            );
          })
          .toList(growable: false);
      final domainCards = cards
          .map(
            (item) => _aiCardToDomain(
              item,
              batch!.id!,
              now,
              batchStartMs,
              batchEndMs,
              trustedWindows,
              resourceSamples,
            ),
          )
          .toList(growable: false);
      await _analysisRepository.completeAnalysis(
        batchId: batch.id!,
        observations: domainObservations,
        cards: domainCards,
      );
    } on Object catch (error) {
      if (batch?.id != null) {
        try {
          final current = await _analysisRepository.getBatch(batch!.id!);
          if (current?.status == ProcessingStatus.processing) {
            await _analysisRepository.markAnalysisFailed(
              batch.id!,
              _errorMessage(error),
            );
          }
        } on Object catch (stateError) {
          onMessage?.call('记录分析失败状态时出错：${_errorMessage(stateError)}');
        }
      }
      onMessage?.call('切片分析失败：${_errorMessage(error)}');
    } finally {
      service?.close();
      if (identical(_activeService, service)) _activeService = null;
    }
  }

  static ai.AnalysisCard _domainCardToAi(TimelineCard card) {
    return ai.AnalysisCard(
      category: card.category,
      title: card.title,
      summary: card.summary,
      startTime: _utcTime(card.startedAtMs),
      endTime: _utcTime(card.endedAtMs),
      appSites: card.appUsages
          .map(
            (item) => ai.AnalysisAppSite(
              name: item.name,
              durationSeconds: item.durationMs / 1000,
            ),
          )
          .toList(growable: false),
      distractions: card.distractions
          .map(
            (item) => ai.AnalysisDistraction(
              description: item.description,
              offsetSeconds: (item.atMs - card.startedAtMs) / 1000,
              timestamp: _utcTime(item.atMs),
              durationSeconds: item.durationMs / 1000,
            ),
          )
          .toList(growable: false),
      productivityScore: card.productivityScore,
    );
  }

  static TimelineCard _aiCardToDomain(
    ai.AnalysisCard card,
    int batchId,
    int now,
    int batchStartMs,
    int batchEndMs,
    List<_TrustedWindowInterval> trustedWindows,
    List<_WindowResourceSample> resourceSamples,
  ) {
    final rawStart = card.startTime.toUtc().millisecondsSinceEpoch;
    final rawEnd = card.endTime.toUtc().millisecondsSinceEpoch;
    final startedAtMs = rawStart.clamp(batchStartMs, batchEndMs - 1);
    final endedAtMs = math
        .max(rawEnd, startedAtMs + 1)
        .clamp(startedAtMs + 1, batchEndMs);
    final local = _utcTime(startedAtMs).toLocal();
    final reportDate =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    return TimelineCard(
      batchId: batchId,
      reportDate: reportDate,
      category: card.category,
      title: card.title,
      summary: card.summary,
      startedAtMs: startedAtMs,
      endedAtMs: endedAtMs,
      appUsages: card.appSites
          .map((item) {
            final executablePath = _matchExecutablePath(
              appName: item.name,
              startedAtMs: startedAtMs,
              endedAtMs: endedAtMs,
              windows: trustedWindows,
            );
            final resources = _aggregateResourceUsage(
              appName: item.name,
              executablePath: executablePath,
              startedAtMs: startedAtMs,
              endedAtMs: endedAtMs,
              samples: resourceSamples,
            );
            return AppUsage(
              name: item.name,
              durationMs: (item.durationSeconds * 1000).round(),
              executablePath: executablePath,
              averageCpuUsagePercent: resources.averageCpuUsagePercent,
              peakCpuUsagePercent: resources.peakCpuUsagePercent,
              averageMemoryCommitBytes: resources.averageMemoryCommitBytes,
              peakMemoryCommitBytes: resources.peakMemoryCommitBytes,
            );
          })
          .toList(growable: false),
      distractions: card.distractions
          .map(
            (item) => Distraction(
              description: item.description,
              atMs: item.timestamp.toUtc().millisecondsSinceEpoch,
              durationMs: (item.durationSeconds * 1000).round(),
            ),
          )
          .toList(growable: false),
      productivityScore: card.productivityScore,
      createdAtMs: now,
      updatedAtMs: now,
    );
  }

  static DateTime _utcTime(int milliseconds) =>
      DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);

  static String? _matchExecutablePath({
    required String appName,
    required int startedAtMs,
    required int endedAtMs,
    required List<_TrustedWindowInterval> windows,
  }) {
    final wanted = _normalizedAppName(appName);
    final overlapByPath = <String, int>{};
    final originalPathByKey = <String, String>{};
    var bestOverlap = 0;
    for (final window in windows) {
      final matches =
          wanted == _normalizedAppName(window.appName) ||
          wanted == _normalizedAppName(window.processName);
      if (!matches) continue;
      final overlap =
          math.min(endedAtMs, window.endedAtMs) -
          math.max(startedAtMs, window.startedAtMs);
      if (overlap <= 0) continue;
      final pathKey = _normalizedExecutablePath(window.executablePath);
      overlapByPath.update(
        pathKey,
        (current) => current + overlap.toInt(),
        ifAbsent: () => overlap.toInt(),
      );
      originalPathByKey.putIfAbsent(pathKey, () => window.executablePath);
    }
    String? bestPathKey;
    for (final entry in overlapByPath.entries) {
      if (entry.value > bestOverlap) {
        bestPathKey = entry.key;
        bestOverlap = entry.value;
      }
    }
    return bestPathKey == null ? null : originalPathByKey[bestPathKey];
  }

  static String _normalizedAppName(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.endsWith('.exe')
        ? normalized.substring(0, normalized.length - 4)
        : normalized;
  }

  static _ResourceAggregate _aggregateResourceUsage({
    required String appName,
    required String? executablePath,
    required int startedAtMs,
    required int endedAtMs,
    required List<_WindowResourceSample> samples,
  }) {
    final wantedName = _normalizedAppName(appName);
    final wantedPath = executablePath == null
        ? null
        : _normalizedExecutablePath(executablePath);
    var cpuCount = 0;
    var cpuSum = 0.0;
    double? peakCpu;
    var memoryCount = 0;
    var memorySum = 0;
    int? peakMemory;

    for (final sample in samples) {
      if (sample.timestampMs < startedAtMs || sample.timestampMs >= endedAtMs) {
        continue;
      }
      final samplePath = sample.executablePath;
      final pathMatches =
          wantedPath != null &&
          samplePath != null &&
          wantedPath == _normalizedExecutablePath(samplePath);
      final nameMatches =
          wantedName == _normalizedAppName(sample.appName) ||
          wantedName == _normalizedAppName(sample.processName);
      final matches = wantedPath != null && samplePath != null
          ? pathMatches
          : nameMatches;
      if (!matches) continue;

      final cpu = sample.cpuUsagePercent;
      if (cpu != null) {
        cpuCount++;
        cpuSum += cpu;
        peakCpu = peakCpu == null ? cpu : math.max(peakCpu, cpu).toDouble();
      }
      final memory = sample.memoryCommitBytes;
      if (memory != null) {
        memoryCount++;
        memorySum += memory;
        peakMemory = peakMemory == null
            ? memory
            : math.max(peakMemory, memory).toInt();
      }
    }

    return _ResourceAggregate(
      averageCpuUsagePercent: cpuCount == 0 ? null : cpuSum / cpuCount,
      peakCpuUsagePercent: peakCpu,
      averageMemoryCommitBytes: memoryCount == 0
          ? null
          : (memorySum / memoryCount).round(),
      peakMemoryCommitBytes: peakMemory,
    );
  }

  static String _normalizedExecutablePath(String value) =>
      value.trim().replaceAll('/', '\\').toLowerCase();

  static String _errorMessage(Object error) {
    final message = error
        .toString()
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .trim();
    return message.length <= 1000
        ? message
        : '${message.substring(0, 1000)}...';
  }
}

String _reportErrorCategory(Object error) {
  final value = error.toString().toLowerCase();
  if (value.contains('revision') || value.contains('版本')) return 'stale';
  if (value.contains('api') && value.contains('key')) return 'configuration';
  if (value.contains('timeout') || value.contains('超时')) return 'timeout';
  if (value.contains('network') || value.contains('socket')) return 'network';
  return 'generation';
}

String _safeReportErrorSummary(Object error) {
  final value = error.toString();
  if (RegExp(r'api.?key|密钥', caseSensitive: false).hasMatch(value)) {
    return '模型服务配置错误';
  }
  if (RegExp(r'time.?out|超时', caseSensitive: false).hasMatch(value)) {
    return '日报生成请求超时';
  }
  if (RegExp(
    r'network|socket|connection',
    caseSensitive: false,
  ).hasMatch(value)) {
    return '网络连接失败';
  }
  if (RegExp(r'revision|版本.*变化', caseSensitive: false).hasMatch(value)) {
    return '生成期间时间轴已更新，请重试';
  }
  if (value.contains('当天没有可生成日报')) return '当天暂无可生成日报的活动';
  return '日报生成失败，详细信息已隐藏';
}

final class _TrustedWindowInterval {
  const _TrustedWindowInterval({
    required this.startedAtMs,
    required this.endedAtMs,
    required this.appName,
    required this.processName,
    required this.executablePath,
  });

  final int startedAtMs;
  final int endedAtMs;
  final String appName;
  final String processName;
  final String executablePath;
}

final class _WindowResourceSample {
  const _WindowResourceSample({
    required this.timestampMs,
    required this.appName,
    required this.processName,
    required this.executablePath,
    required this.cpuUsagePercent,
    required this.memoryCommitBytes,
  });

  final int timestampMs;
  final String appName;
  final String processName;
  final String? executablePath;
  final double? cpuUsagePercent;
  final int? memoryCommitBytes;
}

final class _ResourceAggregate {
  const _ResourceAggregate({
    required this.averageCpuUsagePercent,
    required this.peakCpuUsagePercent,
    required this.averageMemoryCommitBytes,
    required this.peakMemoryCommitBytes,
  });

  final double? averageCpuUsagePercent;
  final double? peakCpuUsagePercent;
  final int? averageMemoryCommitBytes;
  final int? peakMemoryCommitBytes;
}

typedef VoidCallback = void Function();
