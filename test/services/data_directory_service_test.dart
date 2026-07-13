import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/services/data_directory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('applies a scheduled data directory change on next startup', () async {
    final temp = await Directory.systemTemp.createTemp(
      'qi_day_flow_data_directory_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final current = p.join(temp.path, 'current');
    final next = p.join(temp.path, 'next');
    final locator = p.join(temp.path, 'bootstrap');
    await Directory(current).create(recursive: true);
    final sourceDatabase = AppDatabase(
      path: p.join(current, 'qi_day_flow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final sourceRepository = SqliteDayFlowRepository(sourceDatabase);
    await sourceRepository.putSetting('migration_marker', 'preserved');
    await sourceDatabase.close();
    final service = DataDirectoryService(
      locatorDirectory: locator,
      defaultUserDataDirectory: current,
      databaseFactory: databaseFactoryFfi,
    );

    await service.scheduleChange(
      currentUserDataDirectory: current,
      nextUserDataDirectory: next,
    );
    final resolved = await service.resolvePaths();

    expect(resolved.userDataDirectory, p.windows.normalize(next));
    final migratedDatabase = AppDatabase(
      path: resolved.database,
      databaseFactory: databaseFactoryFfi,
    );
    final migratedRepository = SqliteDayFlowRepository(migratedDatabase);
    expect(
      (await migratedRepository.getSetting('migration_marker'))?.value,
      'preserved',
    );
    await migratedDatabase.close();
    expect(
      (await service.resolvePaths()).userDataDirectory,
      resolved.userDataDirectory,
    );
  });

  test(
    'rejects a corrupted temporary copy without committing locator',
    () async {
      final fixture = await _MigrationFixture.create('corrupt_temporary');
      addTearDown(fixture.dispose);
      final service = fixture.service(
        databaseValidator: (path, factory) async {
          await File(path).writeAsBytes(<int>[0x00, 0x01, 0x02], flush: true);
          await validateMigratedDatabase(path, factory);
        },
      );
      await service.scheduleChange(
        currentUserDataDirectory: fixture.current,
        nextUserDataDirectory: fixture.next,
      );

      await expectLater(service.resolvePaths(), throwsA(anything));

      expect(
        File(p.join(fixture.next, 'qi_day_flow.db')).existsSync(),
        isFalse,
      );
      expect(
        Directory(fixture.next).listSync().whereType<File>().where(
          (file) => file.path.contains('.migrating.'),
        ),
        isEmpty,
      );
      expect(
        File(
          p.join(fixture.next, '.qi_day_flow_database_migration.json'),
        ).existsSync(),
        isTrue,
      );
      await service.scheduleChange(
        currentUserDataDirectory: fixture.current,
        nextUserDataDirectory: fixture.next,
      );
    },
  );

  test('validates a marker-matched existing target before recovery', () async {
    final fixture = await _MigrationFixture.create('corrupt_existing');
    addTearDown(fixture.dispose);
    final service = fixture.service();
    await service.scheduleChange(
      currentUserDataDirectory: fixture.current,
      nextUserDataDirectory: fixture.next,
    );
    await Directory(fixture.next).create(recursive: true);
    await File(
      p.join(fixture.next, '.qi_day_flow_database_migration.json'),
    ).writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'sourceUserDataDirectory': p.windows.normalize(fixture.current),
        'targetUserDataDirectory': p.windows.normalize(fixture.next),
      }),
      flush: true,
    );
    await File(
      p.join(fixture.next, 'qi_day_flow.db'),
    ).writeAsBytes(<int>[0x00, 0x01, 0x02], flush: true);

    await expectLater(service.resolvePaths(), throwsA(anything));

    expect(
      File(
        p.join(fixture.next, '.qi_day_flow_database_migration.json'),
      ).existsSync(),
      isTrue,
    );
    await service.scheduleChange(
      currentUserDataDirectory: fixture.current,
      nextUserDataDirectory: fixture.next,
    );
  });
}

final class _MigrationFixture {
  _MigrationFixture({
    required this.root,
    required this.current,
    required this.next,
    required this.locator,
  });

  static Future<_MigrationFixture> create(String suffix) async {
    final root = await Directory.systemTemp.createTemp(
      'qi_day_flow_migration_$suffix',
    );
    final current = p.join(root.path, 'current');
    final next = p.join(root.path, 'next');
    final locator = p.join(root.path, 'locator');
    await Directory(current).create(recursive: true);
    final database = AppDatabase(
      path: p.join(current, 'qi_day_flow.db'),
      databaseFactory: databaseFactoryFfi,
    );
    await database.open();
    await database.close();
    return _MigrationFixture(
      root: root,
      current: current,
      next: next,
      locator: locator,
    );
  }

  final Directory root;
  final String current;
  final String next;
  final String locator;

  DataDirectoryService service({
    MigrationDatabaseValidator? databaseValidator,
  }) => DataDirectoryService(
    locatorDirectory: locator,
    defaultUserDataDirectory: current,
    databaseFactory: databaseFactoryFfi,
    databaseValidator: databaseValidator,
  );

  Future<void> dispose() => root.delete(recursive: true);
}
