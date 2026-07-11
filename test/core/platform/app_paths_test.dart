import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/platform/app_paths.dart';

void main() {
  test('all runtime paths are derived from the user data directory', () {
    final paths = AppPaths.forUserDataDirectory(r'Z:\Qi Day Flow Data\');

    expect(paths.userDataDirectory, r'Z:\Qi Day Flow Data');
    expect(paths.database, r'Z:\Qi Day Flow Data\qi_day_flow.db');
    expect(paths.logsDirectory, r'Z:\Qi Day Flow Data\logs');
    expect(paths.captureDirectory, r'Z:\Qi Day Flow Data\captures');
  });
}
