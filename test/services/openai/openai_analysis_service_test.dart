import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/services/openai/analysis_exception.dart';
import 'package:qi_day_flow/services/openai/analysis_models.dart';
import 'package:qi_day_flow/services/openai/chat_transport.dart';
import 'package:qi_day_flow/services/openai/openai_analysis_service.dart';

void main() {
  group('OpenAiAnalysisService observations', () {
    test('sends JPEG frames and applies native window context', () async {
      final transport = _FakeTransport()
        ..enqueue(
          _chatResponse('''```json
{"observations":[{"start_ts":0,"end_ts":20,"text":"编辑采集服务"},{"start_ts":20,"end_ts":60,"text":"查阅接口文档"}]}
```'''),
        );
      final service = _service(transport);

      final observations = await service.analyzeChunk(_chunkInput());

      expect(observations, hasLength(2));
      expect(observations.first.appName, 'Visual Studio Code');
      expect(observations.first.processName, 'Code.exe');
      expect(observations.last.appName, 'Microsoft Edge');
      expect(observations.last.endTime, DateTime.utc(2026, 7, 10, 10, 1));

      final request = transport.requests.single;
      expect(
        request.uri.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(request.headers['authorization'], 'Bearer secret');
      final messages = request.body['messages']! as List<Object?>;
      final userMessage = messages[1]! as Map<String, Object?>;
      final content = userMessage['content']! as List<Object?>;
      final imagePart = content[2]! as Map<String, Object?>;
      final image = imagePart['image_url']! as Map<String, Object?>;
      expect(image['url'], 'data:image/jpeg;base64,/9j/2Q==');
      expect(image['detail'], 'high');
      final serializedRequest = jsonEncode(request.body);
      expect(serializedRequest, isNot(contains('cpuUsagePercent')));
      expect(serializedRequest, isNot(contains('memoryCommitBytes')));
      expect(serializedRequest, isNot(contains('cpu_usage_percent')));
      expect(serializedRequest, isNot(contains('memory_commit_bytes')));
    });

    test('chooses the primary app by cumulative window overlap', () async {
      final transport = _FakeTransport()
        ..enqueue(
          _chatResponse(
            '{"observations":[{"start_ts":0,"end_ts":50,"text":"编辑并查阅资料"}]}',
          ),
        );
      final service = _service(transport);
      final input = AnalysisChunkInput(
        chunkId: 'chunk-primary-window',
        startedAt: DateTime.utc(2026, 7, 10, 10),
        durationSeconds: 60,
        keyFrames: <AnalysisKeyFrame>[
          AnalysisKeyFrame.memory(
            offsetSeconds: 0,
            jpegBytes: <int>[0xff, 0xd8, 0xff, 0xd9],
          ),
        ],
        windowContexts: const <WindowContextSegment>[
          WindowContextSegment(
            startSeconds: 0,
            endSeconds: 10,
            processName: 'Code.exe',
            friendlyAppName: 'Visual Studio Code',
            windowTitle: 'first.dart',
            executablePath: r'C:\Apps\Code.exe',
          ),
          WindowContextSegment(
            startSeconds: 10,
            endSeconds: 20,
            processName: 'Code.exe',
            friendlyAppName: 'Visual Studio Code',
            windowTitle: 'second.dart',
            executablePath: r'C:\Apps\Code.exe',
          ),
          WindowContextSegment(
            startSeconds: 20,
            endSeconds: 30,
            processName: 'Code.exe',
            friendlyAppName: 'Visual Studio Code',
            windowTitle: 'third.dart',
            executablePath: r'C:\Apps\Code.exe',
          ),
          WindowContextSegment(
            startSeconds: 30,
            endSeconds: 50,
            processName: 'msedge.exe',
            friendlyAppName: 'Microsoft Edge',
            windowTitle: 'API reference',
            executablePath: r'C:\Apps\msedge.exe',
          ),
        ],
      );

      final observation = (await service.analyzeChunk(input)).single;

      expect(observation.appName, 'Visual Studio Code');
      expect(observation.processName, 'Code.exe');
      expect(observation.executablePath, r'C:\Apps\Code.exe');
      expect(observation.windowTitle, 'first.dart');
    });

    test('rejects prose surrounding an otherwise valid JSON object', () async {
      final transport = _FakeTransport()
        ..enqueue(
          _chatResponse(
            '结果如下： {"observations":[{"start_ts":0,"end_ts":60,"text":"编辑代码"}]}',
          ),
        );
      final service = _service(transport);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.invalidJson),
      );
    });

    test('rejects empty observations', () async {
      final transport = _FakeTransport()
        ..enqueue(_chatResponse('{"observations":[]}'));
      final service = _service(transport);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.validation),
      );
    });

    test('rejects unknown fields instead of silently ignoring them', () async {
      final transport = _FakeTransport()
        ..enqueue(
          _chatResponse(
            '{"observations":[{"start_ts":0,"end_ts":60,"text":"编辑代码","app_name":"伪造应用"}]}',
          ),
        );
      final service = _service(transport);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.validation),
      );
    });

    test('rejects overlapping or out-of-range observation times', () async {
      final transport = _FakeTransport()
        ..enqueue(
          _chatResponse(
            '{"observations":[{"start_ts":0,"end_ts":40,"text":"编辑代码"},{"start_ts":30,"end_ts":61,"text":"查看文档"}]}',
          ),
        );
      final service = _service(transport);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.validation),
      );
    });

    test('requires choices and message content', () async {
      final transport = _FakeTransport()
        ..enqueue(<String, Object?>{'choices': <Object?>[]});
      final service = _service(transport);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.protocol),
      );
    });

    test('accepts compatible text content parts', () async {
      final transport = _FakeTransport()
        ..enqueue(
          _chatResponse(<Object?>[
            <String, Object?>{'type': 'text', 'text': '{"observations":['},
            <String, Object?>{
              'type': 'text',
              'text': '{"start_ts":0,"end_ts":60,"text":"编辑代码"}]}',
            },
          ]),
        );
      final service = _service(transport);

      final observations = await service.analyzeChunk(_chunkInput());

      expect(observations.single.text, '编辑代码');
    });

    test('propagates an explicit retryable transport failure', () async {
      final transport = _FakeTransport()
        ..enqueue(
          const AnalysisException(
            AnalysisFailureKind.timeout,
            'timeout',
            retryable: true,
          ),
        );
      final service = _service(transport);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        throwsA(
          isA<AnalysisException>()
              .having(
                (error) => error.kind,
                'kind',
                AnalysisFailureKind.timeout,
              )
              .having((error) => error.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('rejects a frame that is not JPEG', () async {
      final transport = _FakeTransport();
      final service = _service(transport);
      final input = AnalysisChunkInput(
        chunkId: 'chunk-1',
        startedAt: DateTime.utc(2026, 7, 10, 10),
        durationSeconds: 60,
        keyFrames: <AnalysisKeyFrame>[
          AnalysisKeyFrame.memory(
            offsetSeconds: 0,
            jpegBytes: <int>[1, 2, 3, 4],
          ),
        ],
        windowContexts: const <WindowContextSegment>[],
      );

      await expectLater(
        service.analyzeChunk(input),
        _throwsKind(AnalysisFailureKind.input),
      );
      expect(transport.requests, isEmpty);
    });

    test('rejects more than eight image frames', () async {
      final transport = _FakeTransport();
      final service = _service(transport);
      final input = AnalysisChunkInput(
        chunkId: 'chunk-1',
        startedAt: DateTime.utc(2026, 7, 10, 10),
        durationSeconds: 60,
        keyFrames: List<AnalysisKeyFrame>.generate(
          9,
          (index) => AnalysisKeyFrame.memory(
            offsetSeconds: index.toDouble(),
            jpegBytes: <int>[0xff, 0xd8, 0xff, 0xd9],
          ),
        ),
        windowContexts: const <WindowContextSegment>[],
      );

      await expectLater(
        service.analyzeChunk(input),
        _throwsKind(AnalysisFailureKind.input),
      );
      expect(transport.requests, isEmpty);
    });

    test(
      'rejects image frames whose combined payload exceeds budget',
      () async {
        final transport = _FakeTransport();
        final service = OpenAiAnalysisService(
          config: const OpenAiAnalysisConfig(
            baseUrl: 'https://api.example.com/v1/',
            apiKey: 'secret',
            model: 'vision-model',
            maxJpegBytes: 4,
            maxImagePayloadBytes: 7,
          ),
          transport: transport,
        );
        final input = AnalysisChunkInput(
          chunkId: 'chunk-1',
          startedAt: DateTime.utc(2026, 7, 10, 10),
          durationSeconds: 60,
          keyFrames: <AnalysisKeyFrame>[
            AnalysisKeyFrame.memory(
              offsetSeconds: 0,
              jpegBytes: <int>[0xff, 0xd8, 0xff, 0xd9],
            ),
            AnalysisKeyFrame.memory(
              offsetSeconds: 1,
              jpegBytes: <int>[0xff, 0xd8, 0xff, 0xd9],
            ),
          ],
          windowContexts: const <WindowContextSegment>[],
        );

        await expectLater(
          service.analyzeChunk(input),
          _throwsKind(AnalysisFailureKind.input),
        );
        expect(transport.requests, isEmpty);
      },
    );
  });

  group('OpenAiAnalysisService cards', () {
    test('parses validated cards and computes absolute timestamps', () async {
      final transport = _FakeTransport()
        ..enqueue(_chatResponse(jsonEncode(_validCardsPayload())));
      final service = _service(transport);
      final batchStart = DateTime.utc(2026, 7, 10, 10);

      final cards = await service.generateCards(
        observations: _observations(batchStart),
        batchStart: batchStart,
        batchEnd: batchStart.add(const Duration(minutes: 10)),
      );

      final card = cards.single;
      expect(card.category, '编程');
      expect(card.startTime, batchStart);
      expect(card.endTime, batchStart.add(const Duration(minutes: 10)));
      expect(card.appSites.single.name, 'Visual Studio Code');
      expect(
        card.distractions.single.timestamp,
        batchStart.add(const Duration(minutes: 5)),
      );
      expect(card.productivityScore, 88);
    });

    test('rejects an unsupported category', () async {
      final payload = _validCardsPayload();
      _singleCard(payload)['category'] = '健身';
      await _expectInvalidCard(payload);
    });

    test('rejects a score outside 0 to 100', () async {
      final payload = _validCardsPayload();
      _singleCard(payload)['productivity_score'] = 101;
      await _expectInvalidCard(payload);
    });

    test('rejects an application absent from native context', () async {
      final payload = _validCardsPayload();
      final appSites = _singleCard(payload)['app_sites']! as List<Object?>;
      (appSites.single! as Map<String, Object?>)['name'] = 'Imaginary App';
      await _expectInvalidCard(payload);
    });

    test('rejects application durations beyond the card duration', () async {
      final payload = _validCardsPayload();
      final appSites = _singleCard(payload)['app_sites']! as List<Object?>;
      (appSites.single! as Map<String, Object?>)['duration_seconds'] = 601;
      await _expectInvalidCard(payload);
    });

    test('rejects distractions outside their card', () async {
      final payload = _validCardsPayload();
      final distractions =
          _singleCard(payload)['distractions']! as List<Object?>;
      (distractions.single! as Map<String, Object?>)['offset_seconds'] = 599;
      (distractions.single! as Map<String, Object?>)['duration_seconds'] = 10;
      await _expectInvalidCard(payload);
    });

    test('rejects empty cards so evidence cannot be deleted', () async {
      await _expectInvalidCard(<String, Object?>{'cards': <Object?>[]});
    });

    test('rejects extra card fields', () async {
      final payload = _validCardsPayload();
      _singleCard(payload)['confidence'] = 0.9;
      await _expectInvalidCard(payload);
    });
  });

  test(
    'generateDailyReport sends the requested date and keeps Markdown',
    () async {
      final transport = _FakeTransport();
      final service = _service(transport);
      final batchStart = DateTime.utc(2026, 7, 10, 10);
      final cards = await _cardsFromPayload(service, transport, batchStart);
      transport.enqueue(
        _chatResponse('# 工作日报 - 2026-07-10\n\n## 今日概览\n完成采集链路。'),
      );

      final report = await service.generateDailyReport(
        cards: cards,
        reportDate: DateTime(2026, 7, 10),
      );

      expect(report, startsWith('# 工作日报 - 2026-07-10'));
      final request = transport.requests.last;
      final messages = request.body['messages']! as List<Object?>;
      final user = messages[1]! as Map<String, Object?>;
      expect(user['content'], contains('"date":"2026-07-10"'));
    },
  );

  test('validates configuration before making a request', () {
    expect(
      () => OpenAiAnalysisService(
        config: const OpenAiAnalysisConfig(
          baseUrl: 'not a URL',
          apiKey: 'secret',
          model: 'vision-model',
        ),
        transport: _FakeTransport(),
      ),
      _throwsKind(AnalysisFailureKind.configuration),
    );
  });

  group('configured attempts', () {
    test('a retryable operation may succeed on the fourth attempt', () async {
      final transport = _FakeTransport();
      for (var attempt = 0; attempt < 3; attempt++) {
        transport.enqueue(
          const AnalysisException(
            AnalysisFailureKind.timeout,
            'retryable timeout',
            retryable: true,
          ),
        );
      }
      transport.enqueue(
        _chatResponse(
          '{"observations":[{"start_ts":0,"end_ts":60,"text":"完成分析"}]}',
        ),
      );
      final service = _serviceWithAttempts(transport, 4);

      final result = await service.analyzeChunk(_chunkInput());

      expect(result.single.text, '完成分析');
      expect(transport.requests, hasLength(4));
    });

    test('a non-retryable failure is attempted only once', () async {
      final transport = _FakeTransport()
        ..enqueue(
          const AnalysisException(
            AnalysisFailureKind.http,
            'bad request',
            statusCode: 400,
          ),
        );
      final service = _serviceWithAttempts(transport, 4);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.http),
      );
      expect(transport.requests, hasLength(1));
    });

    test('an unclassified transport error is not retried', () async {
      final transport = _FakeTransport()..enqueue(StateError('client closed'));
      final service = _serviceWithAttempts(transport, 4);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        throwsA(
          isA<AnalysisException>()
              .having(
                (error) => error.kind,
                'kind',
                AnalysisFailureKind.network,
              )
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      );
      expect(transport.requests, hasLength(1));
    });

    test('zero retries maps to one attempt', () async {
      final transport = _FakeTransport()
        ..enqueue(
          const AnalysisException(
            AnalysisFailureKind.timeout,
            'retryable timeout',
            retryable: true,
          ),
        );
      final service = _serviceWithAttempts(transport, 1);

      await expectLater(
        service.analyzeChunk(_chunkInput()),
        _throwsKind(AnalysisFailureKind.timeout),
      );
      expect(transport.requests, hasLength(1));
    });

    test('configuration accepts six attempts but rejects seven', () {
      expect(() => _serviceWithAttempts(_FakeTransport(), 6), returnsNormally);
      expect(
        () => _serviceWithAttempts(_FakeTransport(), 7),
        _throwsKind(AnalysisFailureKind.configuration),
      );
    });
  });
}

OpenAiAnalysisService _service(_FakeTransport transport) =>
    OpenAiAnalysisService(
      config: const OpenAiAnalysisConfig(
        baseUrl: 'https://api.example.com/v1/',
        apiKey: 'secret',
        model: 'vision-model',
      ),
      transport: transport,
    );

OpenAiAnalysisService _serviceWithAttempts(
  _FakeTransport transport,
  int maxAttempts,
) => OpenAiAnalysisService(
  config: OpenAiAnalysisConfig(
    baseUrl: 'https://api.example.com/v1/',
    apiKey: 'secret',
    model: 'vision-model',
    maxAttempts: maxAttempts,
    retryBaseDelay: Duration.zero,
  ),
  transport: transport,
);

AnalysisChunkInput _chunkInput() => AnalysisChunkInput(
  chunkId: 'chunk-1',
  startedAt: DateTime.utc(2026, 7, 10, 10),
  durationSeconds: 60,
  keyFrames: <AnalysisKeyFrame>[
    AnalysisKeyFrame.memory(
      offsetSeconds: 0,
      jpegBytes: <int>[0xff, 0xd8, 0xff, 0xd9],
    ),
  ],
  windowContexts: const <WindowContextSegment>[
    WindowContextSegment(
      startSeconds: 0,
      endSeconds: 30,
      processName: 'Code.exe',
      friendlyAppName: 'Visual Studio Code',
      windowTitle: 'openai_analysis_service.dart - Qi Day Flow',
      cpuUsagePercent: 7.5,
      memoryCommitBytes: 512 * 1024 * 1024,
    ),
    WindowContextSegment(
      startSeconds: 30,
      endSeconds: 60,
      processName: 'msedge.exe',
      friendlyAppName: 'Microsoft Edge',
      windowTitle: 'OpenAI API reference',
    ),
  ],
);

List<AnalysisObservation> _observations(DateTime batchStart) =>
    <AnalysisObservation>[
      AnalysisObservation(
        chunkId: 'chunk-1',
        startSeconds: 0,
        endSeconds: 600,
        startTime: batchStart,
        endTime: batchStart.add(const Duration(minutes: 10)),
        text: '实现采集服务并检查错误处理',
        processName: 'Code.exe',
        appName: 'Visual Studio Code',
        windowTitle: 'openai_analysis_service.dart - Qi Day Flow',
      ),
    ];

Map<String, Object?> _validCardsPayload() => <String, Object?>{
  'cards': <Object?>[
    <String, Object?>{
      'category': '编程',
      'title': 'Qi Day Flow 分析服务',
      'summary': '实现两阶段视觉分析和严格响应校验',
      'start_offset_seconds': 0,
      'end_offset_seconds': 600,
      'app_sites': <Object?>[
        <String, Object?>{
          'name': 'Visual Studio Code',
          'duration_seconds': 580,
        },
      ],
      'distractions': <Object?>[
        <String, Object?>{
          'description': '短暂查看消息',
          'offset_seconds': 300,
          'duration_seconds': 10,
        },
      ],
      'productivity_score': 88,
    },
  ],
};

Map<String, Object?> _singleCard(Map<String, Object?> payload) =>
    (payload['cards']! as List<Object?>).single! as Map<String, Object?>;

Future<void> _expectInvalidCard(Map<String, Object?> payload) async {
  final transport = _FakeTransport()
    ..enqueue(_chatResponse(jsonEncode(payload)));
  final service = _service(transport);
  final batchStart = DateTime.utc(2026, 7, 10, 10);

  await expectLater(
    service.generateCards(
      observations: _observations(batchStart),
      batchStart: batchStart,
      batchEnd: batchStart.add(const Duration(minutes: 10)),
    ),
    _throwsKind(AnalysisFailureKind.validation),
  );
}

Future<List<AnalysisCard>> _cardsFromPayload(
  OpenAiAnalysisService service,
  _FakeTransport transport,
  DateTime batchStart,
) async {
  transport.enqueue(_chatResponse(jsonEncode(_validCardsPayload())));
  return service.generateCards(
    observations: _observations(batchStart),
    batchStart: batchStart,
    batchEnd: batchStart.add(const Duration(minutes: 10)),
  );
}

Matcher _throwsKind(AnalysisFailureKind kind) => throwsA(
  isA<AnalysisException>().having((error) => error.kind, 'kind', kind),
);

Map<String, Object?> _chatResponse(Object content) => <String, Object?>{
  'choices': <Object?>[
    <String, Object?>{
      'message': <String, Object?>{'content': content},
    },
  ],
};

final class _FakeTransport implements ChatTransport {
  final Queue<Object> _responses = Queue<Object>();
  final List<_CapturedRequest> requests = <_CapturedRequest>[];

  void enqueue(Object response) => _responses.add(response);

  @override
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    requests.add(
      _CapturedRequest(
        uri: uri,
        headers: Map<String, String>.from(headers),
        body: Map<String, Object?>.from(body),
      ),
    );
    final response = _responses.removeFirst();
    if (response is AnalysisException) {
      throw response;
    }
    return response as Map<String, Object?>;
  }

  @override
  void close() {}
}

final class _CapturedRequest {
  const _CapturedRequest({
    required this.uri,
    required this.headers,
    required this.body,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
