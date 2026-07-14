import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qi_day_flow/services/update/update_check_service.dart';

void main() {
  group('UpdateBuildMetadata', () {
    test('requires a valid build time and a non-empty build tag', () {
      final metadata = UpdateBuildMetadata.tryParse(
        buildTimeValue: '2026-07-12T18:00:00+08:00',
        buildTagValue: ' release/20260712 ',
      );

      expect(metadata, isNotNull);
      expect(metadata!.buildTime, DateTime.utc(2026, 7, 12, 10));
      expect(metadata.buildTag, 'release/20260712');

      for (final values in <(String, String)>[
        ('', 'release/20260712'),
        ('not-a-date', 'release/20260712'),
        ('2026-07-12T10:00:00Z', ''),
        ('2026-07-12T10:00:00Z', '   '),
      ]) {
        expect(
          UpdateBuildMetadata.tryParse(
            buildTimeValue: values.$1,
            buildTagValue: values.$2,
          ),
          isNull,
        );
      }
    });
  });

  group('UpdateCheckService', () {
    test(
      'reports an update from publication time even when currentVersion is numerically larger',
      () async {
        final buildTime = DateTime.utc(2026, 7, 12, 10);
        final transport = _FakeTransport(
          response: UpdateHttpResponse(
            statusCode: 200,
            body: jsonEncode(<String, Object?>{
              'tag_name': 'nightly_foo',
              'name': 'Nightly Foo',
              'html_url':
                  'https://github.com/liujiaqi7998/QiDayflow/releases/tag/nightly_foo',
              'published_at': '2026-07-12T10:00:01Z',
            }),
          ),
        );
        final service = UpdateCheckService(
          currentVersion: '99.0.0+4',
          currentBuildTime: buildTime,
          transport: transport,
          now: () => DateTime.utc(2026, 7, 13),
        );

        final result = await service.check();

        expect(transport.uri, UpdateCheckService.latestReleaseApiUri);
        expect(transport.headers, <String, String>{
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'QiDayFlow/99.0.0+4',
        });
        expect(transport.timeout, const Duration(seconds: 5));
        expect(result.currentVersion, '99.0.0+4');
        expect(result.latestVersion, 'nightly_foo');
        expect(result.releaseName, 'Nightly Foo');
        expect(result.releaseUrl.toString(), contains('/tag/nightly_foo'));
        expect(result.updateAvailable, isTrue);
        expect(result.error, isNull);
        expect(result.checkedAt, DateTime.utc(2026, 7, 13));
      },
    );

    test(
      'reports no update when a larger semver was published at or before the build',
      () async {
        final buildTime = DateTime.utc(2026, 7, 12, 10);
        for (final publishedAt in <String>[
          '2026-07-12T09:59:59Z',
          '2026-07-12T10:00:00Z',
        ]) {
          final service = UpdateCheckService(
            currentVersion: '1.0.0',
            currentBuildTime: DateTime.utc(2026, 7, 12, 10),
            transport: _FakeTransport(
              response: UpdateHttpResponse(
                statusCode: 200,
                body: jsonEncode(<String, Object?>{
                  'tag_name': 'v99.0.0',
                  'name': 'Future Version Number',
                  'html_url': 'https://example.test/release',
                  'published_at': publishedAt,
                }),
              ),
            ),
            now: () => buildTime,
          );

          final result = await service.check();

          expect(result.latestVersion, '99.0.0');
          expect(result.updateAvailable, isFalse);
          expect(result.error, isNull);
        }
      },
    );

    test(
      'normalizes build and release timezone offsets before comparing',
      () async {
        final service = UpdateCheckService(
          currentVersion: '1.0.0',
          currentBuildTime: DateTime.parse('2026-07-12T18:00:00+08:00'),
          transport: _FakeTransport(
            response: const UpdateHttpResponse(
              statusCode: 200,
              body:
                  '{"tag_name":"timezone-build","name":"timezone","html_url":"https://example.test/release","published_at":"2026-07-12T12:00:00+02:00"}',
            ),
          ),
        );

        final result = await service.check();

        expect(result.updateAvailable, isFalse);
        expect(result.error, isNull);
      },
    );

    test('the same build tag never reports its own release as newer', () async {
      final service = UpdateCheckService(
        currentVersion: '1.0.0',
        currentBuildTime: DateTime.utc(2026, 7, 12, 10),
        currentBuildTag: ' release/20260712 ',
        transport: _FakeTransport(
          response: const UpdateHttpResponse(
            statusCode: 200,
            body:
                '{"tag_name":"release/20260712","name":"same build","html_url":"https://example.test/release","published_at":"2026-07-12T10:05:00Z"}',
          ),
        ),
      );

      final result = await service.check();

      expect(result.latestVersion, 'release/20260712');
      expect(result.updateAvailable, isFalse);
      expect(result.error, isNull);
    });

    test(
      'uses the arbitrary tag when the release name is null or empty',
      () async {
        for (final name in <Object?>[null, '']) {
          final service = UpdateCheckService(
            currentVersion: '99.0.0',
            currentBuildTime: DateTime.utc(2026, 7, 12, 10),
            transport: _FakeTransport(
              response: UpdateHttpResponse(
                statusCode: 200,
                body: jsonEncode(<String, Object?>{
                  'tag_name': 'nightly_foo',
                  'name': name,
                  'html_url': 'https://example.test/release',
                  'published_at': '2026-07-12T10:00:01Z',
                }),
              ),
            ),
            now: () => DateTime.utc(2026, 7, 12, 10),
          );

          final result = await service.check();

          expect(result.updateAvailable, isTrue);
          expect(result.latestVersion, 'nightly_foo');
          expect(result.releaseName, 'nightly_foo');
          expect(result.error, isNull);
        }
      },
    );

    test(
      'missing or invalid published_at fails without exposing the body',
      () async {
        for (final publishedAt in <Object?>[null, '', 'not-a-date']) {
          final json = <String, Object?>{
            'tag_name': 'v2.0.0',
            'name': 'private release name',
            'html_url': 'https://example.test/release',
            'published_at': ?publishedAt,
          };
          final body = jsonEncode(json);
          final service = UpdateCheckService(
            currentVersion: '1.0.0',
            currentBuildTime: DateTime.utc(2026, 7, 12, 10),
            transport: _FakeTransport(
              response: UpdateHttpResponse(statusCode: 200, body: body),
            ),
            now: () => DateTime.utc(2026, 7, 12, 10),
          );

          final result = await service.check();

          expect(result.updateAvailable, isFalse);
          expect(result.latestVersion, isNull);
          expect(result.error, isNotNull);
          expect(result.error, isNot(contains('private release name')));
        }
      },
    );

    test('turns timeout and network errors into safe failures', () async {
      for (final error in <Object>[
        TimeoutException('late response'),
        StateError('socket secret'),
      ]) {
        final service = UpdateCheckService(
          currentVersion: '1.0.0',
          currentBuildTime: DateTime.utc(2026, 7, 12, 10),
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
            currentBuildTime: DateTime.utc(2026, 7, 12, 10),
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

    test(
      'malformed JSON and missing required fields cannot become updates',
      () async {
        final responses = <String>[
          '{bad json',
          '{"tag_name":"","name":"next","html_url":"https://example.test","published_at":"2026-07-12T10:00:01Z"}',
          '{"tag_name":"release-next","name":"next","html_url":"","published_at":"2026-07-12T10:00:01Z"}',
        ];
        for (final body in responses) {
          final service = UpdateCheckService(
            currentVersion: '1.0.0',
            currentBuildTime: DateTime.utc(2026, 7, 12, 10),
            transport: _FakeTransport(
              response: UpdateHttpResponse(statusCode: 200, body: body),
            ),
            now: () => DateTime.utc(2026, 7, 12, 10),
          );

          final result = await service.check();

          expect(result.updateAvailable, isFalse);
          expect(result.latestVersion, isNull);
          expect(result.error, isNotNull);
        }
      },
    );

    test('close releases the injected transport', () {
      final transport = _FakeTransport();
      final service = UpdateCheckService(
        currentVersion: '1.0.0',
        currentBuildTime: DateTime.utc(2026, 7, 12, 10),
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
