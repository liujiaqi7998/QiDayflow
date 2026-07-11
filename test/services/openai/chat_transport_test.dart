import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/services/openai/analysis_exception.dart';
import 'package:qi_day_flow/services/openai/chat_transport.dart';

void main() {
  test('HttpClientChatTransport returns a JSON object', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"choices":[]}');
      await request.response.close();
    });
    final transport = HttpClientChatTransport();
    addTearDown(transport.close);

    final response = await transport.postJson(
      uri: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
      headers: const <String, String>{'authorization': 'Bearer test'},
      body: const <String, Object?>{'model': 'test'},
      timeout: const Duration(seconds: 2),
      maxResponseBytes: 1024,
    );

    expect(response['choices'], isEmpty);
  });

  test('HttpClientChatTransport exposes retryable HTTP failures', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.tooManyRequests
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'message': 'rate limited'},
          }),
        );
      await request.response.close();
    });
    final transport = HttpClientChatTransport();
    addTearDown(transport.close);

    await expectLater(
      transport.postJson(
        uri: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
        headers: const <String, String>{},
        body: const <String, Object?>{'model': 'test'},
        timeout: const Duration(seconds: 2),
        maxResponseBytes: 1024,
      ),
      throwsA(
        isA<AnalysisException>()
            .having((error) => error.kind, 'kind', AnalysisFailureKind.http)
            .having((error) => error.statusCode, 'statusCode', 429)
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('HttpClientChatTransport rejects a non-object response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write('[]');
      await request.response.close();
    });
    final transport = HttpClientChatTransport();
    addTearDown(transport.close);

    await expectLater(
      transport.postJson(
        uri: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
        headers: const <String, String>{},
        body: const <String, Object?>{'model': 'test'},
        timeout: const Duration(seconds: 2),
        maxResponseBytes: 1024,
      ),
      throwsA(
        isA<AnalysisException>().having(
          (error) => error.kind,
          'kind',
          AnalysisFailureKind.protocol,
        ),
      ),
    );
  });
}
