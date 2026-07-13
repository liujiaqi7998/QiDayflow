// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/domain/domain.dart';
import '../../core/utils/formatters.dart';
import '../../data/data.dart';
import '../../services/native/native_capture_service.dart';
import '../../services/data_directory_service.dart';
import '../../services/logging/app_logger.dart';
import '../../services/logging/managed_log_service.dart';
import '../../services/native/capture_video_spec.dart';
import '../../services/openai/analysis_models.dart';
import '../../services/openai/openai_analysis_service.dart';
import '../../services/processing/analysis_coordinator.dart';
import '../../services/processing/cache_rotation_service.dart';
import '../../services/processing/chunk_evidence.dart';
import '../../services/reports/daily_report_service.dart';
import '../../services/secure_settings_service.dart';
import '../../services/statistics/statistics_service.dart';
import '../../services/update/update_check_service.dart';
import 'app_view_model.dart';

enum AppInitializationStage {
  databaseOpened,
  subscriptionStarted,
  settingsLoaded,
  loggingConfigured,
  coordinatorCreated,
  beforeDerivedRefresh,
}

typedef AppInitializationStageHook =
    Future<void> Function(AppInitializationStage stage);

class AppController extends ChangeNotifier implements QiDayFlowViewModel {
  AppController({
    required AppDatabase database,
    required SqliteDayFlowRepository repository,
    required NativeCaptureService nativeService,
    required SecureSettingsService settingsService,
    DataDirectoryService? dataDirectoryService,
    String? activeUserDataDirectory,
    AppLogger? logger,
    ManagedLogService? managedLogService,
    Duration maintenanceInterval = const Duration(seconds: 30),
    Duration stopTimeout = const Duration(seconds: 15),
    Duration stopReconciliationTimeout = const Duration(seconds: 2),
    DateTime Function()? now,
    UpdateCheckService? updateCheckService,
    Future<bool> Function(Uri uri)? releasePageOpener,
    OpenAiAnalysisService Function(OpenAiAnalysisConfig config)?
    analysisServiceBuilder,
    DailyReportService? dailyReportService,
    AppInitializationStageHook? initializationStageHook,
  }) : _database = database,
       _repository = repository,
       _nativeService = nativeService,
       _settingsService = settingsService,
       _dataDirectoryService = dataDirectoryService,
       _activeUserDataDirectory = p.windows.normalize(
         activeUserDataDirectory ?? p.windows.dirname(database.path),
       ),
       _logger = logger,
       _managedLogService =
           managedLogService ??
           ManagedLogService(
             activeUserDataDirectory: p.windows.normalize(
               activeUserDataDirectory ?? p.windows.dirname(database.path),
             ),
           ),
       _maintenanceInterval = maintenanceInterval,
       _stopTimeout = stopTimeout,
       _stopReconciliationTimeout = stopReconciliationTimeout,
       _now = now ?? DateTime.now,
       _updateCheckService = updateCheckService,
       _releasePageOpener = releasePageOpener ?? _unsupportedReleasePageOpener,
       _analysisServiceBuilder =
           analysisServiceBuilder ?? _defaultAnalysisServiceBuilder,
       _injectedDailyReportService = dailyReportService,
       _initializationStageHook = initializationStageHook,
       _evidenceStore = EvidenceStore(nativeService: nativeService) {
    if (maintenanceInterval <= Duration.zero) {
      throw ArgumentError.value(
        maintenanceInterval,
        'maintenanceInterval',
        '必须大于零',
      );
    }
    if (stopTimeout <= Duration.zero) {
      throw ArgumentError.value(stopTimeout, 'stopTimeout', '必须大于零');
    }
    if (stopReconciliationTimeout <= Duration.zero) {
      throw ArgumentError.value(
        stopReconciliationTimeout,
        'stopReconciliationTimeout',
        '必须大于零',
      );
    }
    _cacheRotationService = CacheRotationService(
      captureRepository: repository,
      evidenceStore: _evidenceStore,
    );
    timelineDate = _now();
    update = UpdateViewData(
      currentVersion: updateCheckService?.currentVersion ?? '未知',
    );
  }

  final AppDatabase _database;
  final SqliteDayFlowRepository _repository;
  final NativeCaptureService _nativeService;
  final SecureSettingsService _settingsService;
  final DataDirectoryService? _dataDirectoryService;
  final String _activeUserDataDirectory;
  final AppLogger? _logger;
  final ManagedLogService _managedLogService;
  final Duration _maintenanceInterval;
  final Duration _stopTimeout;
  final Duration _stopReconciliationTimeout;
  final DateTime Function() _now;
  final UpdateCheckService? _updateCheckService;
  final Future<bool> Function(Uri uri) _releasePageOpener;
  final OpenAiAnalysisService Function(OpenAiAnalysisConfig config)
  _analysisServiceBuilder;
  final DailyReportService? _injectedDailyReportService;
  final AppInitializationStageHook? _initializationStageHook;
  final StatisticsService _statisticsService = const StatisticsService();
  final EvidenceStore _evidenceStore;
  late final CacheRotationService _cacheRotationService;

  late AppSettings _runtimeSettings;
  late AnalysisCoordinator _analysisCoordinator;
  late DailyReportService _dailyReportService;
  StreamSubscription<NativeCaptureEvent>? _nativeSubscription;
  Future<void> _chunkSaveTail = Future<void>.value();
  Future<void> _settingsSaveTail = Future<void>.value();
  Future<void> _trayStateTail = Future<void>.value();
  Future<void>? _captureOperation;
  _NativeStopWait? _nativeStopWait;
  int _captureGeneration = 0;
  int? _activeCaptureGeneration;
  int? _pendingTerminalErrorGeneration;
  String? _pendingTerminalError;
  Future<void>? _managedLogClearOperation;
  Future<void>? _updateCheckOperation;
  Future<void>? _shutdownOperation;
  int _updateCheckGeneration = 0;
  int _latestSettingsSaveRevision = 0;
  int _timelineLoadGeneration = 0;
  int _reportLoadGeneration = 0;
  Timer? _recordingTimer;
  Timer? _refreshTimer;
  Timer? _messageTimer;
  CaptureSession? _activeSession;
  int? _recordingStartedAtMs;
  bool _hasApiKey = false;
  bool _initialized = false;
  bool _exiting = false;
  bool _disposed = false;
  bool _updateCheckServiceClosed = false;
  bool _databaseOpened = false;
  bool _analysisCoordinatorInitialized = false;
  bool _nativeLoggingStarted = false;
  bool _loggerClosed = false;
  int? _lastRotationNoticeAtMs;
  int _dailyGoalHours = 8;

  @override
  AppSection section = AppSection.timeline;
  @override
  RecordingViewStatus recordingStatus = RecordingViewStatus.stopped;
  @override
  Duration recordingDuration = Duration.zero;
  @override
  String? statusMessage;
  @override
  late DateTime timelineDate;
  @override
  List<TimelineCardViewData> timelineCards = const [];
  @override
  bool timelineLoading = false;
  @override
  String? dailyReport;
  @override
  bool reportLoading = false;
  @override
  int statisticsDays = 7;
  @override
  StatisticsViewData statistics = const StatisticsViewData();
  @override
  late SettingsViewData settings;
  @override
  late UpdateViewData update;
  @override
  AnalysisQueueViewData analysisQueue = const AnalysisQueueViewData();
  @override
  int failedChunkCount = 0;
  @override
  int pendingChunkCount = 0;
  @override
  int cacheBytes = 0;
  @override
  int? managedLogBytes;
  @override
  bool clearingManagedLogs = false;
  @override
  String? managedLogError;
  @override
  SettingsSaveStatus settingsSaveStatus = SettingsSaveStatus.idle;
  @override
  String? settingsSaveError;

  @override
  bool get savingSettings => settingsSaveStatus == SettingsSaveStatus.saving;

  Future<void> initialize() async {
    if (_initialized) return;
    if (_shutdownOperation != null) {
      throw StateError('控制器已关闭，不能再次初始化');
    }
    try {
      await _database.open();
      _databaseOpened = true;
      await _runInitializationHook(AppInitializationStage.databaseOpened);
      final recovery = await _repository.recoverInterruptedWork();
      final recoveredReportJobs = await _repository
          .recoverInterruptedDailyReportJobs();
      _nativeSubscription = _nativeService.events.listen(
        _handleNativeEvent,
        onError: (Object error, StackTrace stackTrace) {
          _setMessage('原生事件通道异常：$error');
        },
      );
      await _runInitializationHook(AppInitializationStage.subscriptionStarted);
      _runtimeSettings = await _settingsService.load();
      await _runInitializationHook(AppInitializationStage.settingsLoaded);
      try {
        final launchAtLogin = await _nativeService.queryLaunchAtLogin();
        _runtimeSettings = _runtimeSettings.copyWith(
          launchAtLogin: launchAtLogin,
        );
      } on Object catch (error) {
        _setMessage('读取开机自启动设置失败：$error');
      }
      await _applyLogLevel(_runtimeSettings.logLevel);
      await _runInitializationHook(AppInitializationStage.loggingConfigured);
      await _queueTrayCaptureState(recordingStatus);
      final dataDirectoryService = _dataDirectoryService;
      if (dataDirectoryService != null &&
          !_sameWindowsPath(
            _activeUserDataDirectory,
            _runtimeSettings.userDataDirectory,
          )) {
        try {
          await dataDirectoryService.scheduleChange(
            currentUserDataDirectory: _activeUserDataDirectory,
            nextUserDataDirectory: _runtimeSettings.userDataDirectory,
          );
        } on Object catch (error) {
          _setMessage('用户数据目录迁移调度失败：$error');
        }
      }
      _dailyGoalHours = await _settingsService.loadDailyGoalHours();
      _hasApiKey = _runtimeSettings.apiKeyConfigured;
      _syncSettingsView();
      _dailyReportService =
          _injectedDailyReportService ??
          DailyReportService(
            timelineRepository: _repository,
            reportRepository: _repository,
            serviceFactory: _createAnalysisService,
            modelName: () async => _runtimeSettings.apiModel,
          );
      _analysisCoordinator = AnalysisCoordinator(
        captureRepository: _repository,
        analysisRepository: _repository,
        timelineRepository: _repository,
        serviceFactory: _createAnalysisService,
        dailyReportJobRepository: _repository,
        reportGenerator: (reportDate) async {
          await _dailyReportService.generate(reportDate);
        },
        reportIsFresh: (job) => _dailyReportService
            .hasFreshReportGeneratedSince(job.reportDate, job.requestedAtMs),
        evidenceReader: ChunkEvidenceReader(nativeService: _nativeService),
        onChanged: () => unawaited(_handleAnalysisChanged()),
        onMessage: _setMessage,
      );
      _analysisCoordinatorInitialized = true;
      await _runInitializationHook(AppInitializationStage.coordinatorCreated);
      _initialized = true;
      await _runInitializationHook(AppInitializationStage.beforeDerivedRefresh);
      await _rotateCache();
      await _refreshDerivedData();
      if (_hasApiKey) _analysisCoordinator.schedule();
      if (recovery.sessionsFailed + recovery.chunksFailed > 0) {
        _setMessage('已恢复上次中断的采集与分析任务，原始证据保持不变');
      } else if (recoveredReportJobs > 0) {
        _setMessage('已恢复上次中断的日报任务，将在后台继续生成');
      }
      _refreshTimer = Timer.periodic(_maintenanceInterval, (_) {
        unawaited(_runPeriodicMaintenance());
      });
      _safeNotify();
      await _logger?.log(AppLogLevel.info, 'app.initialized');
      await _refreshManagedLogSize();
      if (_runtimeSettings.autoStartRecording &&
          recordingStatus == RecordingViewStatus.stopped) {
        await startCapture();
      }
      if (_updateCheckService != null) {
        unawaited(_startUpdateCheck(manual: false));
      }
    } on Object {
      try {
        await shutdown();
      } on Object {
        // Preserve the initialization failure after best-effort full rollback.
      }
      rethrow;
    }
  }

  Future<void> _runInitializationHook(AppInitializationStage stage) async {
    await _initializationStageHook?.call(stage);
  }

  @override
  void selectSection(AppSection value) {
    section = value;
    _safeNotify();
    if (value == AppSection.report) unawaited(_loadReport());
    if (value == AppSection.statistics) unawaited(_refreshStatistics());
    if (value == AppSection.analysisQueue) {
      unawaited(refreshAnalysisQueue());
    }
  }

  @override
  Future<void> startCapture() {
    if (_captureOperation != null ||
        recordingStatus.isActive ||
        _activeSession != null ||
        _exiting ||
        _disposed) {
      return Future<void>.value();
    }
    final nativeStopWait = _nativeStopWait;
    if (nativeStopWait != null) {
      return _runCaptureOperation(
        () => _reconcileTimedOutStopAndStart(nativeStopWait),
      );
    }
    return _runCaptureOperation(_startCapture);
  }

  Future<void> _reconcileTimedOutStopAndStart(_NativeStopWait wait) async {
    if (!await _reconcileNativeStop(wait)) return;
    _setRecordingStatus(RecordingViewStatus.stopped);
    _safeNotify();
    if (_nativeStopWait == null &&
        _activeSession == null &&
        !_exiting &&
        !_disposed) {
      await _startCapture();
    }
  }

  Future<void> _startCapture() async {
    CaptureSession? session;
    try {
      await _waitForPendingSettingsSaves();
      _setRecordingStatus(RecordingViewStatus.starting);
      recordingDuration = Duration.zero;
      _safeNotify();
      await Directory(
        _runtimeSettings.captureDirectory,
      ).create(recursive: true);
      final now = _now().toUtc().millisecondsSinceEpoch;
      session = await _repository.createSession(
        CaptureSession(
          captureScope: activeWindowDisplayCaptureScope,
          captureDirectory: _runtimeSettings.captureDirectory,
          startedAtMs: now,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      );
      _activeSession = session;
      _activeCaptureGeneration = ++_captureGeneration;
      _pendingTerminalErrorGeneration = null;
      _pendingTerminalError = null;
      _recordingStartedAtMs = now;
      await _nativeService.start(
        NativeCaptureConfiguration(
          outputDirectory: _runtimeSettings.captureDirectory,
          sessionId: '${session.id}',
          captureIntervalSeconds: _runtimeSettings.captureIntervalSeconds,
          chunkDurationSeconds: captureChunkDurationSeconds,
          idlePauseEnabled: _runtimeSettings.idlePauseEnabled,
          idleTimeoutSeconds: _runtimeSettings.idlePauseSeconds,
        ),
      );
      _setRecordingStatus(RecordingViewStatus.recording);
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final started = _recordingStartedAtMs;
        if (started != null) {
          recordingDuration = Duration(
            milliseconds: _now().toUtc().millisecondsSinceEpoch - started,
          );
          _safeNotify();
        }
      });
      if (!_hasApiKey) {
        _setMessage('尚未配置 API 密钥；切片会在本地排队，不会外发');
      }
    } on Object catch (error) {
      _setRecordingStatus(RecordingViewStatus.error);
      if (session?.id != null) {
        try {
          await _repository.updateSessionStatus(
            session!.id!,
            CaptureSessionStatus.failed,
            errorMessage: error.toString(),
          );
        } on Object {
          // The original start failure remains the actionable error.
        }
      }
      _activeSession = null;
      _activeCaptureGeneration = null;
      _recordingStartedAtMs = null;
      _setMessage('启动采集失败：$error');
    }
    _safeNotify();
  }

  @override
  Future<void> pauseOrResumeCapture() async {
    final session = _activeSession;
    if (session?.id == null) return;
    try {
      if (recordingStatus == RecordingViewStatus.paused) {
        await _nativeService.resume();
        _setRecordingStatus(RecordingViewStatus.recording);
        await _repository.updateSessionStatus(
          session!.id!,
          CaptureSessionStatus.recording,
        );
      } else if (recordingStatus == RecordingViewStatus.recording) {
        await _nativeService.pause();
        _setRecordingStatus(RecordingViewStatus.paused);
        await _repository.updateSessionStatus(
          session!.id!,
          CaptureSessionStatus.paused,
        );
      }
    } on Object catch (error) {
      _setMessage('切换采集状态失败：$error');
    }
    _safeNotify();
  }

  @override
  Future<void> stopCapture() {
    final session = _activeSession;
    if (_captureOperation != null ||
        session?.id == null ||
        recordingStatus == RecordingViewStatus.stopped ||
        recordingStatus == RecordingViewStatus.starting ||
        recordingStatus == RecordingViewStatus.stopping ||
        _disposed) {
      return Future<void>.value();
    }
    return _runCaptureOperation(() => _stopCapture(session!));
  }

  Future<void> _stopCapture(CaptureSession session) async {
    _setRecordingStatus(RecordingViewStatus.stopping);
    _safeNotify();
    final nativeStopWait = _NativeStopWait(
      sessionId: '${session.id}',
      generation: _activeCaptureGeneration!,
    );
    _nativeStopWait = nativeStopWait;
    var nativeStopAccepted = false;
    try {
      await _nativeService.stop();
      nativeStopAccepted = true;
      try {
        await nativeStopWait.completion.future.timeout(
          _stopTimeout,
          onTimeout: () => throw TimeoutException('原生停止确认超时', _stopTimeout),
        );
      } on TimeoutException {
        if (!await _reconcileNativeStop(nativeStopWait)) rethrow;
      }
      final nativeStopFailure = nativeStopWait.failure;
      if (nativeStopFailure != null) throw nativeStopFailure;
      await _chunkSaveTail;
      await _repository.updateSessionStatus(
        session.id!,
        CaptureSessionStatus.stopped,
        endedAtMs: _now().toUtc().millisecondsSinceEpoch,
      );
      _setRecordingStatus(RecordingViewStatus.stopped);
    } on Object catch (error) {
      if (!nativeStopAccepted && identical(_nativeStopWait, nativeStopWait)) {
        _nativeStopWait = null;
      }
      _setRecordingStatus(RecordingViewStatus.error);
      await _repository.updateSessionStatus(
        session.id!,
        CaptureSessionStatus.failed,
        errorMessage: error.toString(),
      );
      _setMessage('停止采集失败：$error');
    } finally {
      _recordingTimer?.cancel();
      _recordingTimer = null;
      _activeSession = null;
      _activeCaptureGeneration = null;
      _recordingStartedAtMs = null;
    }
    if (_hasApiKey) _analysisCoordinator.schedule();
    await _refreshDerivedData();
  }

  @override
  Future<void> setTimelineDate(DateTime date) async {
    final normalized = DateTime(date.year, date.month, date.day);
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    timelineDate = normalized.isAfter(today) ? today : normalized;
    await Future.wait([_refreshTimeline(), _loadReport()]);
  }

  @override
  Future<void> updateTimelineCard(TimelineCardEditDraft draft) async {
    final id = int.tryParse(draft.id);
    if (id == null || id <= 0) {
      throw ArgumentError.value(draft.id, 'id', '卡片 ID 无效');
    }
    if (!timelineCategories.contains(draft.category)) {
      throw ArgumentError.value(draft.category, 'category', '类别无效');
    }
    if (draft.title.trim().isEmpty) {
      throw ArgumentError.value(draft.title, 'title', '标题不能为空');
    }
    if (!draft.productivityScore.isFinite ||
        draft.productivityScore < 0 ||
        draft.productivityScore > 100) {
      throw RangeError.range(
        draft.productivityScore,
        0,
        100,
        'productivityScore',
      );
    }
    final updated = await _repository.updateTimelineCard(
      id: id,
      category: draft.category,
      title: draft.title,
      summary: draft.summary,
      productivityScore: draft.productivityScore,
    );
    if (!updated) throw StateError('要编辑的时间轴卡片不存在');
    await Future.wait([
      _refreshTimeline(),
      _refreshStatistics(),
      _loadReport(),
    ]);
  }

  @override
  Future<Uint8List?> loadApplicationIcon(String executablePath) =>
      _nativeService.getExecutableIcon(executablePath);

  @override
  Future<void> revealExecutableInExplorer(String executablePath) async {
    final revealed = await _nativeService.revealExecutableInExplorer(
      executablePath,
    );
    if (!revealed) throw StateError('无法在 Explorer 中定位该软件');
  }

  @override
  Future<void> openUserDataDirectory(String directoryPath) async {
    final opened = await _nativeService.openDirectoryInExplorer(directoryPath);
    if (!opened) throw StateError('无法在 Explorer 中打开用户数据目录');
  }

  @override
  Future<void> generateDailyReport() async {
    if (!_hasApiKey) {
      section = AppSection.settings;
      _setMessage('生成日报前需要配置 API 密钥');
      return;
    }
    final reportDate = formatIsoDate(timelineDate);
    try {
      final job = await _repository.enqueueDailyReportJob(reportDate);
      if (formatIsoDate(timelineDate) == reportDate) {
        reportLoading = job.status != DailyReportJobStatus.failed;
        _safeNotify();
      }
      _analysisCoordinator.schedule();
      unawaited(refreshAnalysisQueue());
    } on Object catch (error) {
      _setMessage('日报任务入队失败：${error.runtimeType}');
    }
  }

  @override
  Future<void> setStatisticsDays(int days) async {
    if (days != 1 && days != 7 && days != 30) return;
    statisticsDays = days;
    await _refreshStatistics();
  }

  @override
  Future<void> updateDailyGoalHours(int hours) async {
    await _settingsService.saveDailyGoalHours(hours);
    _dailyGoalHours = hours;
    await _refreshStatistics();
  }

  @override
  Future<String> loadApiKeyForEditing() async {
    if (!_hasApiKey) return '';
    return _settingsService.readApiKey(settings: _runtimeSettings);
  }

  @override
  Future<void> saveSettings(SettingsDraft draft) => _enqueueSettingsSave(
    (revision) => _persistSettingsDraft(draft, revision),
  );

  @override
  Future<void> updateLogLevel(AppLogLevel level) {
    if (level == _runtimeSettings.logLevel) return Future<void>.value();
    return _enqueueSettingsSave((revision) async {
      _runtimeSettings = await _settingsService.save(
        _runtimeSettings.copyWith(logLevel: level),
      );
      if (revision != _latestSettingsSaveRevision) return;
      _syncSettingsView();
      try {
        await _applyLogLevel(level);
      } on Object catch (error) {
        _setMessage('日志级别应用失败：$error');
      }
      try {
        await _logger?.log(
          AppLogLevel.info,
          'logging.level_changed',
          fields: <String, Object?>{'level': level.name.toUpperCase()},
        );
      } on Object catch (error) {
        _setMessage('日志级别变更记录失败：$error');
      }
    });
  }

  @override
  Future<void> testApiConnection(SettingsDraft draft) async {
    final key = draft.apiKey.isNotEmpty
        ? draft.apiKey
        : await _settingsService.readApiKey();
    if (key.isEmpty) throw StateError('没有可用的 API 密钥');
    final service = _analysisServiceBuilder(
      OpenAiAnalysisConfig(
        baseUrl: draft.apiUrl,
        apiKey: key,
        model: draft.model,
        timeout: const Duration(seconds: 30),
        maxAttempts: draft.analysisRetryCount + 1,
      ),
    );
    try {
      await service.testConnection();
    } finally {
      service.close();
    }
  }

  @override
  Future<void> checkForUpdates() {
    final pending = _updateCheckOperation;
    if (pending != null) return pending;
    return _startUpdateCheck(manual: true);
  }

  Future<void> _startUpdateCheck({required bool manual}) {
    final pending = _updateCheckOperation;
    if (pending != null) return pending;
    final service = _updateCheckService;
    if (service == null) {
      if (manual && !_disposed) {
        update = UpdateViewData(
          currentVersion: update.currentVersion,
          latestVersion: update.latestVersion,
          updateAvailable: update.updateAvailable,
          lastChecked: update.lastChecked,
          error: '当前环境无法检查更新',
        );
        _safeNotify();
      }
      return Future<void>.value();
    }

    final generation = ++_updateCheckGeneration;
    update = UpdateViewData(
      currentVersion: update.currentVersion,
      latestVersion: update.latestVersion,
      checking: true,
      updateAvailable: update.updateAvailable,
      lastChecked: update.lastChecked,
    );
    _safeNotify();

    late final Future<void> operation;
    operation =
        _performUpdateCheck(
          service: service,
          generation: generation,
          manual: manual,
        ).whenComplete(() {
          if (identical(_updateCheckOperation, operation)) {
            _updateCheckOperation = null;
          }
        });
    _updateCheckOperation = operation;
    return operation;
  }

  Future<void> _performUpdateCheck({
    required UpdateCheckService service,
    required int generation,
    required bool manual,
  }) async {
    final result = await service.check();
    if (_disposed || generation != _updateCheckGeneration) return;
    if (result.error != null) {
      update = UpdateViewData(
        currentVersion: update.currentVersion,
        latestVersion: update.latestVersion,
        updateAvailable: update.updateAvailable,
        lastChecked: result.checkedAt,
        error: manual ? result.error : null,
      );
    } else {
      update = UpdateViewData(
        currentVersion: result.currentVersion,
        latestVersion: result.latestVersion,
        updateAvailable: result.updateAvailable,
        lastChecked: result.checkedAt,
      );
    }
    _safeNotify();
  }

  @override
  Future<void> openReleasesPage() async {
    final opened = await _releasePageOpener(UpdateCheckService.releasesPageUri);
    if (!opened) throw StateError('无法打开下载页面');
  }

  @override
  Future<String?> chooseUserDataDirectory() => _nativeService.selectDirectory(
    initialDirectory: _runtimeSettings.userDataDirectory,
  );

  @override
  Future<void> clearCompletedVideos() async {
    final result = await _cacheRotationService.clearCompletedVideos(
      captureDirectory: _runtimeSettings.captureDirectory,
    );
    await _refreshQueueAndCache();
    final deleted = result.deletedChunkIds.length;
    final skipped = result.skippedChunkIds.length;
    if (skipped > 0) {
      final details = result.messages.join('；');
      final message = '已清理 $deleted 个切片，$skipped 个删除失败：$details';
      _setMessage(message);
      throw StateError(message);
    }
    _setMessage('已清理 $deleted 个已分析缓存视频及对应 JSON');
  }

  @override
  Future<void> clearManagedLogs() {
    final existing = _managedLogClearOperation;
    if (existing != null) return existing;
    final operation = _clearManagedLogs();
    _managedLogClearOperation = operation;
    return operation.whenComplete(() {
      if (identical(_managedLogClearOperation, operation)) {
        _managedLogClearOperation = null;
      }
    });
  }

  Future<void> _clearManagedLogs() async {
    if (_exiting || _disposed) return;
    clearingManagedLogs = true;
    managedLogError = null;
    _safeNotify();

    String? failure;
    try {
      await _logger?.pauseAndFlush();
      await _nativeService.closeLogging();
      final result = await _managedLogService.clear();
      if (!result.succeeded) {
        failure = '${result.issues.length} 个日志文件清理失败，未删除的受管理日志已保留';
      }
    } on Object catch (error) {
      failure = '日志清理失败（${error.runtimeType}）';
    } finally {
      try {
        await _nativeService.configureLogging(
          level: _runtimeSettings.logLevel,
          logDirectory: p.windows.join(_activeUserDataDirectory, 'logs'),
        );
      } on Object catch (error) {
        final reconfigureFailure = '原生日志恢复失败（${error.runtimeType}）';
        failure = failure == null
            ? reconfigureFailure
            : '$failure；$reconfigureFailure';
      }
      try {
        _logger?.resume();
      } on Object catch (error) {
        final resumeFailure = '应用日志恢复失败（${error.runtimeType}）';
        failure = failure == null ? resumeFailure : '$failure；$resumeFailure';
      }
      final refreshIssue = await _refreshManagedLogSize(
        preserveExistingError: true,
      );
      if (refreshIssue != null) {
        failure = failure == null ? refreshIssue : '$failure；$refreshIssue';
      }
      clearingManagedLogs = false;
      managedLogError = failure;
      _safeNotify();
    }

    if (failure != null) {
      _setMessage(failure);
      throw StateError(failure);
    }
    _setMessage('受管理日志已清理');
  }

  @override
  Future<void> refreshAnalysisQueue() async {
    if (!_initialized || _exiting) return;
    final entries = await _repository.listAnalysisQueue();
    final reportJobs = await _repository.listDailyReportJobs();
    final items = <AnalysisQueueItemViewData>[
      ...entries.map(_toAnalysisQueueItem),
      ...reportJobs.map(_toDailyReportQueueItem),
    ]..sort(_compareAnalysisQueueItems);
    analysisQueue = AnalysisQueueViewData(
      items: List<AnalysisQueueItemViewData>.unmodifiable(items),
    );
    pendingChunkCount =
        analysisQueue.processingCount + analysisQueue.pendingCount;
    failedChunkCount = analysisQueue.failedCount;
    _safeNotify();
  }

  @override
  Future<void> retryFailedChunks() => _analysisCoordinator.retryFailed();

  @override
  Future<void> exitApplication() async {
    if (_exiting) return;
    _exiting = true;
    Object? cleanupFailure;
    try {
      final captureOperation = _captureOperation;
      if (captureOperation != null) {
        await captureOperation;
      }
      if (_activeSession != null) await stopCapture();
      await _shutdownResources(logExit: true);
    } on Object catch (error) {
      cleanupFailure = error;
      _setMessage('退出时清理资源失败：$error');
    }
    try {
      await _nativeService.requestExit();
    } on Object catch (error) {
      final prefix = cleanupFailure == null ? '' : '资源清理未完全成功；';
      _setMessage('$prefix请求退出失败：$error');
    }
  }

  void _handleNativeEvent(NativeCaptureEvent event) {
    switch (event) {
      case NativeCaptureStateEvent():
        final activeSessionMatches = _eventMatchesActiveSession(
          event.sessionId,
        );
        final nativeStopWait = _matchingNativeStopWait(event.sessionId);
        final stopWaitMatches = nativeStopWait != null;
        if (event.status == NativeCaptureStatus.stopped && stopWaitMatches) {
          _completeNativeStopWait(nativeStopWait);
        }
        if (!activeSessionMatches && !stopWaitMatches) return;
        if (event.status == NativeCaptureStatus.stopped &&
            activeSessionMatches &&
            !stopWaitMatches) {
          _finalizeUnexpectedNativeStop();
          return;
        }
        _setRecordingStatus(switch (event.status) {
          NativeCaptureStatus.stopped => RecordingViewStatus.stopped,
          NativeCaptureStatus.starting => RecordingViewStatus.starting,
          NativeCaptureStatus.capturing => RecordingViewStatus.recording,
          NativeCaptureStatus.paused => RecordingViewStatus.paused,
          NativeCaptureStatus.stopping => RecordingViewStatus.stopping,
          NativeCaptureStatus.error => RecordingViewStatus.error,
        });
        final session = _activeSession;
        if (session?.id != null && !_exiting) {
          final status = recordingStatus == RecordingViewStatus.paused
              ? CaptureSessionStatus.paused
              : recordingStatus == RecordingViewStatus.recording
              ? CaptureSessionStatus.recording
              : null;
          if (status != null) {
            unawaited(
              _repository
                  .updateSessionStatus(session!.id!, status)
                  .catchError((Object error) => _setMessage('同步采集状态失败：$error')),
            );
          }
        }
        _safeNotify();
      case NativeChunkCompletedEvent():
        if (!_eventMatchesActiveSession(event.sessionId)) return;
        _chunkSaveTail = _chunkSaveTail.then((_) => _saveNativeChunk(event));
      case NativeCaptureErrorEvent():
        final activeSessionMatches = _eventMatchesActiveSession(
          event.sessionId,
        );
        final nativeStopWait = _matchingNativeStopWait(event.sessionId);
        final stopWaitMatches = nativeStopWait != null;
        if (!activeSessionMatches && !stopWaitMatches) return;
        if (!event.recoverable) {
          if (stopWaitMatches) {
            nativeStopWait.failure = StateError(event.message);
            _nativeStopWait = null;
            if (!nativeStopWait.completion.isCompleted) {
              nativeStopWait.completion.complete();
            }
          } else if (activeSessionMatches) {
            _pendingTerminalErrorGeneration = _activeCaptureGeneration;
            _pendingTerminalError = event.message;
          }
          _setRecordingStatus(RecordingViewStatus.error);
        }
        _setMessage('原生采集错误：${event.message}');
      case NativeQuitRequestedEvent():
        unawaited(exitApplication());
      case NativeTrayCommandEvent():
        if (_disposed || _exiting) return;
        unawaited(_handleTrayCommand(event.command));
      case NativeIdleEvent():
        break;
    }
  }

  bool _eventMatchesActiveSession(String? sessionId) {
    final session = _activeSession;
    return session?.id != null &&
        _activeCaptureGeneration != null &&
        sessionId == '${session!.id}';
  }

  _NativeStopWait? _matchingNativeStopWait(String? sessionId) {
    final wait = _nativeStopWait;
    return wait != null &&
            wait.sessionId == sessionId &&
            wait.generation == _captureGeneration
        ? wait
        : null;
  }

  Future<bool> _reconcileNativeStop(_NativeStopWait wait) async {
    if (!identical(_nativeStopWait, wait) ||
        wait.generation != _captureGeneration) {
      return _nativeStopCompletedSuccessfully(wait);
    }
    try {
      final state = await _nativeService.getState().timeout(
        _stopReconciliationTimeout,
      );
      if (!identical(_nativeStopWait, wait) ||
          wait.generation != _captureGeneration) {
        return _nativeStopCompletedSuccessfully(wait);
      }
      if (state['status'] != NativeCaptureStatus.stopped.name ||
          state['sessionId'] != wait.sessionId) {
        return false;
      }
      _completeNativeStopWait(wait);
      return true;
    } on Object {
      return _nativeStopCompletedSuccessfully(wait);
    }
  }

  bool _nativeStopCompletedSuccessfully(_NativeStopWait wait) =>
      _nativeStopWait == null &&
      wait.generation == _captureGeneration &&
      wait.completion.isCompleted &&
      wait.failure == null;

  void _completeNativeStopWait(_NativeStopWait wait) {
    if (!identical(_nativeStopWait, wait)) return;
    _nativeStopWait = null;
    if (!wait.completion.isCompleted) wait.completion.complete();
  }

  void _finalizeUnexpectedNativeStop() {
    final session = _activeSession;
    final generation = _activeCaptureGeneration;
    if (session?.id == null || generation == null) return;
    final terminalError = _pendingTerminalErrorGeneration == generation
        ? _pendingTerminalError
        : null;
    _activeCaptureGeneration = null;
    _pendingTerminalErrorGeneration = null;
    _pendingTerminalError = null;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStartedAtMs = null;
    _setRecordingStatus(
      terminalError == null
          ? RecordingViewStatus.stopped
          : RecordingViewStatus.error,
    );
    _safeNotify();
    unawaited(_completeUnexpectedNativeStop(session!, terminalError));
  }

  Future<void> _completeUnexpectedNativeStop(
    CaptureSession session,
    String? terminalError,
  ) async {
    try {
      await _chunkSaveTail;
      await _repository.updateSessionStatus(
        session.id!,
        terminalError == null
            ? CaptureSessionStatus.stopped
            : CaptureSessionStatus.failed,
        endedAtMs: _now().toUtc().millisecondsSinceEpoch,
        errorMessage: terminalError,
      );
    } on Object catch (error) {
      _setMessage('终结异常采集会话失败：$error');
    } finally {
      if (_activeSession?.id == session.id &&
          _activeCaptureGeneration == null) {
        _activeSession = null;
      }
      _safeNotify();
    }
  }

  Future<void> _saveNativeChunk(NativeChunkCompletedEvent event) async {
    try {
      final sessionId = int.parse(event.sessionId);
      final now = _now().toUtc().millisecondsSinceEpoch;
      await _repository.addChunk(
        CaptureChunk(
          sessionId: sessionId,
          framesDirectory: event.directoryPath,
          metadataPath: event.metadataPath,
          videoPath: event.videoPath,
          startedAtMs: event.startedAtMs,
          endedAtMs: event.endedAtMs,
          frameCount: event.frameCount,
          createdAtMs: now,
          updatedAtMs: now,
        ),
      );
      await _rotateCache();
      if (_hasApiKey) _analysisCoordinator.schedule();
      await _refreshDerivedData();
    } on Object catch (error) {
      _setMessage('切片入队失败，文件已保留：$error');
    }
  }

  Future<void> _handleTrayCommand(NativeTrayCommand command) async {
    if (_disposed || _exiting) return;
    if (_initialized) {
      switch (command) {
        case NativeTrayCommand.startCapture:
          if (recordingStatus == RecordingViewStatus.stopped ||
              recordingStatus == RecordingViewStatus.error) {
            await startCapture();
          }
        case NativeTrayCommand.stopCapture:
          if (recordingStatus == RecordingViewStatus.recording ||
              recordingStatus == RecordingViewStatus.paused) {
            await stopCapture();
          }
      }
    }
    if (!_disposed && !_exiting) {
      await _queueTrayCaptureState(recordingStatus);
    }
  }

  Future<OpenAiAnalysisService> _createAnalysisService() async {
    final key = await _settingsService.readApiKey();
    if (key.isEmpty) throw StateError('API 密钥未配置');
    return _analysisServiceBuilder(
      OpenAiAnalysisConfig(
        baseUrl: _runtimeSettings.apiUrl,
        apiKey: key,
        model: _runtimeSettings.apiModel,
        maxAttempts: _runtimeSettings.analysisRetryCount + 1,
      ),
    );
  }

  Future<void> _refreshDerivedData() async {
    if (!_initialized || _exiting) return;
    await Future.wait([
      _refreshTimeline(),
      _refreshStatistics(),
      _refreshQueueAndCache(),
    ]);
    if (section == AppSection.report) await _loadReport();
  }

  Future<void> _handleAnalysisChanged() async {
    await _rotateCache();
    await _refreshDerivedData();
  }

  Future<void> _runPeriodicMaintenance() async {
    await _rotateCache();
    await _refreshDerivedData();
    await _refreshManagedLogSize();
  }

  Future<String?> _refreshManagedLogSize({
    bool preserveExistingError = false,
  }) async {
    try {
      final snapshot = await _managedLogService.inspect();
      managedLogBytes = snapshot.totalBytes;
      final issue = snapshot.complete
          ? null
          : '日志大小读取不完整（${snapshot.issues.length} 项）';
      if (!preserveExistingError) managedLogError = issue;
      _safeNotify();
      return issue;
    } on Object catch (error) {
      final issue = '日志大小读取失败（${error.runtimeType}）';
      if (!preserveExistingError) managedLogError = issue;
      _safeNotify();
      return issue;
    }
  }

  Future<CacheRotationResult?> _rotateCache({
    bool announceBlocked = false,
  }) async {
    if (_exiting) {
      return null;
    }
    try {
      final result = await _cacheRotationService.rotate(
        captureDirectory: _runtimeSettings.captureDirectory,
        limitBytes: _runtimeSettings.cacheLimitGb * 1024 * 1024 * 1024,
      );
      cacheBytes = result.finalBytes;
      final now = _now().toUtc().millisecondsSinceEpoch;
      final canNotify =
          _lastRotationNoticeAtMs == null ||
          now - _lastRotationNoticeAtMs! >= 60000;
      if (result.purgedChunkIds.isNotEmpty && canNotify) {
        _lastRotationNoticeAtMs = now;
        _setMessage('缓存已轮转：清理 ${result.purgedChunkIds.length} 个最旧已分析切片');
      } else if (announceBlocked && result.unableToReachLimit && canNotify) {
        _lastRotationNoticeAtMs = now;
        _setMessage('缓存仍高于上限；待分析和失败证据已保留');
      }
      _safeNotify();
      return result;
    } on Object catch (error) {
      if (announceBlocked) {
        _setMessage('缓存轮转失败：$error');
      }
      return null;
    }
  }

  Future<void> _refreshTimeline() async {
    final reportDate = formatIsoDate(timelineDate);
    final generation = ++_timelineLoadGeneration;
    timelineLoading = true;
    _safeNotify();
    try {
      final cards = await _repository.listCardsForReportDate(reportDate);
      if (generation == _timelineLoadGeneration &&
          formatIsoDate(timelineDate) == reportDate) {
        timelineCards = cards.map(_toViewCard).toList(growable: false);
      }
    } finally {
      if (generation == _timelineLoadGeneration &&
          formatIsoDate(timelineDate) == reportDate) {
        timelineLoading = false;
        _safeNotify();
      }
    }
  }

  Future<void> _loadReport() async {
    final reportDate = formatIsoDate(timelineDate);
    final generation = ++_reportLoadGeneration;
    try {
      final loaded = await _dailyReportService.loadFresh(reportDate);
      final job = await _repository.getDailyReportJob(reportDate);
      if (generation != _reportLoadGeneration ||
          formatIsoDate(timelineDate) != reportDate) {
        return;
      }
      dailyReport = loaded;
      reportLoading =
          job?.status == DailyReportJobStatus.pending ||
          job?.status == DailyReportJobStatus.processing;
    } on Object catch (error) {
      if (generation != _reportLoadGeneration ||
          formatIsoDate(timelineDate) != reportDate) {
        return;
      }
      dailyReport = null;
      reportLoading = false;
      _setMessage('读取日报失败：$error');
    }
    _safeNotify();
  }

  Future<void> _refreshStatistics() async {
    final now = _now();
    final end = statisticsDays == 1
        ? now
        : DateTime(now.year, now.month, now.day + 1);
    final start = end.subtract(Duration(days: statisticsDays));
    var loadedStart = start.subtract(end.difference(start));
    final referenceDay = end.subtract(const Duration(milliseconds: 1));
    final recentStart = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day - 13,
    );
    final weekStart = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day - (referenceDay.weekday - DateTime.monday),
    );
    final lastWeekStart = weekStart.subtract(const Duration(days: 7));
    for (final candidate in <DateTime>[recentStart, lastWeekStart]) {
      if (candidate.isBefore(loadedStart)) loadedStart = candidate;
    }
    final cards = await _repository.listCardsBetween(
      loadedStart.toUtc().millisecondsSinceEpoch,
      end.toUtc().millisecondsSinceEpoch,
    );
    final result = _statisticsService.calculate(
      cards: cards,
      rangeStart: start,
      rangeEnd: end,
    );
    statistics = StatisticsViewData(
      totalMinutes: result.totalMinutes,
      weightedProductivity: result.weightedProductivity,
      activityCount: result.activityCount,
      deepWorkCount: result.deepWorkCount,
      highEfficiencyMinutes: result.highEfficiencyMinutes,
      totalDurationComparison: StatisticsMetricComparisonViewData(
        current: result.current.totalMinutes,
        previous: result.previous.totalMinutes,
      ),
      productivityComparison: StatisticsMetricComparisonViewData(
        current: result.current.weightedProductivity,
        previous: result.previous.weightedProductivity,
      ),
      deepWorkComparison: StatisticsMetricComparisonViewData(
        current: result.current.deepWorkCount.toDouble(),
        previous: result.previous.deepWorkCount.toDouble(),
      ),
      activityComparison: StatisticsMetricComparisonViewData(
        current: result.current.activityCount.toDouble(),
        previous: result.previous.activityCount.toDouble(),
      ),
      categoryMinutes: result.categoryMinutes,
      categoryShares: result.categoryShares,
      dailyMinutes: result.dailyMinutes,
      dailyCategoryMinutes: result.dailyCategoryMinutes,
      dailyWeightedProductivity: result.dailyWeightedProductivity,
      hourlyEfficiency: result.hourlyEfficiency
          .map(
            (item) => HourEfficiencyViewData(
              hour: item.hour,
              durationMinutes: item.durationMinutes,
              weightedProductivity: item.weightedProductivity,
            ),
          )
          .toList(growable: false),
      topApps: result.topApps
          .map(
            (item) => StatisticsAppViewData(
              name: item.name,
              durationMinutes: item.durationMinutes,
              share: item.share,
              executablePath: item.executablePath,
            ),
          )
          .toList(growable: false),
      thisWeek: StatisticsPeriodViewData(
        totalMinutes: result.thisWeek.totalMinutes,
        weightedProductivity: result.thisWeek.weightedProductivity,
        categoryMinutes: result.thisWeek.categoryMinutes,
      ),
      lastWeek: StatisticsPeriodViewData(
        totalMinutes: result.lastWeek.totalMinutes,
        weightedProductivity: result.lastWeek.weightedProductivity,
        categoryMinutes: result.lastWeek.categoryMinutes,
      ),
      weeklyCategoryDifference: result.weeklyCategoryDifference,
      recentDailyCategoryMinutes: result.recentDailyCategoryMinutes,
      todayMinutes: result.todayMinutes,
      dailyGoalHours: _dailyGoalHours,
      activeApplicationCount: result.activeApplicationCount,
    );
    _safeNotify();
  }

  Future<void> _refreshQueueAndCache() async {
    await refreshAnalysisQueue();
    cacheBytes = await _evidenceStore.sizeOf(_runtimeSettings.captureDirectory);
    _safeNotify();
  }

  AnalysisQueueItemViewData _toAnalysisQueueItem(AnalysisQueueEntry entry) {
    DateTime time(int milliseconds) =>
        DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);

    return AnalysisQueueItemViewData(
      chunkId: entry.chunkId,
      batchId: entry.batchId,
      status: entry.status,
      recordedAt: time(entry.startedAtMs),
      recordedUntil: time(entry.endedAtMs),
      enqueuedAt: time(entry.enqueuedAtMs),
      updatedAt: time(entry.updatedAtMs),
      retryCount: entry.retryCount,
      processingStartedAt: entry.processingStartedAtMs == null
          ? null
          : time(entry.processingStartedAtMs!),
      errorSummary: entry.status == ProcessingStatus.failed
          ? safeAnalysisErrorSummary(entry.errorMessage)
          : null,
    );
  }

  AnalysisQueueItemViewData _toDailyReportQueueItem(DailyReportJob job) {
    DateTime time(int milliseconds) =>
        DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    final requestedAt = time(job.requestedAtMs);
    return AnalysisQueueItemViewData(
      chunkId: null,
      reportDate: job.reportDate,
      status: switch (job.status) {
        DailyReportJobStatus.pending => ProcessingStatus.pending,
        DailyReportJobStatus.processing => ProcessingStatus.processing,
        DailyReportJobStatus.failed => ProcessingStatus.failed,
      },
      recordedAt: requestedAt,
      recordedUntil: requestedAt,
      enqueuedAt: requestedAt,
      updatedAt: time(job.updatedAtMs),
      retryCount: job.retryCount,
      processingStartedAt: job.processingStartedAtMs == null
          ? null
          : time(job.processingStartedAtMs!),
      errorSummary: job.status == DailyReportJobStatus.failed
          ? job.errorSummary
          : null,
    );
  }

  TimelineCardViewData _toViewCard(TimelineCard card) {
    return TimelineCardViewData(
      id: '${card.id}',
      category: card.category,
      title: card.title,
      summary: card.summary,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        card.startedAtMs,
        isUtc: true,
      ),
      endedAt: DateTime.fromMillisecondsSinceEpoch(card.endedAtMs, isUtc: true),
      productivityScore: card.productivityScore,
      apps: card.appUsages.map((item) => item.name).toList(growable: false),
      appUsages: card.appUsages
          .map(
            (item) => TimelineAppViewData(
              name: item.name,
              duration: Duration(milliseconds: item.durationMs),
              executablePath: item.executablePath,
              averageCpuUsagePercent: item.averageCpuUsagePercent,
              peakCpuUsagePercent: item.peakCpuUsagePercent,
              averageMemoryCommitBytes: item.averageMemoryCommitBytes,
              peakMemoryCommitBytes: item.peakMemoryCommitBytes,
            ),
          )
          .toList(growable: false),
    );
  }

  void _syncSettingsView() {
    settings = SettingsViewData(
      apiUrl: _runtimeSettings.apiUrl,
      hasApiKey: _hasApiKey,
      model: _runtimeSettings.apiModel,
      userDataDirectory: _runtimeSettings.userDataDirectory,
      activeUserDataDirectory: _activeUserDataDirectory,
      dataDirectoryRestartRequired: !_sameWindowsPath(
        _activeUserDataDirectory,
        _runtimeSettings.userDataDirectory,
      ),
      cacheLimitGb: _runtimeSettings.cacheLimitGb,
      idlePauseEnabled: _runtimeSettings.idlePauseEnabled,
      idleTimeoutMinutes: _runtimeSettings.idlePauseSeconds ~/ 60,
      captureIntervalSeconds: _runtimeSettings.captureIntervalSeconds,
      themeMode: switch (_runtimeSettings.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      logLevel: _runtimeSettings.logLevel,
      autoStartRecording: _runtimeSettings.autoStartRecording,
      launchAtLogin: _runtimeSettings.launchAtLogin,
      analysisRetryCount: _runtimeSettings.analysisRetryCount,
    );
  }

  Future<void> _applyLogLevel(AppLogLevel level) async {
    final logger = _logger;
    if (logger != null) logger.level = level;
    _nativeLoggingStarted = true;
    await _nativeService.configureLogging(
      level: level,
      logDirectory:
          logger?.logDirectory ??
          p.windows.join(_activeUserDataDirectory, 'logs'),
    );
  }

  Future<void> _enqueueSettingsSave(
    Future<void> Function(int revision) operation, {
    int? reservedRevision,
  }) {
    final revision = reservedRevision ?? _beginSettingsSave();
    final queued = _settingsSaveTail.then((_) async {
      try {
        await operation(revision);
        if (revision == _latestSettingsSaveRevision) {
          settingsSaveStatus = SettingsSaveStatus.saved;
          settingsSaveError = null;
        }
      } on Object catch (error) {
        if (revision == _latestSettingsSaveRevision) {
          settingsSaveStatus = SettingsSaveStatus.error;
          settingsSaveError = '设置保存失败（${error.runtimeType}）';
        }
        rethrow;
      } finally {
        if (revision == _latestSettingsSaveRevision) {
          _safeNotify();
        }
      }
    });
    _settingsSaveTail = queued.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return queued;
  }

  Future<void> _waitForPendingSettingsSaves() async {
    while (true) {
      final pending = _settingsSaveTail;
      await pending;
      if (identical(pending, _settingsSaveTail)) break;
    }
    if (settingsSaveStatus == SettingsSaveStatus.error) {
      throw StateError(settingsSaveError ?? '设置保存失败');
    }
  }

  int _beginSettingsSave() {
    final revision = ++_latestSettingsSaveRevision;
    settingsSaveStatus = SettingsSaveStatus.saving;
    settingsSaveError = null;
    _safeNotify();
    return revision;
  }

  Future<void> _persistSettingsDraft(SettingsDraft draft, int revision) async {
    final apiKey = draft.apiKey.trim();
    final previousLaunchAtLogin = _runtimeSettings.launchAtLogin;
    final launchAtLoginChanged = draft.launchAtLogin != previousLaunchAtLogin;
    final runtime = AppSettings(
      apiUrl: draft.apiUrl,
      apiModel: draft.model,
      apiKeyCiphertext: _runtimeSettings.apiKeyCiphertext,
      userDataDirectory: draft.userDataDirectory,
      cacheLimitGb: draft.cacheLimitGb,
      idlePauseEnabled: draft.idlePauseEnabled,
      idlePauseSeconds: draft.idleTimeoutMinutes * 60,
      themeMode: _preference(draft.themeMode),
      captureIntervalSeconds: recordingStatus.isActive
          ? _runtimeSettings.captureIntervalSeconds
          : draft.captureIntervalSeconds,
      chunkDurationSeconds: _runtimeSettings.chunkDurationSeconds,
      logLevel: draft.logLevel,
      autoStartRecording: draft.autoStartRecording,
      launchAtLogin: draft.launchAtLogin,
      analysisRetryCount: draft.analysisRetryCount,
    );
    var launchAtLoginApplied = false;
    try {
      if (launchAtLoginChanged) {
        await _nativeService.setLaunchAtLogin(draft.launchAtLogin);
        launchAtLoginApplied = true;
      }
      await Directory(runtime.captureDirectory).create(recursive: true);
      _runtimeSettings = await _settingsService.save(
        runtime,
        plaintextApiKey: draft.apiKeyChanged && apiKey.isNotEmpty
            ? apiKey
            : null,
      );
    } on Object catch (error) {
      Object? rollbackFailure;
      if (launchAtLoginApplied) {
        try {
          await _nativeService.setLaunchAtLogin(previousLaunchAtLogin);
        } on Object catch (rollbackError) {
          rollbackFailure = rollbackError;
          try {
            final actualLaunchAtLogin = await _nativeService
                .queryLaunchAtLogin();
            _runtimeSettings = _runtimeSettings.copyWith(
              launchAtLogin: actualLaunchAtLogin,
            );
            if (revision == _latestSettingsSaveRevision) {
              _syncSettingsView();
            }
          } on Object catch (queryError) {
            rollbackFailure = StateError(
              '$rollbackError；重新查询启动项失败：$queryError',
            );
          }
        }
      }
      if (rollbackFailure != null) {
        throw StateError('设置保存失败：$error；启动项回滚失败：$rollbackFailure');
      }
      rethrow;
    }
    final postCommitFailures = <String>[];
    try {
      await _dataDirectoryService?.scheduleChange(
        currentUserDataDirectory: _activeUserDataDirectory,
        nextUserDataDirectory: _runtimeSettings.userDataDirectory,
      );
    } on Object catch (error) {
      postCommitFailures.add('目录迁移调度失败：$error');
    }
    _hasApiKey = _runtimeSettings.apiKeyConfigured;
    if (revision == _latestSettingsSaveRevision) {
      try {
        await _applyLogLevel(_runtimeSettings.logLevel);
      } on Object catch (error) {
        postCommitFailures.add('日志级别应用失败：$error');
      }
      _syncSettingsView();
    }
    if (_hasApiKey) _analysisCoordinator.schedule();
    try {
      await _rotateCache(announceBlocked: true);
    } on Object catch (error) {
      postCommitFailures.add('缓存轮转失败：$error');
    }
    try {
      await _refreshDerivedData();
    } on Object catch (error) {
      postCommitFailures.add('设置后刷新失败：$error');
    }
    if (postCommitFailures.isNotEmpty) {
      _setMessage(postCommitFailures.join('；'));
    }
  }

  static AppThemeMode _preference(ThemeMode mode) => switch (mode) {
    ThemeMode.system => AppThemeMode.system,
    ThemeMode.light => AppThemeMode.light,
    ThemeMode.dark => AppThemeMode.dark,
  };

  Future<void> _runCaptureOperation(Future<void> Function() operation) {
    final pending = operation();
    _captureOperation = pending;
    return pending.whenComplete(() {
      if (identical(_captureOperation, pending)) {
        _captureOperation = null;
      }
    });
  }

  void _setRecordingStatus(RecordingViewStatus value) {
    if (recordingStatus == value) return;
    recordingStatus = value;
    unawaited(_queueTrayCaptureState(value));
  }

  Future<void> _queueTrayCaptureState(RecordingViewStatus value) {
    final state = switch (value) {
      RecordingViewStatus.stopped => NativeTrayCaptureState.stopped,
      RecordingViewStatus.starting => NativeTrayCaptureState.starting,
      RecordingViewStatus.recording => NativeTrayCaptureState.recording,
      RecordingViewStatus.paused => NativeTrayCaptureState.paused,
      RecordingViewStatus.stopping => NativeTrayCaptureState.stopping,
      RecordingViewStatus.error => NativeTrayCaptureState.error,
    };
    final operation = _trayStateTail.then((_) async {
      if (_disposed) return;
      await _nativeService.updateTrayCaptureState(state);
    });
    _trayStateTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        if (!_disposed && !_exiting) {
          _setMessage('同步托盘录制状态失败（${error.runtimeType}）');
        }
      },
    );
    return _trayStateTail;
  }

  void _setMessage(String message) {
    statusMessage = message;
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 7), () {
      statusMessage = null;
      _safeNotify();
    });
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _updateCheckGeneration++;
    _recordingTimer?.cancel();
    _refreshTimer?.cancel();
    _messageTimer?.cancel();
    unawaited(_nativeSubscription?.cancel());
    _closeUpdateCheckService();
    super.dispose();
  }

  Future<void> shutdown() => _shutdownResources(logExit: false);

  Future<void> _shutdownResources({required bool logExit}) {
    final existing = _shutdownOperation;
    if (existing != null) return existing;
    final operation = _performShutdown(logExit: logExit);
    _shutdownOperation = operation;
    return operation;
  }

  Future<void> _performShutdown({required bool logExit}) async {
    _exiting = true;
    _initialized = false;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _messageTimer?.cancel();
    _messageTimer = null;
    Object? firstFailure;

    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error) {
        firstFailure ??= error;
      }
    }

    if (_analysisCoordinatorInitialized) {
      _analysisCoordinatorInitialized = false;
      _dailyReportService.cancelActiveGeneration();
      await attempt(_analysisCoordinator.stop);
    }
    await attempt(() async => _settingsSaveTail);
    await attempt(() async => _trayStateTail);
    final subscription = _nativeSubscription;
    _nativeSubscription = null;
    if (subscription != null) await attempt(subscription.cancel);
    if (_databaseOpened || _database.isOpen) {
      await attempt(_database.close);
      _databaseOpened = false;
    }
    final logger = _logger;
    if (logger != null && !_loggerClosed) {
      if (logExit) {
        await attempt(() => logger.log(AppLogLevel.info, 'app.exiting'));
      }
      await attempt(logger.close);
      _loggerClosed = true;
    }
    _updateCheckGeneration++;
    _closeUpdateCheckService();
    if (_nativeLoggingStarted) {
      _nativeLoggingStarted = false;
      await attempt(_nativeService.closeLogging);
    }
    if (firstFailure != null) throw firstFailure!;
  }

  void _closeUpdateCheckService() {
    if (_updateCheckServiceClosed) return;
    _updateCheckServiceClosed = true;
    _updateCheckService?.close();
  }
}

Future<bool> _unsupportedReleasePageOpener(Uri uri) async => false;

OpenAiAnalysisService _defaultAnalysisServiceBuilder(
  OpenAiAnalysisConfig config,
) => OpenAiAnalysisService(config: config);

final class _NativeStopWait {
  _NativeStopWait({required this.sessionId, required this.generation});

  final String sessionId;
  final int generation;
  final Completer<void> completion = Completer<void>();
  Object? failure;
}

bool _sameWindowsPath(String left, String right) =>
    p.windows.normalize(left).toLowerCase() ==
    p.windows.normalize(right).toLowerCase();

int _compareAnalysisQueueItems(
  AnalysisQueueItemViewData left,
  AnalysisQueueItemViewData right,
) {
  int rank(ProcessingStatus status) => switch (status) {
    ProcessingStatus.processing => 0,
    ProcessingStatus.pending => 1,
    ProcessingStatus.failed => 2,
    ProcessingStatus.completed => 3,
  };

  final statusOrder = rank(left.status).compareTo(rank(right.status));
  if (statusOrder != 0) return statusOrder;
  final timeOrder = left.status == ProcessingStatus.failed
      ? right.updatedAt.compareTo(left.updatedAt)
      : left.enqueuedAt.compareTo(right.enqueuedAt);
  if (timeOrder != 0) return timeOrder;
  return left.id.compareTo(right.id);
}
