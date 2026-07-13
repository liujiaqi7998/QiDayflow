import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class AppDatabase {
  AppDatabase({required this.path, this.databaseFactory});

  static const int schemaVersion = 9;

  final String path;
  final DatabaseFactory? databaseFactory;
  Database? _database;

  bool get isOpen => _database?.isOpen ?? false;

  Future<Database> open() async {
    final existing = _database;
    if (existing != null && existing.isOpen) {
      return existing;
    }

    final factory = databaseFactory ?? _defaultFactory();
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: _configure,
        onCreate: _create,
        onUpgrade: _upgrade,
        onDowngrade: (database, oldVersion, newVersion) {
          throw StateError(
            'Database downgrade is not supported: $oldVersion -> $newVersion',
          );
        },
      ),
    );
    _database = database;
    return database;
  }

  Future<T> transaction<T>(
    Future<T> Function(Transaction transaction) action,
  ) async {
    final database = await open();
    return database.transaction(action);
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database == null || !database.isOpen) {
      return;
    }
    await database.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await database.close();
  }

  DatabaseFactory _defaultFactory() {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  Future<void> _configure(Database database) async {
    await database.execute('PRAGMA foreign_keys = ON');
    await database.rawQuery('PRAGMA journal_mode = WAL');
    await database.execute('PRAGMA synchronous = NORMAL');
    await database.execute('PRAGMA busy_timeout = 5000');
  }

  Future<void> _create(Database database, int version) async {
    for (var nextVersion = 1; nextVersion <= version; nextVersion++) {
      await _applyMigration(database, nextVersion);
    }
  }

  Future<void> _upgrade(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    for (var version = oldVersion + 1; version <= newVersion; version++) {
      await _applyMigration(database, version);
    }
  }

  Future<void> _applyMigration(Database database, int version) async {
    switch (version) {
      case 1:
        await _createSettingsTable(database);
      case 2:
        await _createDomainSchema(database);
      case 3:
        await _migrateChunkTableName(database);
      case 4:
        await _migrateCaptureArtifactsToMp4(database);
      case 5:
        await _migrateFlatCaptureEvidence(database);
      case 6:
        await _addObservationProcessPath(database);
      case 7:
        await _enableAppUsageResourceMetrics(database);
      case 8:
        await _addTimelineSourceDuration(database);
      case 9:
        await _createDailyReportJobs(database);
      default:
        throw StateError('Missing database migration for version $version');
    }
    await database.insert('schema_version', {
      'version': version,
      'applied_at_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _createSettingsTable(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER PRIMARY KEY,
        applied_at_ms INTEGER NOT NULL CHECK(applied_at_ms >= 0)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY NOT NULL CHECK(length(trim(key)) > 0),
        value TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
      )
    ''');
  }

  Future<void> _createDomainSchema(DatabaseExecutor database) async {
    await _createSettingsTable(database);
    await database.execute('''
      CREATE TABLE IF NOT EXISTS capture_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        capture_scope TEXT NOT NULL CHECK(length(trim(capture_scope)) > 0),
        capture_directory TEXT NOT NULL CHECK(length(trim(capture_directory)) > 0),
        started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
        ended_at_ms INTEGER,
        status TEXT NOT NULL CHECK(status IN ('recording', 'paused', 'stopped', 'failed')),
        error_message TEXT,
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
        CHECK(ended_at_ms IS NULL OR ended_at_ms >= started_at_ms)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS capture_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        frames_directory TEXT NOT NULL UNIQUE CHECK(length(trim(frames_directory)) > 0),
        metadata_path TEXT NOT NULL CHECK(length(trim(metadata_path)) > 0),
        video_path TEXT,
        started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
        ended_at_ms INTEGER NOT NULL CHECK(ended_at_ms > started_at_ms),
        frame_count INTEGER NOT NULL CHECK(frame_count > 0),
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'processing', 'completed', 'failed')),
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0),
        next_retry_at_ms INTEGER,
        error_message TEXT,
        processing_started_at_ms INTEGER,
        completed_at_ms INTEGER,
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
        FOREIGN KEY(session_id) REFERENCES capture_sessions(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS analysis_batches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'processing', 'completed', 'failed')),
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0),
        error_message TEXT,
        processing_started_at_ms INTEGER,
        completed_at_ms INTEGER,
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS analysis_batch_chunks (
        batch_id INTEGER NOT NULL,
        chunk_id INTEGER NOT NULL,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        PRIMARY KEY(batch_id, chunk_id),
        UNIQUE(batch_id, ordinal),
        FOREIGN KEY(batch_id) REFERENCES analysis_batches(id) ON DELETE CASCADE,
        FOREIGN KEY(chunk_id) REFERENCES capture_chunks(id) ON DELETE RESTRICT
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS observations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        batch_id INTEGER NOT NULL,
        chunk_id INTEGER NOT NULL,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
        ended_at_ms INTEGER NOT NULL CHECK(ended_at_ms > started_at_ms),
        description TEXT NOT NULL CHECK(length(trim(description)) > 0),
        app_name TEXT,
        process_name TEXT,
        window_title TEXT,
        confidence REAL CHECK(confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        UNIQUE(batch_id, ordinal),
        FOREIGN KEY(batch_id) REFERENCES analysis_batches(id) ON DELETE CASCADE,
        FOREIGN KEY(chunk_id) REFERENCES capture_chunks(id) ON DELETE RESTRICT
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS timeline_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        batch_id INTEGER NOT NULL,
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        report_date TEXT NOT NULL CHECK(length(report_date) = 10),
        category TEXT NOT NULL CHECK(length(trim(category)) > 0),
        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
        summary TEXT NOT NULL DEFAULT '',
        started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
        ended_at_ms INTEGER NOT NULL CHECK(ended_at_ms > started_at_ms),
        app_usages_json TEXT NOT NULL DEFAULT '[]',
        distractions_json TEXT NOT NULL DEFAULT '[]',
        productivity_score REAL NOT NULL
          CHECK(productivity_score >= 0 AND productivity_score <= 100),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
        UNIQUE(batch_id, ordinal),
        FOREIGN KEY(batch_id) REFERENCES analysis_batches(id) ON DELETE RESTRICT
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS timeline_day_revisions (
        report_date TEXT PRIMARY KEY NOT NULL CHECK(length(report_date) = 10),
        revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS daily_reports (
        report_date TEXT PRIMARY KEY NOT NULL CHECK(length(report_date) = 10),
        content TEXT NOT NULL,
        source_revision INTEGER NOT NULL CHECK(source_revision >= 0),
        generated_at_ms INTEGER NOT NULL CHECK(generated_at_ms >= 0),
        model TEXT NOT NULL CHECK(length(trim(model)) > 0),
        invalidated_at_ms INTEGER
      )
    ''');

    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_sessions_status ON capture_sessions(status)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_chunks_status_due '
      'ON capture_chunks(status, next_retry_at_ms, started_at_ms)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_chunks_session '
      'ON capture_chunks(session_id)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_batches_status ON analysis_batches(status)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_batch_chunks_chunk '
      'ON analysis_batch_chunks(chunk_id)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_observations_batch_time '
      'ON observations(batch_id, started_at_ms)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_cards_report_time '
      'ON timeline_cards(report_date, started_at_ms)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_cards_time '
      'ON timeline_cards(started_at_ms, ended_at_ms)',
    );
  }

  Future<void> _migrateChunkTableName(DatabaseExecutor database) async {
    final rows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('chunks', 'capture_chunks')",
    );
    final tables = rows.map((row) => row['name']).toSet();
    if (tables.contains('chunks') && !tables.contains('capture_chunks')) {
      await database.execute('ALTER TABLE chunks RENAME TO capture_chunks');
    }
  }

  Future<void> _migrateCaptureArtifactsToMp4(DatabaseExecutor database) async {
    final sessionColumns = await database.rawQuery(
      'PRAGMA table_info(capture_sessions)',
    );
    final sessionColumnNames = sessionColumns
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    if (sessionColumnNames.contains('display_id') &&
        !sessionColumnNames.contains('capture_scope')) {
      await database.execute(
        'ALTER TABLE capture_sessions '
        'RENAME COLUMN display_id TO capture_scope',
      );
    }

    final chunkColumns = await database.rawQuery(
      'PRAGMA table_info(capture_chunks)',
    );
    final chunkColumnNames = chunkColumns
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    if (!chunkColumnNames.contains('video_path')) {
      await database.execute(
        'ALTER TABLE capture_chunks ADD COLUMN video_path TEXT',
      );
    }
    await database.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_chunks_video_path '
      'ON capture_chunks(video_path) WHERE video_path IS NOT NULL',
    );
  }

  Future<void> _migrateFlatCaptureEvidence(DatabaseExecutor database) async {
    // SQLite cannot drop the v2 inline UNIQUE constraint, so rebuild the
    // chunk table and both tables that hold foreign keys to it as one migration.
    final hasBatchChunks = await _tableExists(
      database,
      'analysis_batch_chunks',
    );
    final hasObservations = await _tableExists(database, 'observations');

    await database.execute('''
      CREATE TABLE capture_chunks_v5 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        frames_directory TEXT NOT NULL CHECK(length(trim(frames_directory)) > 0),
        metadata_path TEXT NOT NULL CHECK(length(trim(metadata_path)) > 0),
        video_path TEXT,
        started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
        ended_at_ms INTEGER NOT NULL CHECK(ended_at_ms > started_at_ms),
        frame_count INTEGER NOT NULL CHECK(frame_count > 0),
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'processing', 'completed', 'failed')),
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0),
        next_retry_at_ms INTEGER,
        error_message TEXT,
        processing_started_at_ms INTEGER,
        completed_at_ms INTEGER,
        evidence_purged_at_ms INTEGER CHECK(
          evidence_purged_at_ms IS NULL OR evidence_purged_at_ms >= 0
        ),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
        FOREIGN KEY(session_id) REFERENCES capture_sessions(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      INSERT INTO capture_chunks_v5(
        id, session_id, frames_directory, metadata_path, video_path,
        started_at_ms, ended_at_ms, frame_count, status, retry_count,
        next_retry_at_ms, error_message, processing_started_at_ms,
        completed_at_ms, evidence_purged_at_ms, created_at_ms, updated_at_ms
      )
      SELECT
        id, session_id, frames_directory, metadata_path, video_path,
        started_at_ms, ended_at_ms, frame_count, status, retry_count,
        next_retry_at_ms, error_message, processing_started_at_ms,
        completed_at_ms, NULL, created_at_ms, updated_at_ms
      FROM capture_chunks
    ''');

    if (hasBatchChunks) {
      await database.execute('''
        CREATE TABLE analysis_batch_chunks_v5 (
          batch_id INTEGER NOT NULL,
          chunk_id INTEGER NOT NULL,
          ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
          PRIMARY KEY(batch_id, chunk_id),
          UNIQUE(batch_id, ordinal),
          FOREIGN KEY(batch_id) REFERENCES analysis_batches(id) ON DELETE CASCADE,
          FOREIGN KEY(chunk_id) REFERENCES capture_chunks_v5(id) ON DELETE RESTRICT
        )
      ''');
      await database.execute('''
        INSERT INTO analysis_batch_chunks_v5(batch_id, chunk_id, ordinal)
        SELECT batch_id, chunk_id, ordinal FROM analysis_batch_chunks
      ''');
    }
    if (hasObservations) {
      await database.execute('''
        CREATE TABLE observations_v5 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          batch_id INTEGER NOT NULL,
          chunk_id INTEGER NOT NULL,
          ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
          started_at_ms INTEGER NOT NULL CHECK(started_at_ms >= 0),
          ended_at_ms INTEGER NOT NULL CHECK(ended_at_ms > started_at_ms),
          description TEXT NOT NULL CHECK(length(trim(description)) > 0),
          app_name TEXT,
          process_name TEXT,
          window_title TEXT,
          confidence REAL CHECK(
            confidence IS NULL OR (confidence >= 0 AND confidence <= 1)
          ),
          created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
          UNIQUE(batch_id, ordinal),
          FOREIGN KEY(batch_id) REFERENCES analysis_batches(id) ON DELETE CASCADE,
          FOREIGN KEY(chunk_id) REFERENCES capture_chunks_v5(id) ON DELETE RESTRICT
        )
      ''');
      await database.execute('''
        INSERT INTO observations_v5(
          id, batch_id, chunk_id, ordinal, started_at_ms, ended_at_ms,
          description, app_name, process_name, window_title, confidence,
          created_at_ms
        )
        SELECT
          id, batch_id, chunk_id, ordinal, started_at_ms, ended_at_ms,
          description, app_name, process_name, window_title, confidence,
          created_at_ms
        FROM observations
      ''');
    }

    if (hasObservations) {
      await database.execute('DROP TABLE observations');
    }
    if (hasBatchChunks) {
      await database.execute('DROP TABLE analysis_batch_chunks');
    }
    await database.execute('DROP TABLE capture_chunks');
    await database.execute(
      'ALTER TABLE capture_chunks_v5 RENAME TO capture_chunks',
    );
    if (hasBatchChunks) {
      await database.execute(
        'ALTER TABLE analysis_batch_chunks_v5 '
        'RENAME TO analysis_batch_chunks',
      );
    }
    if (hasObservations) {
      await database.execute(
        'ALTER TABLE observations_v5 RENAME TO observations',
      );
    }

    await database.execute(
      'CREATE INDEX idx_chunks_status_due '
      'ON capture_chunks(status, next_retry_at_ms, started_at_ms)',
    );
    await database.execute(
      'CREATE INDEX idx_chunks_session ON capture_chunks(session_id)',
    );
    await database.execute(
      'CREATE UNIQUE INDEX idx_chunks_video_path '
      'ON capture_chunks(video_path) WHERE video_path IS NOT NULL',
    );
    if (hasBatchChunks) {
      await database.execute(
        'CREATE INDEX idx_batch_chunks_chunk '
        'ON analysis_batch_chunks(chunk_id)',
      );
    }
    if (hasObservations) {
      await database.execute(
        'CREATE INDEX idx_observations_batch_time '
        'ON observations(batch_id, started_at_ms)',
      );
    }

    final violations = await database.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw StateError('Foreign key violations after schema v5 migration');
    }
  }

  Future<bool> _tableExists(DatabaseExecutor database, String tableName) async {
    final rows = await database.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      <Object?>[tableName],
    );
    return rows.isNotEmpty;
  }

  Future<void> _addObservationProcessPath(DatabaseExecutor database) async {
    final columns = await database.rawQuery('PRAGMA table_info(observations)');
    if (!columns.any((row) => row['name'] == 'process_path')) {
      await database.execute(
        'ALTER TABLE observations ADD COLUMN process_path TEXT',
      );
    }
    final violations = await database.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw StateError('Foreign key violations after schema v6 migration');
    }
  }

  Future<void> _enableAppUsageResourceMetrics(DatabaseExecutor database) async {
    if (await _tableExists(database, 'timeline_cards')) {
      final columns = await database.rawQuery(
        'PRAGMA table_info(timeline_cards)',
      );
      if (!columns.any((row) => row['name'] == 'app_usages_json')) {
        throw StateError('timeline_cards is missing app_usages_json');
      }
    }
    final violations = await database.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw StateError('Foreign key violations after schema v7 migration');
    }
  }

  Future<void> _addTimelineSourceDuration(DatabaseExecutor database) async {
    if (await _tableExists(database, 'timeline_cards')) {
      final columns = await database.rawQuery(
        'PRAGMA table_info(timeline_cards)',
      );
      if (!columns.any((row) => row['name'] == 'source_duration_ms')) {
        await database.execute('''
          ALTER TABLE timeline_cards
          ADD COLUMN source_duration_ms INTEGER NOT NULL DEFAULT 0
            CHECK(source_duration_ms >= 0)
        ''');
      }
      await database.execute('''
        UPDATE timeline_cards
        SET source_duration_ms = ended_at_ms - started_at_ms
        WHERE source_duration_ms <= 0
      ''');
    }
    final violations = await database.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw StateError('Foreign key violations after schema v8 migration');
    }
  }

  Future<void> _createDailyReportJobs(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS daily_report_jobs (
        report_date TEXT PRIMARY KEY NOT NULL CHECK(length(report_date) = 10),
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'processing', 'failed')),
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0),
        error_category TEXT,
        error_summary TEXT,
        requested_at_ms INTEGER NOT NULL CHECK(requested_at_ms >= 0),
        updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
        processing_started_at_ms INTEGER
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_report_jobs_status_requested '
      'ON daily_report_jobs(status, requested_at_ms)',
    );
  }
}
