import 'core/platform/app_paths.dart';
import 'data/data.dart';
import 'features/presentation/app_controller.dart';
import 'services/native/native_capture_service.dart';
import 'services/data_directory_service.dart';
import 'services/logging/app_logger.dart';
import 'services/secure_settings_service.dart';

Future<AppController> bootstrapApplication() async {
  final defaultPaths = await AppPaths.create();
  final dataDirectoryService = DataDirectoryService(
    locatorDirectory: defaultPaths.userDataDirectory,
    defaultUserDataDirectory: defaultPaths.userDataDirectory,
  );
  final paths = await dataDirectoryService.resolvePaths();
  final logger = AppLogger(logDirectory: paths.logsDirectory);
  final database = AppDatabase(path: paths.database);
  final repository = SqliteDayFlowRepository(database);
  final nativeService = NativeCaptureService();
  final settingsService = SecureSettingsService(
    repository: repository,
    platform: nativeService,
    defaultUserDataDirectory: paths.userDataDirectory,
  );
  final controller = AppController(
    database: database,
    repository: repository,
    nativeService: nativeService,
    settingsService: settingsService,
    dataDirectoryService: dataDirectoryService,
    activeUserDataDirectory: paths.userDataDirectory,
    logger: logger,
  );
  await controller.initialize();
  return controller;
}
