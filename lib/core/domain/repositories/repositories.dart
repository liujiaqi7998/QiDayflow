import '../models/analysis_models.dart';
import '../models/capture_models.dart';
import '../models/daily_report.dart';
import '../models/setting_record.dart';
import '../models/statuses.dart';
import '../models/timeline_models.dart';

abstract interface class SettingsRepository {
  Future<SettingRecord?> getSetting(String key);

  Future<List<SettingRecord>> listSettings();

  Future<void> putSetting(String key, String value);

  Future<bool> deleteSetting(String key);
}

abstract interface class CaptureRepository {
  Future<CaptureSession> createSession(CaptureSession session);

  Future<CaptureSession?> getSession(int id);

  Future<CaptureSession?> getActiveSession();

  Future<void> updateSessionStatus(
    int id,
    CaptureSessionStatus status, {
    int? endedAtMs,
    String? errorMessage,
  });

  Future<CaptureChunk> addChunk(CaptureChunk chunk);

  Future<CaptureChunk?> getChunk(int id);

  Future<CaptureChunk?> findChunkByMetadataPath(String metadataPath);

  Future<List<CaptureChunk>> listChunks({
    Set<ProcessingStatus>? statuses,
    int? dueAtMs,
    bool? evidencePurged,
    int? afterId,
    int limit = 100,
  });

  Future<bool> retryChunk(int id);

  Future<bool> markChunkEvidencePurged(int id, {required int purgedAtMs});
}

final class RecoverySummary {
  const RecoverySummary({
    required this.sessionsFailed,
    required this.chunksFailed,
    required this.batchesFailed,
  });

  final int sessionsFailed;
  final int chunksFailed;
  final int batchesFailed;
}

final class AnalysisCommitResult {
  const AnalysisCommitResult({
    required this.observationIds,
    required this.cardIds,
    required this.completedChunkIds,
  });

  final List<int> observationIds;
  final List<int> cardIds;
  final List<int> completedChunkIds;
}

abstract interface class AnalysisRepository {
  Future<AnalysisBatch> claimChunksForAnalysis(List<int> chunkIds);

  Future<AnalysisBatch?> getBatch(int id);

  Future<int> getMaxAnalysisBatchId();

  Future<List<AnalysisBatch>> listBatches({
    Set<ProcessingStatus>? statuses,
    int? afterId,
    int? beforeOrAtId,
    int? updatedBeforeOrAtMs,
    int limit = 100,
  });

  Future<List<int>> listStandaloneFailedChunkIds({
    required int updatedBeforeOrAtMs,
    int? afterId,
    int limit = 100,
  });

  Future<List<AnalysisQueueEntry>> listAnalysisQueue({int? limit});

  Future<List<Observation>> listObservationsForBatch(int batchId);

  Future<void> markAnalysisFailed(
    int batchId,
    String errorMessage, {
    int? nextRetryAtMs,
  });

  Future<bool> retryBatch(int batchId);

  Future<AnalysisBatch?> retryStandaloneFailedChunk(int chunkId);

  Future<bool> deleteFailedBatch(int batchId);

  Future<bool> deleteFailedChunk(int chunkId);

  Future<AnalysisCommitResult> completeAnalysis({
    required int batchId,
    required List<Observation> observations,
    required List<TimelineCard> cards,
  });

  Future<RecoverySummary> recoverInterruptedWork({
    String reason = '应用异常退出，已保留原始证据，可重试分析',
  });
}

abstract interface class TimelineRepository {
  Future<TimelineCard?> getCard(int id);

  Future<List<TimelineCard>> listCardsForReportDate(String reportDate);

  Future<List<TimelineCard>> listCardsBetween(int startMs, int endMs);

  Future<List<TimelineCard>> getRecentCards({int limit = 10});

  Future<bool> updateCard(TimelineCard card);

  Future<bool> updateTimelineCard({
    required int id,
    required String category,
    required String title,
    required String summary,
    required double productivityScore,
  });

  Future<bool> deleteCard(int id);

  Future<int> getTimelineRevision(String reportDate);
}

abstract interface class DailyReportRepository {
  Future<DailyReport?> getDailyReport(String reportDate);

  Future<DailyReport> saveDailyReport({
    required String reportDate,
    required String content,
    required String model,
    int? expectedRevision,
  });

  Future<List<DailyReport>> listDailyReports({int limit = 30});

  Future<bool> deleteDailyReport(String reportDate);

  Future<int> invalidateDailyReport(String reportDate);
}

abstract interface class DailyReportJobRepository {
  Future<DailyReportJob> enqueueDailyReportJob(String reportDate);

  Future<DailyReportJob?> getDailyReportJob(String reportDate);

  Future<List<DailyReportJob>> listDailyReportJobs();

  Future<DailyReportJob?> claimNextDailyReportJob();

  Future<DailyReportJob?> claimPendingDailyReportJob(String reportDate);

  Future<bool> completeDailyReportJob(String reportDate);

  Future<bool> markDailyReportJobFailed(
    String reportDate, {
    required String category,
    required String summary,
  });

  Future<int> retryFailedDailyReportJobs();

  Future<bool> retryFailedDailyReportJob(String reportDate);

  Future<bool> deleteFailedDailyReportJob(String reportDate);

  Future<int> recoverInterruptedDailyReportJobs();
}
