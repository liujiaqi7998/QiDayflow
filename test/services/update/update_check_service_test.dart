import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qi_day_flow/services/update/update_check_service.dart';

void main() {
  group('stable numeric version comparison', () {
    test('accepts v prefix, missing patch, and ignores build metadata', () {
      expect(isNewerStableVersion(current: '1.2.0+7', latest: 'v1.3'), isTrue);
      expect(
        isNewerStableVersion(current: '1.2.3', latest: '1.2.3+9'),
        isFalse,
      );
      expect(isNewerStableVersion(current: '1.9.9', latest: '2.0.0'), isTrue);
    });

    test('rejects malformed and prerelease tags', () {
      expect(isNewerStableVersion(current: '1.2.3', latest: 'latest'), isFalse);
      expect(
        isNewerStableVersion(current: '1.2.3', latest: '1.3.0-beta.1'),
        isFalse,
      );
      expect(isNewerStableVersion(current: '1.2.3', latest: '1'), isFalse);
    });
  });

  group('UpdateCheckService', () {
    test('requests latest release and parses a newer 200 response', () async {
      final transport = _FakeTransport(
        response: UpdateHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'tag_name': 'v1.2.3',
            'name': 'Qi Day Flow 1.2.3',
            'html_url':
                'https://github.com/liujiaqi7998/QiDayflow/releases/tag/v1.2.3',
          }),
        ),
      );
      final service = UpdateCheckService(
        currentVersion: '1.1.0+4',
        transport: transport,
        now: () => DateTime.utc(2026, 7, 13),
      );

      final result = await service.check();

      expect(transport.uri, UpdateCheckService.latestReleaseApiUri);
      expect(transport.headers, <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'QiDayFlow/1.1.0+4',
      });
      expect(transport.timeout, const Duration(seconds: 5));
      expect(result.currentVersion, '1.1.0+4');
      expect(result.latestVersion, '1.2.3');
      expect(result.releaseName, 'Qi Day Flow 1.2.3');
      expect(result.releaseUrl.toString(), contains('/releases/tag/v1.2.3'));
      expect(result.updateAvailable, isTrue);
      expect(result.error, isNull);
      expect(result.checkedAt, DateTime.utc(2026, 7, 13));
    });

    test('reports no update for an equal release', () async {
      final service = UpdateCheckService(
        currentVersion: '1.2.0',
        transport: _FakeTransport(
          response: const UpdateHttpResponse(
            statusCode: 200,
            body:
                '{"tag_name":"v1.2","name":"same","html_url":"https://example.test/release"}',
          ),
        ),
      );

      final result = await service.check();

      expect(result.latestVersion, '1.2.0');
      expect(result.updateAvailable, isFalse);
      expect(result.error, isNull);
    });

    test('accepts a GitHub release without an optional name', () async {
      final service = UpdateCheckService(
        currentVersion: '1.0.0',
        transport: _FakeTransport(
          response: const UpdateHttpResponse(
            statusCode: 200,
            body:
                '{"tag_name":"v1.1.0","name":null,"html_url":"https://example.test/release"}',
          ),
        ),
      );

      final result = await service.check();

      expect(result.updateAvailable, isTrue);
      expect(result.latestVersion, '1.1.0');
      expect(result.releaseName, 'v1.1.0');
      expect(result.error, isNull);
    });

    test('uses the tag when GitHub returns an empty release name', () async {
      final service = UpdateCheckService(
        currentVersion: '1.0.0',
        transport: _FakeTransport(
          response: const UpdateHttpResponse(
            statusCode: 200,
            body:
                '{"tag_name":"v1.1.0","name":"","html_url":"https://github.com/liujiaqi7998/QiDayflow/releases/tag/v1.1.0"}',
          ),
        ),
      );

      final result = await service.check();

      expect(result.updateAvailable, isTrue);
      expect(result.releaseName, 'v1.1.0');
      expect(result.error, isNull);
    });

    test('turns timeout and network errors into safe failures', () async {
      for (final error in <Object>[
        TimeoutException('late response'),
        StateError('socket secret'),
      ]) {
        final service = UpdateCheckService(
          currentVersion: '1.0.0',
          transport: _FakeTransport(error: error),
        );

        final result = await service.check();

        expect(result.updateAvailable, isFalse);
        expect(result.error, isNotNull);
        expect(result.error, isNot(contains('socket secret')));
      }
    });

    test(
      'handles 404 and rate limiting without exposing response body',
      () async {
        for (final statusCode in <int>[404, 403, 429]) {
          final service = UpdateCheckService(
            currentVersion: '1.0.0',
            transport: _FakeTransport(
              response: UpdateHttpResponse(
                statusCode: statusCode,
                body: 'private response body',
              ),
            ),
          );

          final result = await service.check();

          expect(result.updateAvailable, isFalse);
          expect(result.error, isNotNull);
          expect(result.error, isNot(contains('private response body')));
        }
      },
    );

    test('malformed JSON and malformed tags cannot become updates', () async {
      final responses = <String>[
        '{bad json',
        '{"tag_name":"release-next","name":"next","html_url":"https://example.test"}',
      ];
      for (final body in responses) {
        final service = UpdateCheckService(
          currentVersion: '1.0.0',
          transport: _FakeTransport(
            response: UpdateHttpResponse(statusCode: 200, body: body),
          ),
        );

        final result = await service.check();

        expect(result.updateAvailable, isFalse);
        expect(result.latestVersion, isNull);
        expect(result.error, isNotNull);
      }
    });

    test('close releases the injected transport', () {
      final transport = _FakeTransport();
      final service = UpdateCheckService(
        currentVersion: '1.0.0',
        transport: transport,
      );

      service.close();

      expect(transport.closed, isTrue);
    });
  });

  group('HttpUpdateCheckTransport', () {
    test('aborts the underlying request when the timeout expires', () async {
      final client = _TrackingHttpClient(neverComplete: true);
      final transport = HttpUpdateCheckTransport(client);

      await expectLater(
        transport.get(
          Uri.parse('https://example.test/releases/latest'),
          headers: const <String, String>{'Accept': 'application/json'},
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.sawAbortableRequest, isTrue);
      expect(client.requestAborted, isTrue);
    });

    test('does not close an externally owned client', () {
      final client = _TrackingHttpClient();
      final transport = HttpUpdateCheckTransport(client);

      transport.close();

      expect(client.closed, isFalse);
    });
  });
}

final class _TrackingHttpClient extends http.BaseClient {
  _TrackingHttpClient({this.neverComplete = false});

  final bool neverComplete;
  bool sawAbortableRequest = false;
  bool requestAborted = false;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.AbortableRequest) {
      sawAbortableRequest = true;
      request.abortTrigger?.then((_) => requestAborted = true);
    }
    if (neverComplete) return Completer<http.StreamedResponse>().future;
    return Future<http.StreamedResponse>.value(
      http.StreamedResponse(const Stream<List<int>>.empty(), 200),
    );
  }

  @override
  void close() => closed = true;
}

final class _FakeTransport implements UpdateCheckTransport {
  _FakeTransport({this.response, this.error});

  final UpdateHttpResponse? response;
  final Object? error;
  Uri? uri;
  Map<String, String>? headers;
  Duration? timeout;
  bool closed = false;

  @override
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    this.uri = uri;
    this.headers = headers;
    this.timeout = timeout;
    if (error case final error?) throw error;
    return response ?? const UpdateHttpResponse(statusCode: 404, body: '');
  }

  @override
  void close() => closed = true;
}
