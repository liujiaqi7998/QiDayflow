import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qi_day_flow/data/data.dart';
import 'package:qi_day_flow/features/presentation/app_controller.dart';
import 'package:qi_day_flow/services/native/native_capture_service.dart';
import 'package:qi_day_flow/services/secure_settings_service.dart';
import 'package:qi_day_flow/services/update/update_check_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'initialize starts one silent update check without awaiting it',
    () async {
      final transport = _QueuedTransport();
      final fixture = await _createFixture(transport);
      addTearDown(fixture.close);

      await fixture.controller.initialize().timeout(const Duration(seconds: 3));

      expect(transport.requests, hasLength(1));
      expect(fixture.controller.update.checking, isTrue);
      transport.requests.single.complete(
        const UpdateHttpResponse(statusCode: 500, body: 'secret body'),
      );
      await _waitFor(() => !fixture.controller.update.checking);

      expect(fixture.controller.update.error, isNull);
      expect(fixture.controller.update.updateAvailable, isFalse);
    },
  );

  test('manual check shows safe errors and ignores duplicate clicks', () async {
    final transport = _QueuedTransport();
    final fixture = await _createFixture(transport);
    addTearDown(fixture.close);
    await fixture.controller.initialize();
    transport.requests.single.complete(
      const UpdateHttpResponse(statusCode: 404, body: 'private response'),
    );
    await _waitFor(() => !fixture.controller.update.checking);

    final first = fixture.controller.checkForUpdates();
    final second = fixture.controller.checkForUpdates();
    await Future<void>.delayed(Duration.zero);

    expect(transport.requests, hasLength(2));
    expect(fixture.controller.update.checking, isTrue);
    transport.requests.last.completeError(TimeoutException('late secret'));
    await Future.wait(<Future<void>>[first, second]);

    expect(fixture.controller.update.checking, isFalse);
    expect(fixture.controller.update.error, contains('超时'));
    expect(fixture.controller.update.error, isNot(contains('secret')));
  });

  test(
    'manual check exposes a newer version and opens fixed releases page',
    () async {
      final opened = <Uri>[];
      final transport = _QueuedTransport();
      final fixture = await _createFixture(
        transport,
        opener: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      transport.requests.single.complete(
        const UpdateHttpResponse(
          statusCode: 200,
          body:
              '{"tag_name":"v1.1.0","name":"1.1.0","html_url":"https://example.test/untrusted"}',
        ),
      );
      await _waitFor(() => fixture.controller.update.updateAvailable);

      await fixture.controller.openReleasesPage();

      expect(fixture.controller.update.currentVersion, '1.0.0+2');
      expect(fixture.controller.update.latestVersion, '1.1.0');
      expect(opened, <Uri>[UpdateCheckService.releasesPageUri]);
    },
  );

  test('a late update result cannot notify a disposed controller', () async {
    final transport = _QueuedTransport();
    final fixture = await _createFixture(transport);
    await fixture.controller.initialize();
    var notifications = 0;
    fixture.controller.addListener(() => notifications++);
    final beforeDispose = notifications;

    fixture.controller.dispose();
    fixture.disposed = true;
    transport.requests.single.complete(
      const UpdateHttpResponse(
        statusCode: 200,
        body:
            '{"tag_name":"v9.0.0","name":"9.0.0","html_url":"https://example.test/release"}',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications, beforeDispose);
    expect(transport.closed, isTrue);
    await fixture.close();
  });

  test('normal application exit closes the update transport', () async {
    final transport = _QueuedTransport();
    final fixture = await _createFixture(transport);
    addTearDown(fixture.close);
    await fixture.controller.initialize();
    transport.requests.single.complete(
      const UpdateHttpResponse(statusCode: 404, body: ''),
    );
    await _waitFor(() => !fixture.controller.update.checking);

    await fixture.controller.exitApplication();

    expect(transport.closed, isTrue);
  });
}

Future<_ControllerFixture> _createFixture(
  _QueuedTransport transport, {
  Future<bool> Function(Uri uri)? opener,
}) async {
  final root = await Directory.systemTemp.createTemp('qi_update_controller_');
  final database = AppDatabase(
    path: p.join(root.path, 'dayflow.db'),
    databaseFactory: databaseFactoryFfi,
  );
  final repository = SqliteDayFlowRepository(database);
  const methods = MethodChannel('qi_day_flow/test/update-methods');
  const events = EventChannel('qi_day_flow/test/update-events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(methods, (call) async {
    if (call.method == 'queryLaunchAtLogin') return false;
    return null;
  });
  messenger.setMockMethodCallHandler(
    const MethodChannel('qi_day_flow/test/update-events'),
    (_) async => null,
  );
  final native = NativeCaptureService(
    methodChannel: methods,
    eventChannel: events,
  );
  final controller = AppController(
    database: database,
    repository: repository,
    nativeService: native,
    settingsService: SecureSettingsService(
      repository: repository,
      platform: native,
      defaultUserDataDirectory: root.path,
    ),
    activeUserDataDirectory: root.path,
    updateCheckService: UpdateCheckService(
      currentVersion: '1.0.0+2',
      transport: transport,
    ),
    releasePageOpener: opener ?? (_) async => true,
  );
  return _ControllerFixture(
    controller: controller,
    database: database,
    root: root,
    messenger: messenger,
    methods: methods,
  );
}

final class _ControllerFixture {
  _ControllerFixture({
    required this.controller,
    required this.database,
    required this.root,
    required this.messenger,
    required this.methods,
  });

  final AppController controller;
  final AppDatabase database;
  final Directory root;
  final TestDefaultBinaryMessenger messenger;
  final MethodChannel methods;
  bool disposed = false;

  Future<void> close() async {
    if (!disposed) controller.dispose();
    disposed = true;
    await database.close();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('qi_day_flow/test/update-events'),
      null,
    );
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _QueuedTransport implements UpdateCheckTransport {
  final List<Completer<UpdateHttpResponse>> requests =
      <Completer<UpdateHttpResponse>>[];
  bool closed = false;

  @override
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) {
    final request = Completer<UpdateHttpResponse>();
    requests.add(request);
    return request.future;
  }

  @override
  void close() => closed = true;
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for update state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
