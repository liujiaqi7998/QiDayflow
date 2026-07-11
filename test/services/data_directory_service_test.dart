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
}
