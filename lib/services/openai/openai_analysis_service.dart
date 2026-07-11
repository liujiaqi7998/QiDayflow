import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analysis_exception.dart';
import 'analysis_models.dart';
import 'chat_transport.dart';
import 'prompts.dart';

const Set<String> supportedActivityCategories = <String>{
  '编程',
  '工作',
  '学习',
  '会议',
  '社交',
  '娱乐',
  '休息',
  '其他',
};

final class OpenAiAnalysisService {
  OpenAiAnalysisService({
    required OpenAiAnalysisConfig config,
    ChatTransport? transport,
    HttpClient? httpClient,
  }) : _config = config,
       _transport = transport ?? HttpClientChatTransport(client: httpClient) {
    if (transport != null && httpClient != null) {
      throw const AnalysisException(
        AnalysisFailureKind.configuration,
        '不能同时注入 ChatTransport 和 HttpClient',
      );
    }
    _endpoint = _validateConfig(config);
  }

  final OpenAiAnalysisConfig _config;
  final ChatTransport _transport;
  late final Uri _endpoint;

  Future<void> testConnection() async {
    final responseText = await _complete(<Map<String, Object?>>[
      <String, Object?>{
        'role': 'system',
        'content': '只返回一个 JSON 对象：{"ok":true}。不得输出其他文字。',
      },
      <String, Object?>{'role': 'user', 'content': '连接测试'},
    ], temperature: 0);
    final payload = _decodeModelObject(responseText);
    if (payload.length != 1 || payload['ok'] != true) {
      throw const AnalysisException(
        AnalysisFailureKind.validation,
        '模型未返回预期的连接测试结果',
      );
    }
  }

  Future<List<AnalysisObservation>> analyzeChunk(
    AnalysisChunkInput input,
  ) async {
    _validateChunkInput(input);
    final keyFrames = input.keyFrames.toList()
      ..sort(
        (left, right) => left.offsetSeconds.compareTo(right.offsetSeconds),
      );
    final windows = input.windowContexts.toList()
      ..sort((left, right) => left.startSeconds.compareTo(right.startSeconds));

    final content = <Object?>[
      <String, Object?>{
        'type': 'text',
        'text': jsonEncode(<String, Object?>{
          'task': '分析关键帧并返回 observations JSON',
          'chunk_id': input.chunkId,
          'chunk_started_at': input.startedAt.toIso8601String(),
          'duration_seconds': input.durationSeconds,
          'window_context': windows
              .map((window) => window.toPromptJson())
              .toList(growable: false),
        }),
      },
    ];

    var totalImageBytes = 0;
    for (var index = 0; index < keyFrames.length; index++) {
      final frame = keyFrames[index];
      final bytes = await _readJpeg(frame);
      totalImageBytes += bytes.length;
      if (totalImageBytes > _config.maxImagePayloadBytes) {
        throw const AnalysisException(
          AnalysisFailureKind.input,
          '关键帧总载荷超过大小预算',
        );
      }
      content
        ..add(<String, Object?>{
          'type': 'text',
          'text':
              '关键帧 ${index + 1}/${keyFrames.length}，切片相对时间 '
              '${frame.offsetSeconds.toStringAsFixed(3)} 秒',
        })
        ..add(<String, Object?>{
          'type': 'image_url',
          'image_url': <String, Object?>{
            'url': 'data:image/jpeg;base64,${base64Encode(bytes)}',
            'detail': 'high',
          },
        });
    }

    final responseText = await _complete(<Map<String, Object?>>[
      <String, Object?>{
        'role': 'system',
        'content': OpenAiPrompts.observationSystem,
      },
      <String, Object?>{'role': 'user', 'content': content},
    ], temperature: 0.2);
    final payload = _decodeModelObject(responseText);
    return _parseObservations(payload, input, windows);
  }

  Future<List<AnalysisCard>> generateCards({
    required List<AnalysisObservation> observations,
    required DateTime batchStart,
    required DateTime batchEnd,
    List<AnalysisCard> recentCards = const <AnalysisCard>[],
  }) async {
    final batchDuration = _validateCardInput(
      observations,
      batchStart,
      batchEnd,
    );
    final orderedObservations = observations.toList()
      ..sort((left, right) => left.startTime.compareTo(right.startTime));
    final orderedRecentCards = recentCards.toList()
      ..sort((left, right) => left.endTime.compareTo(right.endTime));
    final contextStart = orderedRecentCards.length > 3
        ? orderedRecentCards.length - 3
        : 0;

    final inputPayload = <String, Object?>{
      'batch_started_at': batchStart.toIso8601String(),
      'batch_duration_seconds': batchDuration,
      'observations': orderedObservations
          .map(
            (observation) => <String, Object?>{
              'start_offset_seconds': _secondsBetween(
                batchStart,
                observation.startTime,
              ),
              'end_offset_seconds': _secondsBetween(
                batchStart,
                observation.endTime,
              ),
              'text': observation.text,
              'app_name': observation.appName,
              'process_name': observation.processName,
              'window_title': observation.windowTitle,
            },
          )
          .toList(growable: false),
      'recent_cards': orderedRecentCards
          .skip(contextStart)
          .map(
            (card) => <String, Object?>{
              'category': card.category,
              'title': card.title,
              'ended_at': card.endTime.toIso8601String(),
            },
          )
          .toList(growable: false),
    };

    final responseText = await _complete(<Map<String, Object?>>[
      <String, Object?>{'role': 'system', 'content': OpenAiPrompts.cardsSystem},
      <String, Object?>{'role': 'user', 'content': jsonEncode(inputPayload)},
    ], temperature: 0.2);
    final payload = _decodeModelObject(responseText);
    final observedApps = orderedObservations
        .map((observation) => observation.appName?.trim())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toSet();
    return _parseCards(
      payload,
      batchStart: batchStart,
      batchDuration: batchDuration,
      observedApps: observedApps,
    );
  }

  Future<String> generateDailyReport({
    required List<AnalysisCard> cards,
    required DateTime reportDate,
  }) async {
    if (cards.isEmpty) {
      throw const AnalysisException(
        AnalysisFailureKind.input,
        '生成日报至少需要一张活动卡片',
      );
    }
    final date = _formatDate(reportDate);
    final payload = <String, Object?>{
      'date': date,
      'cards': cards
          .map(
            (card) => <String, Object?>{
              'category': card.category,
              'title': card.title,
              'summary': card.summary,
              'start_time': card.startTime.toIso8601String(),
              'end_time': card.endTime.toIso8601String(),
              'duration_minutes': card.duration.inSeconds / 60,
              'productivity_score': card.productivityScore,
              'apps': card.appSites.map((app) => app.name).toList(),
              'distraction_count': card.distractions.length,
            },
          )
          .toList(growable: false),
    };
    final report = await _complete(<Map<String, Object?>>[
      <String, Object?>{
        'role': 'system',
        'content': OpenAiPrompts.dailyReportSystem,
      },
      <String, Object?>{'role': 'user', 'content': jsonEncode(payload)},
    ], temperature: 0.5);
    if (report.length > 100000) {
      throw const AnalysisException(AnalysisFailureKind.validation, '日报内容过长');
    }
    return report;
  }

  void close() => _transport.close();

  Future<String> _complete(
    List<Map<String, Object?>> messages, {
    required double temperature,
  }) async {
    AnalysisException? lastError;
    for (var attempt = 1; attempt <= _config.maxAttempts; attempt++) {
      try {
        final response = await _transport.postJson(
          uri: _endpoint,
          headers: <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer ${_config.apiKey.trim()}',
            HttpHeaders.acceptHeader: ContentType.json.mimeType,
          },
          body: <String, Object?>{
            'model': _config.model.trim(),
            'messages': messages,
            'temperature': temperature,
            'max_tokens': _config.maxTokens,
          },
          timeout: _config.timeout,
          maxResponseBytes: _config.maxResponseBytes,
        );
        return _extractResponseContent(response);
      } on AnalysisException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = AnalysisException(
          AnalysisFailureKind.timeout,
          'API 请求超时',
          retryable: true,
          cause: error,
        );
      } on Object catch (error) {
        lastError = AnalysisException(
          AnalysisFailureKind.network,
          '分析服务传输失败',
          retryable: true,
          cause: error,
        );
      }
      if (!lastError.retryable || attempt == _config.maxAttempts) {
        throw lastError;
      }
      await Future<void>.delayed(_config.retryBaseDelay * attempt);
    }
    throw lastError!;
  }

  Future<List<int>> _readJpeg(AnalysisKeyFrame frame) async {
    final List<int> bytes;
    try {
      bytes = await frame.readBytes();
    } on FileSystemException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.io,
        '关键帧文件无法读取',
        cause: error,
      );
    } on IOException catch (error) {
      throw AnalysisException(AnalysisFailureKind.io, '关键帧读取失败', cause: error);
    }

    if (bytes.length < 4 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes[bytes.length - 1] != 0xd9) {
      throw const AnalysisException(
        AnalysisFailureKind.input,
        '关键帧不是合法 JPEG 数据',
      );
    }
    if (bytes.length > _config.maxJpegBytes) {
      throw const AnalysisException(AnalysisFailureKind.input, '关键帧超过大小预算');
    }
    return bytes;
  }

  static Uri _validateConfig(OpenAiAnalysisConfig config) {
    final baseUrl = config.baseUrl.trim();
    final apiKey = config.apiKey.trim();
    final model = config.model.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) {
      throw const AnalysisException(
        AnalysisFailureKind.configuration,
        'API URL、密钥和模型不能为空',
      );
    }
    if (config.timeout <= Duration.zero ||
        config.maxTokens <= 0 ||
        config.maxJpegBytes <= 0 ||
        config.maxJpegBytes > 2 * 1024 * 1024 ||
        config.maxImagePayloadBytes < config.maxJpegBytes ||
        config.maxImagePayloadBytes > 12 * 1024 * 1024 ||
        config.maxImageFrames < 1 ||
        config.maxImageFrames > 8 ||
        config.maxResponseBytes <= 0 ||
        config.maxAttempts < 1 ||
        config.maxAttempts > 5 ||
        config.retryBaseDelay.isNegative) {
      throw const AnalysisException(
        AnalysisFailureKind.configuration,
        'API 超时和大小预算必须为正数',
      );
    }

    final uri = Uri.tryParse(baseUrl);
    final isLoopback =
        uri != null &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1');
    if (uri == null ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && isLoopback)) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const AnalysisException(
        AnalysisFailureKind.configuration,
        'API URL 必须是有效的 HTTP(S) 地址且不能包含查询、片段或用户信息',
      );
    }

    var endpointPath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (!endpointPath.endsWith('/chat/completions')) {
      endpointPath = '$endpointPath/chat/completions';
    }
    if (!endpointPath.startsWith('/')) {
      endpointPath = '/$endpointPath';
    }
    return uri.replace(path: endpointPath);
  }

  void _validateChunkInput(AnalysisChunkInput input) {
    _requireText(input.chunkId, r'chunk.id', maxLength: 160);
    final duration = input.durationSeconds;
    if (!duration.isFinite || duration <= 0 || duration > 86400) {
      throw const AnalysisException(
        AnalysisFailureKind.input,
        '切片时长必须在 0 到 86400 秒之间',
      );
    }
    if (input.keyFrames.isEmpty ||
        input.keyFrames.length > _config.maxImageFrames) {
      throw AnalysisException(
        AnalysisFailureKind.input,
        '关键帧数量必须在 1 到 ${_config.maxImageFrames} 之间',
      );
    }

    final frames = input.keyFrames.toList()
      ..sort(
        (left, right) => left.offsetSeconds.compareTo(right.offsetSeconds),
      );
    double? previousFrame;
    for (final frame in frames) {
      if (!frame.offsetSeconds.isFinite ||
          frame.offsetSeconds < 0 ||
          frame.offsetSeconds > duration) {
        throw const AnalysisException(
          AnalysisFailureKind.input,
          '关键帧时间必须落在切片范围内',
        );
      }
      if (previousFrame != null && frame.offsetSeconds <= previousFrame) {
        throw const AnalysisException(
          AnalysisFailureKind.input,
          '关键帧时间必须严格递增且不能重复',
        );
      }
      previousFrame = frame.offsetSeconds;
    }

    if (input.windowContexts.length > 5000) {
      throw const AnalysisException(AnalysisFailureKind.input, '窗口上下文数量超过限制');
    }
    final windows = input.windowContexts.toList()
      ..sort((left, right) => left.startSeconds.compareTo(right.startSeconds));
    var previousEnd = 0.0;
    for (var index = 0; index < windows.length; index++) {
      final window = windows[index];
      if (!window.startSeconds.isFinite ||
          !window.endSeconds.isFinite ||
          window.startSeconds < 0 ||
          window.startSeconds >= window.endSeconds ||
          window.endSeconds > duration + 0.001) {
        throw const AnalysisException(AnalysisFailureKind.input, '窗口上下文时间无效');
      }
      if (index > 0 && window.startSeconds < previousEnd - 0.001) {
        throw const AnalysisException(
          AnalysisFailureKind.input,
          '窗口上下文必须按时间排列且不能重叠',
        );
      }
      _requireText(window.processName, 'window.processName', maxLength: 260);
      _requireText(
        window.friendlyAppName,
        'window.friendlyAppName',
        maxLength: 160,
      );
      if (window.windowTitle.length > 2000) {
        throw const AnalysisException(AnalysisFailureKind.input, '窗口标题过长');
      }
      previousEnd = window.endSeconds;
    }
  }

  static double _validateCardInput(
    List<AnalysisObservation> observations,
    DateTime batchStart,
    DateTime batchEnd,
  ) {
    if (!batchEnd.isAfter(batchStart)) {
      throw const AnalysisException(
        AnalysisFailureKind.input,
        '分析批次结束时间必须晚于开始时间',
      );
    }
    if (observations.isEmpty || observations.length > 500) {
      throw const AnalysisException(
        AnalysisFailureKind.input,
        '观察记录数量必须在 1 到 500 之间',
      );
    }
    final duration = _secondsBetween(batchStart, batchEnd);
    if (duration > 86400) {
      throw const AnalysisException(
        AnalysisFailureKind.input,
        '单个分析批次不能超过 24 小时',
      );
    }

    final ordered = observations.toList()
      ..sort((left, right) => left.startTime.compareTo(right.startTime));
    DateTime? previousEnd;
    for (final observation in ordered) {
      if (observation.startTime.isBefore(batchStart) ||
          observation.endTime.isAfter(batchEnd) ||
          !observation.endTime.isAfter(observation.startTime)) {
        throw const AnalysisException(
          AnalysisFailureKind.input,
          '观察记录时间必须落在分析批次内',
        );
      }
      if (previousEnd != null && observation.startTime.isBefore(previousEnd)) {
        throw const AnalysisException(AnalysisFailureKind.input, '观察记录不能重叠');
      }
      _requireText(observation.text, 'observation.text', maxLength: 1000);
      previousEnd = observation.endTime;
    }
    return duration;
  }

  static List<AnalysisObservation> _parseObservations(
    Map<String, Object?> payload,
    AnalysisChunkInput input,
    List<WindowContextSegment> windows,
  ) {
    _requireExactKeys(payload, const <String>{'observations'}, r'$');
    final items = _requireList(payload['observations'], r'$.observations');
    if (items.isEmpty || items.length > 100) {
      throw const AnalysisException(
        AnalysisFailureKind.validation,
        'observations 数量必须在 1 到 100 之间',
      );
    }

    final observations = <AnalysisObservation>[];
    var previousEnd = 0.0;
    for (var index = 0; index < items.length; index++) {
      final path = '\$.observations[$index]';
      final item = _requireMap(items[index], path);
      _requireExactKeys(item, const <String>{
        'start_ts',
        'end_ts',
        'text',
      }, path);
      final start = _requireNumber(item['start_ts'], '$path.start_ts');
      final end = _requireNumber(item['end_ts'], '$path.end_ts');
      final text = _requireText(item['text'], '$path.text', maxLength: 1000);
      if (start < 0 || start >= end || end > input.durationSeconds + 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path 时间必须落在切片范围内且 start_ts < end_ts',
        );
      }
      if (index > 0 && start < previousEnd - 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path 与前一条 observation 重叠或未按时间排序',
        );
      }
      final primaryWindow = _primaryWindow(start, end, windows);
      observations.add(
        AnalysisObservation(
          chunkId: input.chunkId,
          startSeconds: start,
          endSeconds: end,
          startTime: _addSeconds(input.startedAt, start),
          endTime: _addSeconds(input.startedAt, end),
          text: text,
          processName: primaryWindow?.processName,
          appName: primaryWindow?.friendlyAppName,
          windowTitle: primaryWindow?.windowTitle,
          executablePath: primaryWindow?.executablePath,
        ),
      );
      previousEnd = end;
    }
    return List<AnalysisObservation>.unmodifiable(observations);
  }

  static List<AnalysisCard> _parseCards(
    Map<String, Object?> payload, {
    required DateTime batchStart,
    required double batchDuration,
    required Set<String> observedApps,
  }) {
    _requireExactKeys(payload, const <String>{'cards'}, r'$');
    final items = _requireList(payload['cards'], r'$.cards');
    if (items.isEmpty || items.length > 100) {
      throw const AnalysisException(
        AnalysisFailureKind.validation,
        'cards 数量必须在 1 到 100 之间',
      );
    }

    final cards = <AnalysisCard>[];
    var previousEnd = 0.0;
    for (var index = 0; index < items.length; index++) {
      final path = '\$.cards[$index]';
      final item = _requireMap(items[index], path);
      _requireExactKeys(item, const <String>{
        'category',
        'title',
        'summary',
        'start_offset_seconds',
        'end_offset_seconds',
        'app_sites',
        'distractions',
        'productivity_score',
      }, path);
      final category = _requireText(
        item['category'],
        '$path.category',
        maxLength: 16,
      );
      if (!supportedActivityCategories.contains(category)) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path.category 不是支持的活动类别',
        );
      }
      final title = _requireText(item['title'], '$path.title', maxLength: 160);
      final summary = _requireText(
        item['summary'],
        '$path.summary',
        maxLength: 1200,
      );
      final start = _requireNumber(
        item['start_offset_seconds'],
        '$path.start_offset_seconds',
      );
      final end = _requireNumber(
        item['end_offset_seconds'],
        '$path.end_offset_seconds',
      );
      if (start < 0 || start >= end || end > batchDuration + 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path 时间必须落在批次范围内且 start < end',
        );
      }
      if (index > 0 && start < previousEnd - 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path 与前一卡片重叠或未按时间排序',
        );
      }

      final cardDuration = end - start;
      final appSites = _parseAppSites(
        item['app_sites'],
        path: '$path.app_sites',
        cardDuration: cardDuration,
        observedApps: observedApps,
      );
      final distractions = _parseDistractions(
        item['distractions'],
        path: '$path.distractions',
        cardStart: start,
        cardEnd: end,
        batchStart: batchStart,
      );
      final score = _requireNumber(
        item['productivity_score'],
        '$path.productivity_score',
      );
      if (score < 0 || score > 100) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path.productivity_score 必须在 0 到 100 之间',
        );
      }

      cards.add(
        AnalysisCard(
          category: category,
          title: title,
          summary: summary,
          startTime: _addSeconds(batchStart, start),
          endTime: _addSeconds(batchStart, end),
          appSites: appSites,
          distractions: distractions,
          productivityScore: score,
        ),
      );
      previousEnd = end;
    }
    return List<AnalysisCard>.unmodifiable(cards);
  }

  static List<AnalysisAppSite> _parseAppSites(
    Object? value, {
    required String path,
    required double cardDuration,
    required Set<String> observedApps,
  }) {
    final items = _requireList(value, path);
    if (items.length > 32) {
      throw AnalysisException(AnalysisFailureKind.validation, '$path 数量超过限制');
    }
    final apps = <AnalysisAppSite>[];
    final names = <String>{};
    var totalDuration = 0.0;
    for (var index = 0; index < items.length; index++) {
      final itemPath = '$path[$index]';
      final item = _requireMap(items[index], itemPath);
      _requireExactKeys(item, const <String>{
        'name',
        'duration_seconds',
      }, itemPath);
      final name = _requireText(item['name'], '$itemPath.name', maxLength: 160);
      if (!observedApps.contains(name)) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$itemPath.name 未出现在系统窗口上下文中',
        );
      }
      if (!names.add(name)) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$itemPath.name 重复',
        );
      }
      final duration = _requireNumber(
        item['duration_seconds'],
        '$itemPath.duration_seconds',
      );
      if (duration <= 0 || duration > cardDuration + 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$itemPath.duration_seconds 必须为正且不能超过卡片时长',
        );
      }
      totalDuration += duration;
      apps.add(AnalysisAppSite(name: name, durationSeconds: duration));
    }
    if (totalDuration > cardDuration + 0.001) {
      throw AnalysisException(
        AnalysisFailureKind.validation,
        '$path 的累计时长不能超过卡片时长',
      );
    }
    return apps;
  }

  static List<AnalysisDistraction> _parseDistractions(
    Object? value, {
    required String path,
    required double cardStart,
    required double cardEnd,
    required DateTime batchStart,
  }) {
    final items = _requireList(value, path);
    if (items.length > 100) {
      throw AnalysisException(AnalysisFailureKind.validation, '$path 数量超过限制');
    }
    final distractions = <AnalysisDistraction>[];
    var previousOffset = cardStart;
    for (var index = 0; index < items.length; index++) {
      final itemPath = '$path[$index]';
      final item = _requireMap(items[index], itemPath);
      _requireExactKeys(item, const <String>{
        'description',
        'offset_seconds',
        'duration_seconds',
      }, itemPath);
      final description = _requireText(
        item['description'],
        '$itemPath.description',
        maxLength: 300,
      );
      final offset = _requireNumber(
        item['offset_seconds'],
        '$itemPath.offset_seconds',
      );
      final duration = _requireNumber(
        item['duration_seconds'],
        '$itemPath.duration_seconds',
      );
      if (offset < cardStart - 0.001 ||
          offset > cardEnd + 0.001 ||
          duration < 0 ||
          offset + duration > cardEnd + 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$itemPath 必须完整落在卡片时间范围内',
        );
      }
      if (index > 0 && offset < previousOffset - 0.001) {
        throw AnalysisException(
          AnalysisFailureKind.validation,
          '$path 必须按时间排序',
        );
      }
      distractions.add(
        AnalysisDistraction(
          description: description,
          offsetSeconds: offset,
          timestamp: _addSeconds(batchStart, offset),
          durationSeconds: duration,
        ),
      );
      previousOffset = offset;
    }
    return distractions;
  }

  static WindowContextSegment? _primaryWindow(
    double observationStart,
    double observationEnd,
    List<WindowContextSegment> windows,
  ) {
    final overlapByIdentity = <(String, String, String?), double>{};
    final representativeByIdentity =
        <(String, String, String?), WindowContextSegment>{};
    final representativeOverlap = <(String, String, String?), double>{};
    for (final window in windows) {
      final overlapStart = observationStart > window.startSeconds
          ? observationStart
          : window.startSeconds;
      final overlapEnd = observationEnd < window.endSeconds
          ? observationEnd
          : window.endSeconds;
      final overlap = overlapEnd - overlapStart;
      if (overlap <= 0) continue;
      final identity = (
        window.friendlyAppName,
        window.processName,
        window.executablePath,
      );
      overlapByIdentity.update(
        identity,
        (current) => current + overlap,
        ifAbsent: () => overlap,
      );
      if (overlap > (representativeOverlap[identity] ?? 0)) {
        representativeByIdentity[identity] = window;
        representativeOverlap[identity] = overlap;
      }
    }
    (String, String, String?)? primaryIdentity;
    var longestOverlap = 0.0;
    for (final entry in overlapByIdentity.entries) {
      if (entry.value > longestOverlap) {
        primaryIdentity = entry.key;
        longestOverlap = entry.value;
      }
    }
    return primaryIdentity == null
        ? null
        : representativeByIdentity[primaryIdentity];
  }

  static String _extractResponseContent(Map<String, Object?> response) {
    final choices = response['choices'];
    if (choices is! List<Object?> || choices.isEmpty) {
      throw const AnalysisException(
        AnalysisFailureKind.protocol,
        'API 响应缺少非空 choices',
      );
    }
    final choice = _requireMap(
      choices.first,
      r'$.choices[0]',
      failureKind: AnalysisFailureKind.protocol,
    );
    final message = _requireMap(
      choice['message'],
      r'$.choices[0].message',
      failureKind: AnalysisFailureKind.protocol,
    );
    final content = message['content'];
    final parts = <String>[];
    if (content is String) {
      parts.add(content);
    } else if (content is List<Object?>) {
      for (var index = 0; index < content.length; index++) {
        final part = content[index];
        if (part is String) {
          parts.add(part);
          continue;
        }
        final partMap = _requireMap(
          part,
          '\$.choices[0].message.content[$index]',
          failureKind: AnalysisFailureKind.protocol,
        );
        final text = partMap['text'];
        if (text is! String) {
          throw const AnalysisException(
            AnalysisFailureKind.protocol,
            'API content part 缺少文本',
          );
        }
        parts.add(text);
      }
    } else {
      throw const AnalysisException(
        AnalysisFailureKind.protocol,
        'API message.content 类型无效',
      );
    }

    final result = parts.join('\n').trim();
    if (result.isEmpty) {
      throw const AnalysisException(
        AnalysisFailureKind.protocol,
        'API message.content 为空',
      );
    }
    return result;
  }

  static Map<String, Object?> _decodeModelObject(String content) {
    var jsonText = content.trim();
    if (jsonText.startsWith('```')) {
      final firstLineEnd = jsonText.indexOf('\n');
      if (firstLineEnd < 0 || !jsonText.endsWith('```')) {
        throw const AnalysisException(
          AnalysisFailureKind.invalidJson,
          '模型 JSON 代码围栏不完整',
        );
      }
      final fence = jsonText.substring(0, firstLineEnd).trim().toLowerCase();
      if (fence != '```' && fence != '```json') {
        throw const AnalysisException(
          AnalysisFailureKind.invalidJson,
          '模型响应使用了不支持的代码围栏',
        );
      }
      jsonText = jsonText
          .substring(firstLineEnd + 1, jsonText.length - 3)
          .trim();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.invalidJson,
        '模型响应不是单一合法 JSON 对象',
        cause: error,
      );
    }
    return _requireMap(
      decoded,
      r'$',
      failureKind: AnalysisFailureKind.validation,
    );
  }

  static Map<String, Object?> _requireMap(
    Object? value,
    String path, {
    AnalysisFailureKind failureKind = AnalysisFailureKind.validation,
  }) {
    if (value is! Map<Object?, Object?>) {
      throw AnalysisException(failureKind, '$path 必须是 JSON 对象');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw AnalysisException(failureKind, '$path 的字段名必须是字符串');
      }
      result[key] = entry.value;
    }
    return result;
  }

  static List<Object?> _requireList(Object? value, String path) {
    if (value is! List<Object?>) {
      throw AnalysisException(
        AnalysisFailureKind.validation,
        '$path 必须是 JSON 数组',
      );
    }
    return value;
  }

  static String _requireText(
    Object? value,
    String path, {
    required int maxLength,
  }) {
    if (value is! String) {
      throw AnalysisException(AnalysisFailureKind.validation, '$path 必须是字符串');
    }
    final text = value.trim();
    if (text.isEmpty || text.length > maxLength) {
      throw AnalysisException(
        AnalysisFailureKind.validation,
        '$path 必须非空且不超过 $maxLength 个字符',
      );
    }
    return text;
  }

  static double _requireNumber(Object? value, String path) {
    if (value is! num) {
      throw AnalysisException(AnalysisFailureKind.validation, '$path 必须是数字');
    }
    final number = value.toDouble();
    if (!number.isFinite) {
      throw AnalysisException(AnalysisFailureKind.validation, '$path 必须是有限数字');
    }
    return number;
  }

  static void _requireExactKeys(
    Map<String, Object?> value,
    Set<String> expected,
    String path,
  ) {
    final actual = value.keys.toSet();
    final missing = expected.difference(actual);
    final extra = actual.difference(expected);
    if (missing.isNotEmpty || extra.isNotEmpty) {
      throw AnalysisException(
        AnalysisFailureKind.validation,
        '$path 字段不匹配，缺少 ${missing.join(',')}，多出 ${extra.join(',')}',
      );
    }
  }

  static DateTime _addSeconds(DateTime value, double seconds) => value.add(
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()),
  );

  static double _secondsBetween(DateTime start, DateTime end) =>
      end.difference(start).inMicroseconds / Duration.microsecondsPerSecond;

  static String _formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
