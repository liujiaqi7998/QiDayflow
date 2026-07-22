import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/domain/domain.dart';
import '../local/app_database.dart';

final class SqliteDayFlowRepository
    implements
        SettingsRepository,
        CaptureRepository,
        AnalysisRepository,
        TimelineRepository,
        DailyReportRepository,
        DailyReportJobRepository {
  SqliteDayFlowRepository(this.database, {this.clock = const SystemClock()});

  final AppDatabase database;
  final Clock clock;

  @override
  Future<SettingRecord?> getSetting(String key) async {
    final normalizedKey = requireNonBlank(key, 'key');
    final db = await database.open();
    final rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [normalizedKey],
      limit: 1,
    );
    return rows.isEmpty ? null : _settingFromRow(rows.single);
  }

  @override
  Future<List<SettingRecord>> listSettings() async {
    final db = await database.open();
    final rows = await db.query('settings', orderBy: 'key ASC');
    return rows.map(_settingFromRow).toList(growable: false);
  }

  @override
  Future<void> putSetting(String key, String value) async {
    final normalizedKey = requireNonBlank(key, 'key');
    if (normalizedKey == 'api_key' || normalizedKey == 'apiKey') {
      throw ArgumentError.value(
        normalizedKey,
        'key',
        '禁止存储明文 API key，必须使用 DPAPI 密文',
      );
    }
    final now = clock.nowUtcEpochMs();
    final db = await database.open();
    await db.rawInsert(
      '''
      INSERT INTO settings(key, value, updated_at_ms)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updated_at_ms = excluded.updated_at_ms
      ''',
      [normalizedKey, value, now],
    );
  }

  @override
  Future<bool> deleteSetting(String key) async {
    final db = await database.open();
    return await db.delete(
          'settings',
          where: 'key = ?',
          whereArgs: [requireNonBlank(key, 'key')],
        ) >
        0;
  }

  @override
  Future<CaptureSession> createSession(CaptureSession session) async {
    if (session.id != null) {
      throw ArgumentError.value(session.id, 'session.id', 'must be null');
    }
    final db = await database.open();
    final id = await db.insert('capture_sessions', {
      'capture_scope': session.captureScope,
      'capture_directory': session.captureDirectory,
      'started_at_ms': session.startedAtMs,
      'ended_at_ms': session.endedAtMs,
      'status': session.status.name,
      'error_message': session.errorMessage,
      'created_at_ms': session.createdAtMs,
      'updated_at_ms': session.updatedAtMs,
    });
    return (await getSession(id))!;
  }

  @override
  Future<CaptureSession?> getSession(int id) async {
    final db = await database.open();
    final rows = await db.query(
      'capture_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _sessionFromRow(rows.single);
  }

  @override
  Future<CaptureSession?> getActiveSession() async {
    final db = await database.open();
    final rows = await db.query(
      'capture_sessions',
      where: "status IN ('recording', 'paused')",
      orderBy: 'started_at_ms DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _sessionFromRow(rows.single);
  }

  @override
  Future<void> updateSessionStatus(
    int id,
    CaptureSessionStatus status, {
    int? endedAtMs,
    String? errorMessage,
  }) async {
    final now = clock.nowUtcEpochMs();
    final isTerminal =
        status == CaptureSessionStatus.stopped ||
        status == CaptureSessionStatus.failed;
    final db = await database.open();
    final count = await db.update(
      'capture_sessions',
      {
        'status': status.name,
        'ended_at_ms': isTerminal ? (endedAtMs ?? now) : null,
        'error_message': errorMessage,
        'updated_at_ms': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (count != 1) {
      throw StateError('Capture session $id does not exist');
    }
  }

  @override
  Future<CaptureChunk> addChunk(CaptureChunk chunk) async {
    if (chunk.id != null) {
      throw ArgumentError.value(chunk.id, 'chunk.id', 'must be null');
    }
    final db = await database.open();
    final id = await db.insert('capture_chunks', {
      'session_id': chunk.sessionId,
      'frames_directory': chunk.framesDirectory,
      'metadata_path': chunk.metadataPath,
      'video_path': chunk.videoPath,
      'started_at_ms': chunk.startedAtMs,
      'ended_at_ms': chunk.endedAtMs,
      'frame_count': chunk.frameCount,
      'status': chunk.status.name,
      'retry_count': chunk.retryCount,
      'next_retry_at_ms': chunk.nextRetryAtMs,
      'error_message': chunk.errorMessage,
      'processing_started_at_ms': chunk.processingStartedAtMs,
      'completed_at_ms': chunk.completedAtMs,
      'evidence_purged_at_ms': chunk.evidencePurgedAtMs,
      'created_at_ms': chunk.createdAtMs,
      'updated_at_ms': chunk.updatedAtMs,
    });
    return (await getChunk(id))!;
  }

  @override
  Future<CaptureChunk?> getChunk(int id) async {
    final db = await database.open();
    final rows = await db.query(
      'capture_chunks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _chunkFromRow(rows.single);
  }

  @override
  Future<CaptureChunk?> findChunkByMetadataPath(String metadataPath) async {
    final path = requireNonBlank(metadataPath, 'metadataPath');
    final db = await database.open();
    final rows = await db.query(
      'capture_chunks',
      where: 'metadata_path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isEmpty ? null : _chunkFromRow(rows.single);
  }

  @override
  Future<List<CaptureChunk>> listChunks({
    Set<ProcessingStatus>? statuses,
    int? dueAtMs,
    bool? evidencePurged,
    int? afterId,
    int limit = 100,
  }) async {
    _requirePositiveLimit(limit);
    final clauses = <String>[];
    final arguments = <Object?>[];
    if (statuses != null && statuses.isNotEmpty) {
      clauses.add('status IN (${_placeholders(statuses.length)})');
      arguments.addAll(statuses.map((status) => status.name));
    }
    if (dueAtMs != null) {
      clauses.add('(next_retry_at_ms IS NULL OR next_retry_at_ms <= ?)');
      arguments.add(dueAtMs);
    }
    if (evidencePurged != null) {
      clauses.add(
        evidencePurged
            ? 'evidence_purged_at_ms IS NOT NULL'
            : 'evidence_purged_at_ms IS NULL',
      );
    }
    if (afterId != null) {
      clauses.add('id > ?');
      arguments.add(afterId);
    }
    final db = await database.open();
    final rows = await db.query(
      'capture_chunks',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: arguments,
      orderBy: afterId == null ? 'started_at_ms ASC' : 'id ASC',
      limit: limit,
    );
    return rows.map(_chunkFromRow).toList(growable: false);
  }

  @override
  Future<bool> retryChunk(int id) async {
    final db = await database.open();
    return await db.update(
          'capture_chunks',
          {
            'status': ProcessingStatus.pending.name,
            'next_retry_at_ms': null,
            'error_message': null,
            'processing_started_at_ms': null,
            'completed_at_ms': null,
            'updated_at_ms': clock.nowUtcEpochMs(),
          },
          where: 'id = ? AND status = ?',
          whereArgs: [id, ProcessingStatus.failed.name],
        ) ==
        1;
  }

  @override
  Future<bool> markChunkEvidencePurged(
    int id, {
    required int purgedAtMs,
  }) async {
    if (purgedAtMs < 0) {
      throw ArgumentError.value(purgedAtMs, 'purgedAtMs');
    }
    final db = await database.open();
    return await db.update(
          'capture_chunks',
          {
            'evidence_purged_at_ms': purgedAtMs,
            'updated_at_ms': clock.nowUtcEpochMs(),
          },
          where: 'id = ? AND status = ? AND evidence_purged_at_ms IS NULL',
          whereArgs: [id, ProcessingStatus.completed.name],
        ) ==
        1;
  }

  @override
  Future<AnalysisBatch> claimChunksForAnalysis(List<int> chunkIds) async {
    final ids = List<int>.unmodifiable(chunkIds);
    _requireValidIds(ids, 'chunkIds');
    final now = clock.nowUtcEpochMs();
    final batchId = await database.transaction((transaction) async {
      final chunks = await transaction.query(
        'capture_chunks',
        columns: ['id', 'status'],
        where: 'id IN (${_placeholders(ids.length)})',
        whereArgs: ids,
      );
      if (chunks.length != ids.length) {
        throw StateError('One or more chunks do not exist');
      }
      final unavailable = chunks.where(
        (row) => row['status'] != ProcessingStatus.pending.name,
      );
      if (unavailable.isNotEmpty) {
        throw StateError('Only pending chunks can be claimed');
      }

      final id = await transaction.insert('analysis_batches', {
        'status': ProcessingStatus.processing.name,
        'retry_count': 0,
        'processing_started_at_ms': now,
        'created_at_ms': now,
        'updated_at_ms': now,
      });
      for (var index = 0; index < ids.length; index++) {
        await transaction.insert('analysis_batch_chunks', {
          'batch_id': id,
          'chunk_id': ids[index],
          'ordinal': index,
        });
      }
      final updated = await transaction.update(
        'capture_chunks',
        {
          'status': ProcessingStatus.processing.name,
          'error_message': null,
          'next_retry_at_ms': null,
          'processing_started_at_ms': now,
          'completed_at_ms': null,
          'updated_at_ms': now,
        },
        where: 'id IN (${_placeholders(ids.length)}) AND status = ?',
        whereArgs: [...ids, ProcessingStatus.pending.name],
      );
      if (updated != ids.length) {
        throw StateError('Chunks changed while being claimed');
      }
      return id;
    });
    return (await getBatch(batchId))!;
  }

  @override
  Future<AnalysisBatch?> getBatch(int id) async {
    final db = await database.open();
    final rows = await db.query(
      'analysis_batches',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : await _batchFromRow(db, rows.single);
  }

  @override
  Future<int> getMaxAnalysisBatchId() async {
    final db = await database.open();
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(id), 0) AS max_id FROM analysis_batches',
    );
    return rows.single['max_id']! as int;
  }

  @override
  Future<List<AnalysisBatch>> listBatches({
    Set<ProcessingStatus>? statuses,
    int? afterId,
    int? beforeOrAtId,
    int? updatedBeforeOrAtMs,
    int limit = 100,
  }) async {
    _requirePositiveLimit(limit);
    final db = await database.open();
    final statusList = statuses?.toList(growable: false);
    final clauses = <String>[];
    final arguments = <Object?>[];
    if (statusList != null && statusList.isNotEmpty) {
      clauses.add('status IN (${_placeholders(statusList.length)})');
      arguments.addAll(statusList.map((status) => status.name));
    }
    if (afterId != null) {
      clauses.add('id > ?');
      arguments.add(afterId);
    }
    if (beforeOrAtId != null) {
      clauses.add('id <= ?');
      arguments.add(beforeOrAtId);
    }
    if (updatedBeforeOrAtMs != null) {
      clauses.add('updated_at_ms <= ?');
      arguments.add(updatedBeforeOrAtMs);
    }
    final rows = await db.query(
      'analysis_batches',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: arguments,
      orderBy: afterId == null ? 'created_at_ms ASC' : 'id ASC',
      limit: limit,
    );
    final batches = <AnalysisBatch>[];
    for (final row in rows) {
      batches.add(await _batchFromRow(db, row));
    }
    return batches;
  }

  @override
  Future<List<int>> listStandaloneFailedChunkIds({
    required int updatedBeforeOrAtMs,
    int? afterId,
    int limit = 100,
  }) async {
    _requirePositiveLimit(limit);
    final db = await database.open();
    final rows = await db.rawQuery(
      '''
      SELECT chunks.id
      FROM capture_chunks AS chunks
      WHERE chunks.status = ?
        AND chunks.updated_at_ms <= ?
        AND chunks.id > ?
        AND NOT EXISTS (
          SELECT 1
          FROM analysis_batch_chunks AS links
          WHERE links.chunk_id = chunks.id
        )
      ORDER BY chunks.id ASC
      LIMIT ?
      ''',
      <Object?>[
        ProcessingStatus.failed.name,
        updatedBeforeOrAtMs,
        afterId ?? 0,
        limit,
      ],
    );
    return rows.map((row) => row['id']! as int).toList(growable: false);
  }

  @override
  Future<List<AnalysisQueueEntry>> listAnalysisQueue({int? limit}) async {
    if (limit != null) _requirePositiveLimit(limit);
    final db = await database.open();
    final limitClause = limit == null ? '' : 'LIMIT ?';
    final rows = await db.rawQuery('''
      WITH latest_batch_links AS (
        SELECT chunk_id, MAX(batch_id) AS batch_id
        FROM analysis_batch_chunks
        GROUP BY chunk_id
      ), queue_entries AS (
        SELECT
          chunks.id AS queue_chunk_id,
          links.batch_id AS queue_batch_id,
          chunks.status AS queue_status,
          chunks.started_at_ms AS queue_started_at_ms,
          chunks.ended_at_ms AS queue_ended_at_ms,
          chunks.created_at_ms AS queue_enqueued_at_ms,
          CASE
            WHEN batches.status = chunks.status
              AND batches.updated_at_ms > chunks.updated_at_ms
              THEN batches.updated_at_ms
            ELSE chunks.updated_at_ms
          END AS queue_updated_at_ms,
          CASE
            WHEN batches.status = chunks.status
              AND batches.retry_count > chunks.retry_count
              THEN batches.retry_count
            ELSE chunks.retry_count
          END AS queue_retry_count,
          CASE
            WHEN chunks.status = 'processing'
              THEN COALESCE(
                chunks.processing_started_at_ms,
                CASE
                  WHEN batches.status = 'processing'
                    THEN batches.processing_started_at_ms
                END
              )
          END AS queue_processing_started_at_ms,
          CASE
            WHEN chunks.status = 'failed'
              THEN COALESCE(
                chunks.error_message,
                CASE
                  WHEN batches.status = 'failed' THEN batches.error_message
                END
              )
          END AS queue_error_message
        FROM capture_chunks AS chunks
        LEFT JOIN latest_batch_links AS links
          ON links.chunk_id = chunks.id
        LEFT JOIN analysis_batches AS batches
          ON batches.id = links.batch_id
        WHERE chunks.status IN ('processing', 'pending', 'failed')
      )
      SELECT *
      FROM queue_entries
      ORDER BY
        CASE queue_status
          WHEN 'processing' THEN 0
          WHEN 'pending' THEN 1
          ELSE 2
        END ASC,
        CASE
          WHEN queue_status = 'processing'
            THEN COALESCE(
              queue_processing_started_at_ms,
              queue_enqueued_at_ms
            )
        END ASC,
        CASE
          WHEN queue_status = 'pending' THEN queue_enqueued_at_ms
        END ASC,
        CASE
          WHEN queue_status = 'failed' THEN queue_updated_at_ms
        END DESC,
        queue_chunk_id ASC
      $limitClause
      ''', limit == null ? const <Object?>[] : <Object?>[limit]);
    return rows.map(_analysisQueueEntryFromRow).toList(growable: false);
  }

  @override
  Future<List<Observation>> listObservationsForBatch(int batchId) async {
    final db = await database.open();
    final rows = await db.query(
      'observations',
      where: 'batch_id = ?',
      whereArgs: [batchId],
      orderBy: 'ordinal ASC',
    );
    return rows.map(_observationFromRow).toList(growable: false);
  }

  @override
  Future<void> markAnalysisFailed(
    int batchId,
    String errorMessage, {
    int? nextRetryAtMs,
  }) async {
    final error = requireNonBlank(errorMessage, 'errorMessage');
    final now = clock.nowUtcEpochMs();
    await database.transaction((transaction) async {
      final batchUpdated = await transaction.rawUpdate(
        '''
        UPDATE analysis_batches
        SET status = ?, retry_count = retry_count + 1,
            error_message = ?, completed_at_ms = ?, updated_at_ms = ?
        WHERE id = ? AND status IN (?, ?)
        ''',
        [
          ProcessingStatus.failed.name,
          error,
          now,
          now,
          batchId,
          ProcessingStatus.pending.name,
          ProcessingStatus.processing.name,
        ],
      );
      if (batchUpdated != 1) {
        throw StateError('Batch $batchId is not pending or processing');
      }
      await transaction.rawUpdate(
        '''
        UPDATE capture_chunks
        SET status = ?, retry_count = retry_count + 1,
            next_retry_at_ms = ?, error_message = ?,
            processing_started_at_ms = NULL, completed_at_ms = NULL,
            updated_at_ms = ?
        WHERE id IN (
          SELECT chunk_id FROM analysis_batch_chunks WHERE batch_id = ?
        ) AND status = ?
        ''',
        [
          ProcessingStatus.failed.name,
          nextRetryAtMs,
          error,
          now,
          batchId,
          ProcessingStatus.processing.name,
        ],
      );
    });
  }

  @override
  Future<bool> retryBatch(int batchId) async {
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final batchUpdated = await transaction.update(
        'analysis_batches',
        {
          'status': ProcessingStatus.processing.name,
          'error_message': null,
          'processing_started_at_ms': now,
          'completed_at_ms': null,
          'updated_at_ms': now,
        },
        where: 'id = ? AND status = ?',
        whereArgs: [batchId, ProcessingStatus.failed.name],
      );
      if (batchUpdated != 1) {
        return false;
      }
      final chunkRows = await transaction.rawQuery(
        '''
        SELECT c.id, c.status
        FROM capture_chunks c
        JOIN analysis_batch_chunks bc ON bc.chunk_id = c.id
        WHERE bc.batch_id = ?
        ''',
        [batchId],
      );
      if (chunkRows.isEmpty ||
          chunkRows.any(
            (row) => row['status'] != ProcessingStatus.failed.name,
          )) {
        throw StateError('All batch chunks must be failed before retry');
      }
      await transaction.rawUpdate(
        '''
        UPDATE capture_chunks
        SET status = ?, next_retry_at_ms = NULL, error_message = NULL,
            processing_started_at_ms = ?, completed_at_ms = NULL,
            updated_at_ms = ?
        WHERE id IN (
          SELECT chunk_id FROM analysis_batch_chunks WHERE batch_id = ?
        )
        ''',
        [ProcessingStatus.processing.name, now, now, batchId],
      );
      return true;
    });
  }

  @override
  Future<AnalysisBatch?> retryStandaloneFailedChunk(int chunkId) async {
    final now = clock.nowUtcEpochMs();
    final batchId = await database.transaction((transaction) async {
      final chunkRows = await transaction.rawQuery(
        '''
        SELECT id
        FROM capture_chunks AS chunks
        WHERE id = ? AND status = ?
          AND NOT EXISTS (
            SELECT 1 FROM analysis_batch_chunks AS links
            WHERE links.chunk_id = chunks.id
          )
        ''',
        <Object?>[chunkId, ProcessingStatus.failed.name],
      );
      if (chunkRows.length != 1) return null;
      final id = await transaction.insert('analysis_batches', <String, Object?>{
        'status': ProcessingStatus.processing.name,
        'retry_count': 0,
        'processing_started_at_ms': now,
        'created_at_ms': now,
        'updated_at_ms': now,
      });
      final updated = await transaction.update(
        'capture_chunks',
        <String, Object?>{
          'status': ProcessingStatus.processing.name,
          'next_retry_at_ms': null,
          'error_message': null,
          'processing_started_at_ms': now,
          'completed_at_ms': null,
          'updated_at_ms': now,
        },
        where: 'id = ? AND status = ?',
        whereArgs: <Object?>[chunkId, ProcessingStatus.failed.name],
      );
      if (updated != 1) {
        throw StateError('Failed chunk state changed during retry');
      }
      await transaction.insert('analysis_batch_chunks', <String, Object?>{
        'batch_id': id,
        'chunk_id': chunkId,
        'ordinal': 0,
      });
      return id;
    });
    return batchId == null ? null : getBatch(batchId);
  }

  @override
  Future<bool> deleteFailedBatch(int batchId) {
    return database.transaction((transaction) async {
      final batchRows = await transaction.query(
        'analysis_batches',
        columns: const <String>['status'],
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
        limit: 1,
      );
      if (batchRows.isEmpty ||
          batchRows.single['status'] != ProcessingStatus.failed.name) {
        return false;
      }
      final chunkRows = await transaction.rawQuery(
        '''
        SELECT c.id, c.status
        FROM capture_chunks AS c
        JOIN analysis_batch_chunks AS bc ON bc.chunk_id = c.id
        WHERE bc.batch_id = ?
        ORDER BY bc.ordinal ASC
        ''',
        <Object?>[batchId],
      );
      if (chunkRows.isEmpty ||
          chunkRows.any(
            (row) => row['status'] != ProcessingStatus.failed.name,
          )) {
        return false;
      }
      final chunkIds = chunkRows
          .map((row) => row['id']! as int)
          .toList(growable: false);
      await transaction.delete(
        'analysis_batch_chunks',
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
      final batchDeleted = await transaction.delete(
        'analysis_batches',
        where: 'id = ? AND status = ?',
        whereArgs: <Object?>[batchId, ProcessingStatus.failed.name],
      );
      if (batchDeleted != 1) {
        throw StateError('Failed batch state changed during deletion');
      }
      final chunksDeleted = await transaction.delete(
        'capture_chunks',
        where:
            'id IN (${_placeholders(chunkIds.length)}) AND status = ? '
            'AND NOT EXISTS ('
            'SELECT 1 FROM analysis_batch_chunks AS links '
            'WHERE links.chunk_id = capture_chunks.id)',
        whereArgs: <Object?>[...chunkIds, ProcessingStatus.failed.name],
      );
      if (chunksDeleted != chunkIds.length) {
        throw StateError('Failed batch chunks changed during deletion');
      }
      return true;
    });
  }

  @override
  Future<bool> deleteFailedChunk(int chunkId) async {
    final db = await database.open();
    return await db.delete(
          'capture_chunks',
          where:
              'id = ? AND status = ? AND NOT EXISTS ('
              'SELECT 1 FROM analysis_batch_chunks AS links '
              'WHERE links.chunk_id = capture_chunks.id)',
          whereArgs: <Object?>[chunkId, ProcessingStatus.failed.name],
        ) ==
        1;
  }

  @override
  Future<AnalysisCommitResult> completeAnalysis({
    required int batchId,
    required List<Observation> observations,
    required List<TimelineCard> cards,
  }) async {
    if (observations.isEmpty) {
      throw ArgumentError.value(
        observations,
        'observations',
        'must not be empty',
      );
    }
    if (cards.isEmpty) {
      throw ArgumentError.value(cards, 'cards', 'must not be empty');
    }
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final batchRows = await transaction.query(
        'analysis_batches',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [batchId],
        limit: 1,
      );
      if (batchRows.isEmpty ||
          batchRows.single['status'] != ProcessingStatus.processing.name) {
        throw StateError('Batch $batchId is not processing');
      }
      final chunkRows = await transaction.query(
        'analysis_batch_chunks',
        columns: ['chunk_id'],
        where: 'batch_id = ?',
        whereArgs: [batchId],
        orderBy: 'ordinal ASC',
      );
      final chunkIds = chunkRows
          .map((row) => row['chunk_id']! as int)
          .toList(growable: false);
      if (chunkIds.isEmpty) {
        throw StateError('Batch $batchId has no chunks');
      }
      final chunkIdSet = chunkIds.toSet();
      if (observations.any(
        (observation) =>
            !chunkIdSet.contains(observation.chunkId) ||
            (observation.batchId != null && observation.batchId != batchId),
      )) {
        throw ArgumentError(
          'Observation references a chunk outside this batch',
        );
      }
      if (cards.any(
        (card) => card.batchId != null && card.batchId != batchId,
      )) {
        throw ArgumentError('Card references a different batch');
      }
      final chunkStates = await transaction.query(
        'capture_chunks',
        columns: ['id', 'status'],
        where: 'id IN (${_placeholders(chunkIds.length)})',
        whereArgs: chunkIds,
      );
      if (chunkStates.length != chunkIds.length ||
          chunkStates.any(
            (row) => row['status'] != ProcessingStatus.processing.name,
          )) {
        throw StateError('All batch chunks must still be processing');
      }

      await transaction.delete(
        'observations',
        where: 'batch_id = ?',
        whereArgs: [batchId],
      );
      await transaction.delete(
        'timeline_cards',
        where: 'batch_id = ?',
        whereArgs: [batchId],
      );

      final observationIds = <int>[];
      for (var index = 0; index < observations.length; index++) {
        final observation = observations[index];
        observationIds.add(
          await transaction.insert('observations', {
            'batch_id': batchId,
            'chunk_id': observation.chunkId,
            'ordinal': index,
            'started_at_ms': observation.startedAtMs,
            'ended_at_ms': observation.endedAtMs,
            'description': observation.description,
            'app_name': observation.appName,
            'process_name': observation.processName,
            'process_path': observation.processPath,
            'window_title': observation.windowTitle,
            'confidence': observation.confidence,
            'created_at_ms': observation.createdAtMs,
          }),
        );
      }

      final insertedCardIds = <int>[];
      final affectedDates = <String>{};
      for (var index = 0; index < cards.length; index++) {
        final card = cards[index];
        affectedDates.add(card.reportDate);
        insertedCardIds.add(
          await transaction.insert('timeline_cards', {
            'batch_id': batchId,
            'ordinal': index,
            'report_date': card.reportDate,
            'category': card.category,
            'title': card.title,
            'summary': card.summary,
            'started_at_ms': card.startedAtMs,
            'ended_at_ms': card.endedAtMs,
            'app_usages_json': jsonEncode(
              card.appUsages.map((usage) => usage.toJson()).toList(),
            ),
            'distractions_json': jsonEncode(
              card.distractions.map((item) => item.toJson()).toList(),
            ),
            'productivity_score': card.productivityScore,
            'created_at_ms': card.createdAtMs,
            'updated_at_ms': card.updatedAtMs,
            'source_duration_ms': card.durationMs,
          }),
        );
      }

      final chunksUpdated = await transaction.update(
        'capture_chunks',
        {
          'status': ProcessingStatus.completed.name,
          'error_message': null,
          'next_retry_at_ms': null,
          'processing_started_at_ms': null,
          'completed_at_ms': now,
          'updated_at_ms': now,
        },
        where: 'id IN (${_placeholders(chunkIds.length)}) AND status = ?',
        whereArgs: [...chunkIds, ProcessingStatus.processing.name],
      );
      if (chunksUpdated != chunkIds.length) {
        throw StateError('Failed to complete every chunk in batch $batchId');
      }
      final batchUpdated = await transaction.update(
        'analysis_batches',
        {
          'status': ProcessingStatus.completed.name,
          'error_message': null,
          'processing_started_at_ms': null,
          'completed_at_ms': now,
          'updated_at_ms': now,
        },
        where: 'id = ? AND status = ?',
        whereArgs: [batchId, ProcessingStatus.processing.name],
      );
      if (batchUpdated != 1) {
        throw StateError('Failed to complete batch $batchId');
      }
      final survivingCardIds = <int>[];
      for (final reportDate in affectedDates) {
        survivingCardIds.addAll(
          await _mergeTimelineCardsForDate(
            transaction,
            reportDate: reportDate,
            insertedCardIds: insertedCardIds.toSet(),
            now: now,
          ),
        );
        await _bumpTimelineRevision(transaction, reportDate, now);
      }
      return AnalysisCommitResult(
        observationIds: List.unmodifiable(observationIds),
        cardIds: List.unmodifiable(survivingCardIds),
        completedChunkIds: List.unmodifiable(chunkIds),
      );
    });
  }

  @override
  Future<RecoverySummary> recoverInterruptedWork({
    String reason = '应用异常退出，已保留原始证据，可重试分析',
  }) async {
    final error = requireNonBlank(reason, 'reason');
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final sessionsFailed = await transaction.rawUpdate(
        '''
        UPDATE capture_sessions
        SET status = ?, ended_at_ms = COALESCE(ended_at_ms, ?),
            error_message = ?, updated_at_ms = ?
        WHERE status IN (?, ?)
        ''',
        [
          CaptureSessionStatus.failed.name,
          now,
          error,
          now,
          CaptureSessionStatus.recording.name,
          CaptureSessionStatus.paused.name,
        ],
      );
      final batchesFailed = await transaction.rawUpdate(
        '''
        UPDATE analysis_batches
        SET status = ?, retry_count = retry_count + 1,
            error_message = ?, processing_started_at_ms = NULL,
            completed_at_ms = ?, updated_at_ms = ?
        WHERE status = ?
        ''',
        [
          ProcessingStatus.failed.name,
          error,
          now,
          now,
          ProcessingStatus.processing.name,
        ],
      );
      final chunksFailed = await transaction.rawUpdate(
        '''
        UPDATE capture_chunks
        SET status = ?, retry_count = retry_count + 1,
            error_message = ?, processing_started_at_ms = NULL,
            completed_at_ms = NULL, updated_at_ms = ?
        WHERE status = ?
        ''',
        [
          ProcessingStatus.failed.name,
          error,
          now,
          ProcessingStatus.processing.name,
        ],
      );
      return RecoverySummary(
        sessionsFailed: sessionsFailed,
        chunksFailed: chunksFailed,
        batchesFailed: batchesFailed,
      );
    });
  }

  @override
  Future<TimelineCard?> getCard(int id) async {
    final db = await database.open();
    final rows = await db.query(
      'timeline_cards',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _cardFromRow(rows.single);
  }

  @override
  Future<List<TimelineCard>> listCardsForReportDate(String reportDate) async {
    final date = requireReportDate(reportDate);
    final db = await database.open();
    final rows = await db.query(
      'timeline_cards',
      where: 'report_date = ?',
      whereArgs: [date],
      orderBy: 'started_at_ms ASC',
    );
    return rows.map(_cardFromRow).toList(growable: false);
  }

  @override
  Future<List<TimelineCard>> listCardsBetween(int startMs, int endMs) async {
    requireEpochRange(startedAtMs: startMs, endedAtMs: endMs);
    final db = await database.open();
    final rows = await db.query(
      'timeline_cards',
      where: 'ended_at_ms > ? AND started_at_ms < ?',
      whereArgs: [startMs, endMs],
      orderBy: 'started_at_ms ASC',
    );
    return rows.map(_cardFromRow).toList(growable: false);
  }

  @override
  Future<List<TimelineCard>> getRecentCards({int limit = 10}) async {
    _requirePositiveLimit(limit);
    final db = await database.open();
    final rows = await db.query(
      'timeline_cards',
      orderBy: 'ended_at_ms DESC',
      limit: limit,
    );
    return rows.map(_cardFromRow).toList().reversed.toList(growable: false);
  }

  @override
  Future<bool> updateCard(TimelineCard card) async {
    final id = card.id;
    if (id == null) {
      throw ArgumentError.value(id, 'card.id', 'must not be null');
    }
    return updateTimelineCard(
      id: id,
      category: card.category,
      title: card.title,
      summary: card.summary,
      productivityScore: card.productivityScore,
    );
  }

  @override
  Future<bool> updateTimelineCard({
    required int id,
    required String category,
    required String title,
    required String summary,
    required double productivityScore,
  }) async {
    if (id <= 0) {
      throw ArgumentError.value(id, 'id', 'must be positive');
    }
    final normalizedCategory = requireNonBlank(category, 'category');
    if (!timelineCategories.contains(normalizedCategory)) {
      throw ArgumentError.value(category, 'category', 'unsupported category');
    }
    final normalizedTitle = requireNonBlank(title, 'title');
    final normalizedSummary = summary.trim();
    requireScore(productivityScore, 'productivityScore');
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final existingRows = await transaction.query(
        'timeline_cards',
        columns: ['report_date'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existingRows.isEmpty) {
        return false;
      }
      final reportDate = existingRows.single['report_date']! as String;
      final updated = await transaction.update(
        'timeline_cards',
        {
          'category': normalizedCategory,
          'title': normalizedTitle,
          'summary': normalizedSummary,
          'productivity_score': productivityScore,
          'updated_at_ms': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (updated != 1) {
        throw StateError('Timeline card $id could not be updated');
      }
      await _bumpTimelineRevision(transaction, reportDate, now);
      return true;
    });
  }

  @override
  Future<bool> deleteCard(int id) async {
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final rows = await transaction.query(
        'timeline_cards',
        columns: ['report_date'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) {
        return false;
      }
      final reportDate = rows.single['report_date']! as String;
      await transaction.delete(
        'timeline_cards',
        where: 'id = ?',
        whereArgs: [id],
      );
      await _bumpTimelineRevision(transaction, reportDate, now);
      return true;
    });
  }

  @override
  Future<int> getTimelineRevision(String reportDate) async {
    final date = requireReportDate(reportDate);
    final db = await database.open();
    final rows = await db.query(
      'timeline_day_revisions',
      columns: ['revision'],
      where: 'report_date = ?',
      whereArgs: [date],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.single['revision']! as int;
  }

  @override
  Future<DailyReport?> getDailyReport(String reportDate) async {
    final date = requireReportDate(reportDate);
    final db = await database.open();
    final rows = await db.rawQuery(
      '''
      SELECT r.*,
             COALESCE(v.revision, 0) AS current_revision
      FROM daily_reports r
      LEFT JOIN timeline_day_revisions v ON v.report_date = r.report_date
      WHERE r.report_date = ?
      LIMIT 1
      ''',
      [date],
    );
    return rows.isEmpty ? null : _dailyReportFromRow(rows.single);
  }

  @override
  Future<DailyReport> saveDailyReport({
    required String reportDate,
    required String content,
    required String model,
    int? expectedRevision,
  }) async {
    final date = requireReportDate(reportDate);
    final normalizedModel = requireNonBlank(model, 'model');
    final now = clock.nowUtcEpochMs();
    await database.transaction((transaction) async {
      final revision = await _readTimelineRevision(transaction, date);
      if (expectedRevision != null && revision != expectedRevision) {
        throw StateError('Timeline changed while generating report for $date');
      }
      await transaction.rawInsert(
        '''
        INSERT INTO daily_reports(
          report_date, content, source_revision, generated_at_ms,
          model, invalidated_at_ms
        ) VALUES (?, ?, ?, ?, ?, NULL)
        ON CONFLICT(report_date) DO UPDATE SET
          content = excluded.content,
          source_revision = excluded.source_revision,
          generated_at_ms = excluded.generated_at_ms,
          model = excluded.model,
          invalidated_at_ms = NULL
        ''',
        [date, content, revision, now, normalizedModel],
      );
    });
    return (await getDailyReport(date))!;
  }

  @override
  Future<List<DailyReport>> listDailyReports({int limit = 30}) async {
    _requirePositiveLimit(limit);
    final db = await database.open();
    final rows = await db.rawQuery(
      '''
      SELECT r.*, COALESCE(v.revision, 0) AS current_revision
      FROM daily_reports r
      LEFT JOIN timeline_day_revisions v ON v.report_date = r.report_date
      ORDER BY r.report_date DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map(_dailyReportFromRow).toList(growable: false);
  }

  @override
  Future<bool> deleteDailyReport(String reportDate) async {
    final db = await database.open();
    return await db.delete(
          'daily_reports',
          where: 'report_date = ?',
          whereArgs: [requireReportDate(reportDate)],
        ) ==
        1;
  }

  @override
  Future<int> invalidateDailyReport(String reportDate) async {
    final date = requireReportDate(reportDate);
    final now = clock.nowUtcEpochMs();
    return database.transaction(
      (transaction) => _bumpTimelineRevision(transaction, date, now),
    );
  }

  @override
  Future<DailyReportJob> enqueueDailyReportJob(String reportDate) async {
    final date = requireReportDate(reportDate);
    final now = clock.nowUtcEpochMs();
    final db = await database.open();
    await db.rawInsert(
      '''
      INSERT INTO daily_report_jobs(
        report_date, status, retry_count, requested_at_ms, updated_at_ms
      ) VALUES (?, 'pending', 0, ?, ?)
      ON CONFLICT(report_date) DO UPDATE SET
        status = 'pending',
        retry_count = 0,
        error_category = NULL,
        error_summary = NULL,
        requested_at_ms = excluded.requested_at_ms,
        updated_at_ms = excluded.updated_at_ms,
        processing_started_at_ms = NULL
      WHERE daily_report_jobs.status = 'failed'
      ''',
      <Object?>[date, now, now],
    );
    return (await getDailyReportJob(date))!;
  }

  @override
  Future<DailyReportJob?> getDailyReportJob(String reportDate) async {
    final db = await database.open();
    final rows = await db.query(
      'daily_report_jobs',
      where: 'report_date = ?',
      whereArgs: <Object?>[requireReportDate(reportDate)],
      limit: 1,
    );
    return rows.isEmpty ? null : _dailyReportJobFromRow(rows.single);
  }

  @override
  Future<List<DailyReportJob>> listDailyReportJobs() async {
    final db = await database.open();
    final rows = await db.rawQuery('''
      SELECT * FROM daily_report_jobs
      ORDER BY CASE status
        WHEN 'processing' THEN 0
        WHEN 'pending' THEN 1
        ELSE 2
      END, requested_at_ms ASC, report_date ASC
    ''');
    return rows.map(_dailyReportJobFromRow).toList(growable: false);
  }

  @override
  Future<DailyReportJob?> claimNextDailyReportJob() {
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final rows = await transaction.query(
        'daily_report_jobs',
        columns: <String>['report_date'],
        where: 'status = ?',
        whereArgs: <Object?>[DailyReportJobStatus.pending.name],
        orderBy: 'requested_at_ms ASC, report_date ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final date = rows.single['report_date']! as String;
      final claimed = await transaction.update(
        'daily_report_jobs',
        <String, Object?>{
          'status': DailyReportJobStatus.processing.name,
          'updated_at_ms': now,
          'processing_started_at_ms': now,
        },
        where: 'report_date = ? AND status = ?',
        whereArgs: <Object?>[date, DailyReportJobStatus.pending.name],
      );
      if (claimed != 1) return null;
      final claimedRows = await transaction.query(
        'daily_report_jobs',
        where: 'report_date = ?',
        whereArgs: <Object?>[date],
        limit: 1,
      );
      return _dailyReportJobFromRow(claimedRows.single);
    });
  }

  @override
  Future<DailyReportJob?> claimPendingDailyReportJob(String reportDate) {
    final date = requireReportDate(reportDate);
    final now = clock.nowUtcEpochMs();
    return database.transaction((transaction) async {
      final claimed = await transaction.update(
        'daily_report_jobs',
        <String, Object?>{
          'status': DailyReportJobStatus.processing.name,
          'updated_at_ms': now,
          'processing_started_at_ms': now,
        },
        where: 'report_date = ? AND status = ?',
        whereArgs: <Object?>[date, DailyReportJobStatus.pending.name],
      );
      if (claimed != 1) return null;
      final rows = await transaction.query(
        'daily_report_jobs',
        where: 'report_date = ?',
        whereArgs: <Object?>[date],
        limit: 1,
      );
      return _dailyReportJobFromRow(rows.single);
    });
  }

  @override
  Future<bool> completeDailyReportJob(String reportDate) async {
    final db = await database.open();
    return await db.delete(
          'daily_report_jobs',
          where: 'report_date = ? AND status = ?',
          whereArgs: <Object?>[
            requireReportDate(reportDate),
            DailyReportJobStatus.processing.name,
          ],
        ) ==
        1;
  }

  @override
  Future<bool> markDailyReportJobFailed(
    String reportDate, {
    required String category,
    required String summary,
  }) async {
    final db = await database.open();
    return await db.rawUpdate(
          '''
          UPDATE daily_report_jobs
          SET status = ?, retry_count = retry_count + 1,
              error_category = ?, error_summary = ?, updated_at_ms = ?,
              processing_started_at_ms = NULL
          WHERE report_date = ? AND status = ?
          ''',
          <Object?>[
            DailyReportJobStatus.failed.name,
            requireNonBlank(category, 'category'),
            requireNonBlank(summary, 'summary'),
            clock.nowUtcEpochMs(),
            requireReportDate(reportDate),
            DailyReportJobStatus.processing.name,
          ],
        ) ==
        1;
  }

  @override
  Future<int> retryFailedDailyReportJobs() async {
    final db = await database.open();
    return db.update(
      'daily_report_jobs',
      <String, Object?>{
        'status': DailyReportJobStatus.pending.name,
        'error_category': null,
        'error_summary': null,
        'updated_at_ms': clock.nowUtcEpochMs(),
        'processing_started_at_ms': null,
      },
      where: 'status = ?',
      whereArgs: <Object?>[DailyReportJobStatus.failed.name],
    );
  }

  @override
  Future<bool> retryFailedDailyReportJob(String reportDate) async {
    final db = await database.open();
    final now = clock.nowUtcEpochMs();
    return await db.update(
          'daily_report_jobs',
          <String, Object?>{
            'status': DailyReportJobStatus.processing.name,
            'error_category': null,
            'error_summary': null,
            'updated_at_ms': now,
            'processing_started_at_ms': now,
          },
          where: 'report_date = ? AND status = ?',
          whereArgs: <Object?>[
            requireReportDate(reportDate),
            DailyReportJobStatus.failed.name,
          ],
        ) ==
        1;
  }

  @override
  Future<bool> deleteFailedDailyReportJob(String reportDate) async {
    final db = await database.open();
    return await db.delete(
          'daily_report_jobs',
          where: 'report_date = ? AND status = ?',
          whereArgs: <Object?>[
            requireReportDate(reportDate),
            DailyReportJobStatus.failed.name,
          ],
        ) ==
        1;
  }

  @override
  Future<int> recoverInterruptedDailyReportJobs() async {
    final db = await database.open();
    return db.update(
      'daily_report_jobs',
      <String, Object?>{
        'status': DailyReportJobStatus.pending.name,
        'updated_at_ms': clock.nowUtcEpochMs(),
        'processing_started_at_ms': null,
      },
      where: 'status = ?',
      whereArgs: <Object?>[DailyReportJobStatus.processing.name],
    );
  }

  SettingRecord _settingFromRow(Map<String, Object?> row) {
    return SettingRecord(
      key: row['key']! as String,
      value: row['value']! as String,
      updatedAtMs: row['updated_at_ms']! as int,
    );
  }

  CaptureSession _sessionFromRow(Map<String, Object?> row) {
    return CaptureSession(
      id: row['id']! as int,
      captureScope: row['capture_scope']! as String,
      captureDirectory: row['capture_directory']! as String,
      startedAtMs: row['started_at_ms']! as int,
      endedAtMs: row['ended_at_ms'] as int?,
      status: CaptureSessionStatus.fromStorage(row['status']! as String),
      errorMessage: row['error_message'] as String?,
      createdAtMs: row['created_at_ms']! as int,
      updatedAtMs: row['updated_at_ms']! as int,
    );
  }

  CaptureChunk _chunkFromRow(Map<String, Object?> row) {
    return CaptureChunk(
      id: row['id']! as int,
      sessionId: row['session_id']! as int,
      framesDirectory: row['frames_directory']! as String,
      metadataPath: row['metadata_path']! as String,
      videoPath: row['video_path'] as String?,
      startedAtMs: row['started_at_ms']! as int,
      endedAtMs: row['ended_at_ms']! as int,
      frameCount: row['frame_count']! as int,
      status: ProcessingStatus.fromStorage(row['status']! as String),
      retryCount: row['retry_count']! as int,
      nextRetryAtMs: row['next_retry_at_ms'] as int?,
      errorMessage: row['error_message'] as String?,
      processingStartedAtMs: row['processing_started_at_ms'] as int?,
      completedAtMs: row['completed_at_ms'] as int?,
      evidencePurgedAtMs: row['evidence_purged_at_ms'] as int?,
      createdAtMs: row['created_at_ms']! as int,
      updatedAtMs: row['updated_at_ms']! as int,
    );
  }

  Future<AnalysisBatch> _batchFromRow(
    DatabaseExecutor executor,
    Map<String, Object?> row,
  ) async {
    final chunkRows = await executor.query(
      'analysis_batch_chunks',
      columns: ['chunk_id'],
      where: 'batch_id = ?',
      whereArgs: [row['id']],
      orderBy: 'ordinal ASC',
    );
    return AnalysisBatch(
      id: row['id']! as int,
      chunkIds: chunkRows
          .map((chunk) => chunk['chunk_id']! as int)
          .toList(growable: false),
      status: ProcessingStatus.fromStorage(row['status']! as String),
      retryCount: row['retry_count']! as int,
      errorMessage: row['error_message'] as String?,
      processingStartedAtMs: row['processing_started_at_ms'] as int?,
      completedAtMs: row['completed_at_ms'] as int?,
      createdAtMs: row['created_at_ms']! as int,
      updatedAtMs: row['updated_at_ms']! as int,
    );
  }

  AnalysisQueueEntry _analysisQueueEntryFromRow(Map<String, Object?> row) {
    return AnalysisQueueEntry(
      chunkId: row['queue_chunk_id']! as int,
      batchId: row['queue_batch_id'] as int?,
      status: ProcessingStatus.fromStorage(row['queue_status']! as String),
      startedAtMs: row['queue_started_at_ms']! as int,
      endedAtMs: row['queue_ended_at_ms']! as int,
      enqueuedAtMs: row['queue_enqueued_at_ms']! as int,
      updatedAtMs: row['queue_updated_at_ms']! as int,
      retryCount: row['queue_retry_count']! as int,
      processingStartedAtMs: row['queue_processing_started_at_ms'] as int?,
      errorMessage: row['queue_error_message'] as String?,
    );
  }

  Observation _observationFromRow(Map<String, Object?> row) {
    return Observation(
      id: row['id']! as int,
      batchId: row['batch_id']! as int,
      chunkId: row['chunk_id']! as int,
      startedAtMs: row['started_at_ms']! as int,
      endedAtMs: row['ended_at_ms']! as int,
      description: row['description']! as String,
      appName: row['app_name'] as String?,
      processName: row['process_name'] as String?,
      processPath: row['process_path'] as String?,
      windowTitle: row['window_title'] as String?,
      confidence: (row['confidence'] as num?)?.toDouble(),
      createdAtMs: row['created_at_ms']! as int,
    );
  }

  Future<List<int>> _mergeTimelineCardsForDate(
    Transaction transaction, {
    required String reportDate,
    required Set<int> insertedCardIds,
    required int now,
  }) async {
    final rows = await transaction.query(
      'timeline_cards',
      where: 'report_date = ?',
      whereArgs: <Object?>[reportDate],
      orderBy: 'started_at_ms ASC, ended_at_ms ASC, id ASC',
    );
    if (rows.isEmpty) return const <int>[];

    final mergedRows = <_StoredTimelineCard>[];
    var current = _storedTimelineCardFromRow(rows.first);
    for (final row in rows.skip(1)) {
      final next = _storedTimelineCardFromRow(row);
      var shouldMerge = _sameActivity(current.card, next.card);
      if (shouldMerge && next.card.startedAtMs > current.card.endedAtMs) {
        shouldMerge = !await _hasIncompleteChunkInGap(
          transaction,
          current.card.endedAtMs,
          next.card.startedAtMs,
        );
      }
      if (shouldMerge) {
        current = _mergeStoredTimelineCards(current, next, now);
      } else {
        mergedRows.add(current);
        current = next;
      }
    }
    mergedRows.add(current);

    final survivingInsertedIds = <int>[];
    for (final merged in mergedRows) {
      if (merged.sourceIds.any(insertedCardIds.contains)) {
        survivingInsertedIds.add(merged.card.id!);
      }
      if (merged.sourceIds.length == 1) continue;
      await transaction.update(
        'timeline_cards',
        <String, Object?>{
          'category': merged.card.category,
          'title': merged.card.title,
          'summary': merged.card.summary,
          'started_at_ms': merged.card.startedAtMs,
          'ended_at_ms': merged.card.endedAtMs,
          'app_usages_json': jsonEncode(
            merged.card.appUsages.map((usage) => usage.toJson()).toList(),
          ),
          'distractions_json': jsonEncode(
            merged.card.distractions.map((item) => item.toJson()).toList(),
          ),
          'productivity_score': merged.card.productivityScore,
          'created_at_ms': merged.card.createdAtMs,
          'updated_at_ms': merged.card.updatedAtMs,
          'source_duration_ms': merged.sourceDurationMs,
        },
        where: 'id = ?',
        whereArgs: <Object?>[merged.card.id],
      );
      final absorbedIds = merged.sourceIds
          .where((id) => id != merged.card.id)
          .toList(growable: false);
      await transaction.delete(
        'timeline_cards',
        where: 'id IN (${_placeholders(absorbedIds.length)})',
        whereArgs: absorbedIds,
      );
    }
    return List<int>.unmodifiable(survivingInsertedIds);
  }

  _StoredTimelineCard _storedTimelineCardFromRow(Map<String, Object?> row) {
    final card = _cardFromRow(row);
    final storedDuration = row['source_duration_ms'] as int?;
    return _StoredTimelineCard(
      card: card,
      ordinal: row['ordinal']! as int,
      sourceDurationMs: storedDuration == null || storedDuration <= 0
          ? card.durationMs
          : storedDuration,
      sourceIds: <int>{card.id!},
    );
  }

  Future<bool> _hasIncompleteChunkInGap(
    DatabaseExecutor executor,
    int gapStartMs,
    int gapEndMs,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT 1
      FROM capture_chunks
      WHERE status IN (?, ?, ?)
        AND started_at_ms < ?
        AND ended_at_ms > ?
      LIMIT 1
      ''',
      <Object?>[
        ProcessingStatus.pending.name,
        ProcessingStatus.processing.name,
        ProcessingStatus.failed.name,
        gapEndMs,
        gapStartMs,
      ],
    );
    return rows.isNotEmpty;
  }

  TimelineCard _cardFromRow(Map<String, Object?> row) {
    final usages = (jsonDecode(row['app_usages_json']! as String) as List)
        .map(
          (item) => AppUsage.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
    final distractions =
        (jsonDecode(row['distractions_json']! as String) as List)
            .map(
              (item) =>
                  Distraction.fromJson(Map<String, Object?>.from(item as Map)),
            )
            .toList(growable: false);
    return TimelineCard(
      id: row['id']! as int,
      batchId: row['batch_id']! as int,
      reportDate: row['report_date']! as String,
      category: row['category']! as String,
      title: row['title']! as String,
      summary: row['summary']! as String,
      startedAtMs: row['started_at_ms']! as int,
      endedAtMs: row['ended_at_ms']! as int,
      appUsages: usages,
      distractions: distractions,
      productivityScore: (row['productivity_score']! as num).toDouble(),
      createdAtMs: row['created_at_ms']! as int,
      updatedAtMs: row['updated_at_ms']! as int,
    );
  }

  DailyReport _dailyReportFromRow(Map<String, Object?> row) {
    return DailyReport(
      reportDate: row['report_date']! as String,
      content: row['content']! as String,
      sourceRevision: row['source_revision']! as int,
      currentRevision: row['current_revision']! as int,
      generatedAtMs: row['generated_at_ms']! as int,
      model: row['model']! as String,
      invalidatedAtMs: row['invalidated_at_ms'] as int?,
    );
  }

  DailyReportJob _dailyReportJobFromRow(Map<String, Object?> row) {
    return DailyReportJob(
      reportDate: row['report_date']! as String,
      status: DailyReportJobStatus.values.byName(row['status']! as String),
      retryCount: row['retry_count']! as int,
      errorCategory: row['error_category'] as String?,
      errorSummary: row['error_summary'] as String?,
      requestedAtMs: row['requested_at_ms']! as int,
      updatedAtMs: row['updated_at_ms']! as int,
      processingStartedAtMs: row['processing_started_at_ms'] as int?,
    );
  }

  Future<int> _bumpTimelineRevision(
    DatabaseExecutor executor,
    String reportDate,
    int now,
  ) async {
    final date = requireReportDate(reportDate);
    await executor.rawInsert(
      '''
      INSERT INTO timeline_day_revisions(report_date, revision, updated_at_ms)
      VALUES (?, 1, ?)
      ON CONFLICT(report_date) DO UPDATE SET
        revision = timeline_day_revisions.revision + 1,
        updated_at_ms = excluded.updated_at_ms
      ''',
      [date, now],
    );
    await executor.update(
      'daily_reports',
      {'invalidated_at_ms': now},
      where: 'report_date = ?',
      whereArgs: [date],
    );
    return _readTimelineRevision(executor, date);
  }

  Future<int> _readTimelineRevision(
    DatabaseExecutor executor,
    String reportDate,
  ) async {
    final rows = await executor.query(
      'timeline_day_revisions',
      columns: ['revision'],
      where: 'report_date = ?',
      whereArgs: [reportDate],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.single['revision']! as int;
  }

  String _placeholders(int count) => List.filled(count, '?').join(', ');

  void _requirePositiveLimit(int limit) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
  }

  void _requireValidIds(List<int> ids, String fieldName) {
    if (ids.isEmpty || ids.any((id) => id <= 0)) {
      throw ArgumentError.value(ids, fieldName);
    }
    if (ids.toSet().length != ids.length) {
      throw ArgumentError.value(ids, fieldName, 'contains duplicates');
    }
  }
}

final class _StoredTimelineCard {
  const _StoredTimelineCard({
    required this.card,
    required this.ordinal,
    required this.sourceDurationMs,
    required this.sourceIds,
  });

  final TimelineCard card;
  final int ordinal;
  final int sourceDurationMs;
  final Set<int> sourceIds;
}

bool _sameActivity(TimelineCard current, TimelineCard next) {
  if (current.reportDate != next.reportDate ||
      next.startedAtMs - current.endedAtMs > 120000 ||
      _normalizeEventText(current.category) !=
          _normalizeEventText(next.category) ||
      _normalizeEventText(current.title) != _normalizeEventText(next.title)) {
    return false;
  }
  final currentPrimary = _primaryAppIdentity(current.appUsages);
  final nextPrimary = _primaryAppIdentity(next.appUsages);
  if (currentPrimary == null || nextPrimary == null) return false;
  if (currentPrimary.name != nextPrimary.name) return false;
  final currentPath = currentPrimary.path;
  final nextPath = nextPrimary.path;
  return currentPath == null || nextPath == null || currentPath == nextPath;
}

({String name, String? path})? _primaryAppIdentity(List<AppUsage> usages) {
  if (usages.isEmpty) return null;
  var primary = usages.first;
  for (final usage in usages.skip(1)) {
    if (usage.durationMs > primary.durationMs ||
        (usage.durationMs == primary.durationMs &&
            _stableAppIdentity(usage).compareTo(_stableAppIdentity(primary)) <
                0)) {
      primary = usage;
    }
  }
  return (
    name: _normalizeAppName(primary.name),
    path: _normalizeExecutablePath(primary.executablePath),
  );
}

String _stableAppIdentity(AppUsage usage) =>
    '${_normalizeAppName(usage.name)}\u0000${_normalizeExecutablePath(usage.executablePath) ?? ''}';

String _normalizeAppName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s\u3000]+'), ' ');

String? _normalizeExecutablePath(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return p.windows.normalize(normalized).toLowerCase();
}

String _normalizeEventText(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[，。！？、,:;.!?_\-–—]+'), ' ')
    .replaceAll(RegExp(r'[\s\u3000]+'), ' ')
    .trim();

_StoredTimelineCard _mergeStoredTimelineCards(
  _StoredTimelineCard current,
  _StoredTimelineCard next,
  int now,
) {
  final totalSourceDuration = current.sourceDurationMs + next.sourceDurationMs;
  final weightedScore =
      (current.card.productivityScore * current.sourceDurationMs +
          next.card.productivityScore * next.sourceDurationMs) /
      totalSourceDuration;
  return _StoredTimelineCard(
    card: TimelineCard(
      id: current.card.id,
      batchId: current.card.batchId,
      reportDate: current.card.reportDate,
      category: current.card.category,
      title: current.card.title,
      summary: _mergeSummary(current.card.summary, next.card.summary),
      startedAtMs: current.card.startedAtMs,
      endedAtMs: current.card.endedAtMs > next.card.endedAtMs
          ? current.card.endedAtMs
          : next.card.endedAtMs,
      appUsages: _mergeAppUsages(<AppUsage>[
        ...current.card.appUsages,
        ...next.card.appUsages,
      ]),
      distractions: _mergeDistractions(<Distraction>[
        ...current.card.distractions,
        ...next.card.distractions,
      ]),
      productivityScore: weightedScore,
      createdAtMs: current.card.createdAtMs < next.card.createdAtMs
          ? current.card.createdAtMs
          : next.card.createdAtMs,
      updatedAtMs: now,
    ),
    ordinal: current.ordinal,
    sourceDurationMs: totalSourceDuration,
    sourceIds: Set<int>.unmodifiable(<int>{
      ...current.sourceIds,
      ...next.sourceIds,
    }),
  );
}

String _mergeSummary(String current, String next) {
  final lines = <String>[];
  final seen = <String>{};
  for (final line in <String>[...current.split('\n'), ...next.split('\n')]) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (seen.add(_normalizeEventText(trimmed))) lines.add(trimmed);
  }
  return lines.join('\n');
}

List<Distraction> _mergeDistractions(List<Distraction> distractions) {
  final result = <Distraction>[];
  final seen = <String>{};
  for (final distraction in distractions) {
    final key =
        '${_normalizeEventText(distraction.description)}\u0000${distraction.atMs}\u0000${distraction.durationMs}';
    if (seen.add(key)) result.add(distraction);
  }
  return List<Distraction>.unmodifiable(result);
}

List<AppUsage> _mergeAppUsages(List<AppUsage> usages) {
  final knownPaths = <String, Map<String, String>>{};
  for (final usage in usages) {
    final path = usage.executablePath;
    final normalizedPath = _normalizeExecutablePath(path);
    if (normalizedPath == null || path == null) continue;
    knownPaths
        .putIfAbsent(_normalizeAppName(usage.name), () => <String, String>{})
        .putIfAbsent(normalizedPath, () => path);
  }

  final accumulators = <String, _AppUsageAccumulator>{};
  for (final usage in usages) {
    final nameKey = _normalizeAppName(usage.name);
    var pathKey = _normalizeExecutablePath(usage.executablePath);
    var displayPath = usage.executablePath;
    final pathsForName = knownPaths[nameKey];
    if (pathKey == null && pathsForName?.length == 1) {
      pathKey = pathsForName!.keys.single;
      displayPath = pathsForName.values.single;
    }
    final key = '$nameKey\u0000${pathKey ?? ''}';
    accumulators
        .putIfAbsent(key, () => _AppUsageAccumulator(usage.name, displayPath))
        .add(usage);
  }
  return List<AppUsage>.unmodifiable(
    accumulators.values.map((item) => item.build()),
  );
}

final class _AppUsageAccumulator {
  _AppUsageAccumulator(this.name, this.executablePath);

  final String name;
  final String? executablePath;
  int durationMs = 0;
  double cpuTotal = 0;
  int cpuWeightMs = 0;
  double? peakCpu;
  double memoryTotal = 0;
  int memoryWeightMs = 0;
  int? peakMemory;

  void add(AppUsage usage) {
    durationMs += usage.durationMs;
    final cpu = usage.averageCpuUsagePercent;
    if (cpu != null && usage.durationMs > 0) {
      cpuTotal += cpu * usage.durationMs;
      cpuWeightMs += usage.durationMs;
    }
    final usagePeakCpu = usage.peakCpuUsagePercent;
    if (usagePeakCpu != null && (peakCpu == null || usagePeakCpu > peakCpu!)) {
      peakCpu = usagePeakCpu;
    }
    final memory = usage.averageMemoryCommitBytes;
    if (memory != null && usage.durationMs > 0) {
      memoryTotal += memory * usage.durationMs;
      memoryWeightMs += usage.durationMs;
    }
    final usagePeakMemory = usage.peakMemoryCommitBytes;
    if (usagePeakMemory != null &&
        (peakMemory == null || usagePeakMemory > peakMemory!)) {
      peakMemory = usagePeakMemory;
    }
  }

  AppUsage build() {
    final averageCpu = cpuWeightMs == 0 ? null : cpuTotal / cpuWeightMs;
    var finalPeakCpu = peakCpu;
    if (averageCpu != null &&
        (finalPeakCpu == null || averageCpu > finalPeakCpu)) {
      finalPeakCpu = averageCpu;
    }
    final averageMemory = memoryWeightMs == 0
        ? null
        : (memoryTotal / memoryWeightMs).round();
    var finalPeakMemory = peakMemory;
    if (averageMemory != null &&
        (finalPeakMemory == null || averageMemory > finalPeakMemory)) {
      finalPeakMemory = averageMemory;
    }
    return AppUsage(
      name: name,
      durationMs: durationMs,
      executablePath: executablePath,
      averageCpuUsagePercent: averageCpu,
      peakCpuUsagePercent: finalPeakCpu,
      averageMemoryCommitBytes: averageMemory,
      peakMemoryCommitBytes: finalPeakMemory,
    );
  }
}
