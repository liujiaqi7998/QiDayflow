import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/data/data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporaryDirectory;
  late AppDatabase appDatabase;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'qi_day_flow_database_test_',
    );
    appDatabase = AppDatabase(
      path: '${temporaryDirectory.path}${Platform.pathSeparator}dayflow.db',
      databaseFactory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await appDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'creates the current schema with WAL, foreign keys, and required tables',
    () async {
      final database = await appDatabase.open();

      final journalMode = await database.rawQuery('PRAGMA journal_mode');
      final foreignKeys = await database.rawQuery('PRAGMA foreign_keys');
      final userVersion = await database.rawQuery('PRAGMA user_version');
      final tableRows = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final tables = tableRows.map((row) => row['name']! as String).toSet();

      expect(journalMode.single.values.single, 'wal');
      expect(foreignKeys.single.values.single, 1);
      expect(userVersion.single.values.single, AppDatabase.schemaVersion);
      final sessionColumns = await database.rawQuery(
        'PRAGMA table_info(capture_sessions)',
      );
      final chunkColumns = await database.rawQuery(
        'PRAGMA table_info(capture_chunks)',
      );
      final observationColumns = await database.rawQuery(
        'PRAGMA table_info(observations)',
      );
      final cardColumns = await database.rawQuery(
        'PRAGMA table_info(timeline_cards)',
      );
      expect(
        sessionColumns.map((row) => row['name']),
        contains('capture_scope'),
      );
      expect(
        sessionColumns.map((row) => row['name']),
        isNot(contains('display_id')),
      );
      expect(chunkColumns.map((row) => row['name']), contains('video_path'));
      expect(
        chunkColumns.map((row) => row['name']),
        contains('evidence_purged_at_ms'),
      );
      expect(
        observationColumns.map((row) => row['name']),
        contains('process_path'),
      );
      expect(
        cardColumns.map((row) => row['name']),
        contains('source_duration_ms'),
      );
      expect(
        tables,
        containsAll(<String>{
          'settings',
          'capture_sessions',
          'capture_chunks',
          'analysis_batches',
          'analysis_batch_chunks',
          'observations',
          'timeline_cards',
          'timeline_day_revisions',
          'daily_reports',
        }),
      );
    },
  );

  test('enforces capture chunk foreign keys', () async {
    final database = await appDatabase.open();

    expect(
      () => database.insert('capture_chunks', {
        'session_id': 999,
        'frames_directory': 'C:/missing/chunk',
        'metadata_path': 'C:/missing/chunk/metadata.json',
        'started_at_ms': 1000,
        'ended_at_ms': 2000,
        'frame_count': 1,
        'status': 'pending',
        'created_at_ms': 1000,
        'updated_at_ms': 1000,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('migrates a version 1 settings database without losing data', () async {
    final path = appDatabase.path;
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE settings (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.insert('settings', {
            'key': 'theme',
            'value': 'dark',
            'updated_at_ms': 1234,
          });
        },
      ),
    );
    await legacy.close();

    final migrated = await appDatabase.open();
    final setting = await migrated.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['theme'],
    );
    final batches = await migrated.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'analysis_batches'",
    );
    final userVersion = await migrated.rawQuery('PRAGMA user_version');

    expect(setting.single['value'], 'dark');
    expect(batches, hasLength(1));
    expect(userVersion.single.values.single, AppDatabase.schemaVersion);
  });

  test('migrates v3 display and JPEG columns without losing chunks', () async {
    final path = appDatabase.path;
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE schema_version (
              version INTEGER PRIMARY KEY,
              applied_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE capture_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              display_id TEXT NOT NULL,
              capture_directory TEXT NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER,
              status TEXT NOT NULL,
              error_message TEXT,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE capture_chunks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL,
              frames_directory TEXT NOT NULL UNIQUE,
              metadata_path TEXT NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER NOT NULL,
              frame_count INTEGER NOT NULL,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL,
              next_retry_at_ms INTEGER,
              error_message TEXT,
              processing_started_at_ms INTEGER,
              completed_at_ms INTEGER,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE analysis_batches (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL,
              error_message TEXT,
              processing_started_at_ms INTEGER,
              completed_at_ms INTEGER,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE analysis_batch_chunks (
              batch_id INTEGER NOT NULL,
              chunk_id INTEGER NOT NULL,
              ordinal INTEGER NOT NULL,
              PRIMARY KEY(batch_id, chunk_id),
              UNIQUE(batch_id, ordinal)
            )
          ''');
          await database.execute('''
            CREATE TABLE observations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              batch_id INTEGER NOT NULL,
              chunk_id INTEGER NOT NULL,
              ordinal INTEGER NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER NOT NULL,
              description TEXT NOT NULL,
              app_name TEXT,
              process_name TEXT,
              window_title TEXT,
              confidence REAL,
              created_at_ms INTEGER NOT NULL,
              UNIQUE(batch_id, ordinal)
            )
          ''');
          await database.insert('capture_sessions', {
            'display_id': 'display-0',
            'capture_directory': r'C:\QiDayFlow\captures',
            'started_at_ms': 1000,
            'status': 'stopped',
            'created_at_ms': 1000,
            'updated_at_ms': 1000,
          });
          await database.insert('capture_chunks', {
            'session_id': 1,
            'frames_directory': r'C:\QiDayFlow\captures\legacy',
            'metadata_path': r'C:\QiDayFlow\captures\legacy\metadata.json',
            'started_at_ms': 1000,
            'ended_at_ms': 2000,
            'frame_count': 1,
            'status': 'failed',
            'retry_count': 1,
            'created_at_ms': 1000,
            'updated_at_ms': 1000,
          });
        },
      ),
    );
    await legacy.close();

    final migrated = await appDatabase.open();
    final session = (await migrated.query('capture_sessions')).single;
    final chunk = (await migrated.query('capture_chunks')).single;

    expect(session['capture_scope'], 'display-0');
    expect(session.containsKey('display_id'), isFalse);
    expect(chunk['video_path'], isNull);
    expect(chunk['status'], 'failed');
    expect(chunk['evidence_purged_at_ms'], isNull);
  });

  test('migrates v4 chunks and allows a shared flat capture root', () async {
    final path = appDatabase.path;
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE schema_version (
              version INTEGER PRIMARY KEY,
              applied_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE capture_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              capture_scope TEXT NOT NULL,
              capture_directory TEXT NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER,
              status TEXT NOT NULL,
              error_message TEXT,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE capture_chunks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id INTEGER NOT NULL,
              frames_directory TEXT NOT NULL UNIQUE,
              metadata_path TEXT NOT NULL,
              video_path TEXT,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER NOT NULL,
              frame_count INTEGER NOT NULL,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL,
              next_retry_at_ms INTEGER,
              error_message TEXT,
              processing_started_at_ms INTEGER,
              completed_at_ms INTEGER,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE analysis_batches (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              status TEXT NOT NULL,
              retry_count INTEGER NOT NULL,
              error_message TEXT,
              processing_started_at_ms INTEGER,
              completed_at_ms INTEGER,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE analysis_batch_chunks (
              batch_id INTEGER NOT NULL,
              chunk_id INTEGER NOT NULL,
              ordinal INTEGER NOT NULL,
              PRIMARY KEY(batch_id, chunk_id),
              UNIQUE(batch_id, ordinal)
            )
          ''');
          await database.execute('''
            CREATE TABLE observations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              batch_id INTEGER NOT NULL,
              chunk_id INTEGER NOT NULL,
              ordinal INTEGER NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER NOT NULL,
              description TEXT NOT NULL,
              app_name TEXT,
              process_name TEXT,
              window_title TEXT,
              confidence REAL,
              created_at_ms INTEGER NOT NULL,
              UNIQUE(batch_id, ordinal)
            )
          ''');
          await database.insert('capture_sessions', {
            'capture_scope': 'all-displays',
            'capture_directory': r'C:\QiDayFlow\captures',
            'started_at_ms': 1000,
            'status': 'stopped',
            'created_at_ms': 1000,
            'updated_at_ms': 1000,
          });
          await database.insert('capture_chunks', {
            'session_id': 1,
            'frames_directory': r'C:\QiDayFlow\captures\legacy_chunk',
            'metadata_path':
                r'C:\QiDayFlow\captures\legacy_chunk\metadata.json',
            'video_path': r'C:\QiDayFlow\captures\legacy_chunk\chunk_1000.mp4',
            'started_at_ms': 1000,
            'ended_at_ms': 2000,
            'frame_count': 1,
            'status': 'completed',
            'retry_count': 0,
            'completed_at_ms': 2100,
            'created_at_ms': 1000,
            'updated_at_ms': 2100,
          });
          await database.insert('analysis_batches', {
            'status': 'completed',
            'retry_count': 0,
            'completed_at_ms': 2100,
            'created_at_ms': 1000,
            'updated_at_ms': 2100,
          });
          await database.insert('analysis_batch_chunks', {
            'batch_id': 1,
            'chunk_id': 1,
            'ordinal': 0,
          });
          await database.insert('observations', {
            'batch_id': 1,
            'chunk_id': 1,
            'ordinal': 0,
            'started_at_ms': 1000,
            'ended_at_ms': 2000,
            'description': 'legacy observation',
            'created_at_ms': 2100,
          });
        },
      ),
    );
    await legacy.close();

    final migrated = await appDatabase.open();
    final oldChunk = (await migrated.query('capture_chunks')).single;
    expect(oldChunk['video_path'], contains('chunk_1000.mp4'));
    expect(oldChunk['evidence_purged_at_ms'], isNull);
    expect(await migrated.query('analysis_batch_chunks'), hasLength(1));
    expect(
      (await migrated.query('observations')).single['description'],
      'legacy observation',
    );
    expect(
      (await migrated.query('observations')).single['process_path'],
      isNull,
    );
    expect(await migrated.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    final observationForeignKeys = await migrated.rawQuery(
      'PRAGMA foreign_key_list(observations)',
    );
    expect(
      observationForeignKeys.map((row) => row['table']),
      containsAll(<String>['analysis_batches', 'capture_chunks']),
    );

    final sharedRoot = r'C:\QiDayFlow\captures';
    await migrated.insert('capture_chunks', {
      'session_id': 1,
      'frames_directory': sharedRoot,
      'metadata_path': '$sharedRoot\\chunk_2000.json',
      'video_path': '$sharedRoot\\chunk_2000.mp4',
      'started_at_ms': 2000,
      'ended_at_ms': 3000,
      'frame_count': 1,
      'status': 'pending',
      'retry_count': 0,
      'created_at_ms': 2000,
      'updated_at_ms': 2000,
    });
    await migrated.insert('capture_chunks', {
      'session_id': 1,
      'frames_directory': sharedRoot,
      'metadata_path': '$sharedRoot\\chunk_3000.json',
      'video_path': '$sharedRoot\\chunk_3000.mp4',
      'started_at_ms': 3000,
      'ended_at_ms': 4000,
      'frame_count': 1,
      'status': 'pending',
      'retry_count': 0,
      'created_at_ms': 3000,
      'updated_at_ms': 3000,
    });
    expect(await migrated.query('capture_chunks'), hasLength(3));
  });

  test(
    'migrates legacy cards with source duration without rewriting app data',
    () async {
      final path = appDatabase.path;
      const legacyAppUsages =
          r'[{"name":"Legacy App","duration_ms":1000,"executable_path":"C:\\Apps\\Legacy.exe"}]';
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (database, version) async {
            await database.execute('''
            CREATE TABLE schema_version (
              version INTEGER PRIMARY KEY,
              applied_at_ms INTEGER NOT NULL
            )
          ''');
            await database.insert('schema_version', <String, Object>{
              'version': 6,
              'applied_at_ms': 1000,
            });
            await database.execute('''
            CREATE TABLE timeline_cards (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              batch_id INTEGER NOT NULL,
              ordinal INTEGER NOT NULL,
              report_date TEXT NOT NULL,
              category TEXT NOT NULL,
              title TEXT NOT NULL,
              summary TEXT NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER NOT NULL,
              app_usages_json TEXT NOT NULL,
              distractions_json TEXT NOT NULL,
              productivity_score REAL NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ''');
            await database.insert('timeline_cards', <String, Object>{
              'batch_id': 1,
              'ordinal': 0,
              'report_date': '2026-07-11',
              'category': '工作',
              'title': '旧卡片',
              'summary': '',
              'started_at_ms': 1000,
              'ended_at_ms': 2000,
              'app_usages_json': legacyAppUsages,
              'distractions_json': '[]',
              'productivity_score': 80.0,
              'created_at_ms': 1000,
              'updated_at_ms': 1000,
            });
          },
        ),
      );
      await legacy.close();

      final migrated = await appDatabase.open();
      final row = (await migrated.query('timeline_cards')).single;
      final userVersion = await migrated.rawQuery('PRAGMA user_version');

      expect(AppDatabase.schemaVersion, 9);
      expect(userVersion.single.values.single, AppDatabase.schemaVersion);
      expect(row['app_usages_json'], legacyAppUsages);
      expect(row['source_duration_ms'], 1000);
      expect(
        await migrated.query(
          'schema_version',
          where: 'version = ?',
          whereArgs: <Object>[AppDatabase.schemaVersion],
        ),
        hasLength(1),
      );
      expect(
        await migrated.rawQuery('PRAGMA table_info(daily_report_jobs)'),
        isNotEmpty,
      );
    },
  );
}
