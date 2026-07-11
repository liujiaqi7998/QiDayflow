import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'analysis_exception.dart';

abstract interface class ChatTransport {
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required int maxResponseBytes,
  });

  void close();
}

final class HttpClientChatTransport implements ChatTransport {
  HttpClientChatTransport({HttpClient? client})
    : _client = client ?? HttpClient(),
      _ownsClient = client == null;

  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    HttpClientRequest? activeRequest;

    Future<Map<String, Object?>> send() async {
      activeRequest = await _client.postUrl(uri);
      headers.forEach(activeRequest!.headers.set);
      activeRequest!.headers.contentType = ContentType.json;
      activeRequest!.add(utf8.encode(jsonEncode(body)));

      final response = await activeRequest!.close();
      final buffer = BytesBuilder(copy: false);
      var byteCount = 0;
      await for (final chunk in response) {
        byteCount += chunk.length;
        if (byteCount > maxResponseBytes) {
          throw const AnalysisException(
            AnalysisFailureKind.protocol,
            'API 响应超过允许大小',
          );
        }
        buffer.add(chunk);
      }

      final responseText = utf8.decode(buffer.takeBytes());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final providerMessage = _providerMessage(responseText);
        throw AnalysisException(
          AnalysisFailureKind.http,
          providerMessage.isEmpty
              ? 'API 返回错误状态'
              : 'API 返回错误状态: $providerMessage',
          retryable: _isRetryableStatus(response.statusCode),
          statusCode: response.statusCode,
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(responseText);
      } on FormatException catch (error) {
        throw AnalysisException(
          AnalysisFailureKind.protocol,
          'API 响应不是合法 JSON',
          cause: error,
        );
      }

      if (decoded is! Map<String, Object?>) {
        throw const AnalysisException(
          AnalysisFailureKind.protocol,
          'API 响应 JSON 根节点必须是对象',
        );
      }
      return decoded;
    }

    try {
      return await send().timeout(timeout);
    } on AnalysisException {
      rethrow;
    } on TimeoutException catch (error) {
      activeRequest?.abort(error);
      throw AnalysisException(
        AnalysisFailureKind.timeout,
        'API 请求超时',
        retryable: true,
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.network,
        'TLS 握手失败',
        retryable: true,
        cause: error,
      );
    } on SocketException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.network,
        '无法连接分析服务',
        retryable: true,
        cause: error,
      );
    } on HttpException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.network,
        'HTTP 传输失败',
        retryable: true,
        cause: error,
      );
    } on FormatException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.protocol,
        'API 响应编码无效',
        cause: error,
      );
    } on IOException catch (error) {
      throw AnalysisException(
        AnalysisFailureKind.io,
        'API 数据读写失败',
        retryable: true,
        cause: error,
      );
    }
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close(force: true);
    }
  }

  static bool _isRetryableStatus(int statusCode) =>
      statusCode == HttpStatus.requestTimeout ||
      statusCode == 425 ||
      statusCode == HttpStatus.tooManyRequests ||
      statusCode >= 500;

  static String _providerMessage(String responseText) {
    if (responseText.trim().isEmpty) {
      return '';
    }

    try {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, Object?>) {
        final error = decoded['error'];
        if (error is Map<String, Object?> && error['message'] is String) {
          return _truncate(error['message']! as String);
        }
        if (error is String) {
          return _truncate(error);
        }
        if (decoded['message'] is String) {
          return _truncate(decoded['message']! as String);
        }
      }
    } on FormatException {
      // The status code remains the authoritative failure signal.
    }
    return '';
  }

  static String _truncate(String value) {
    final clean = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    return clean.length <= 300 ? clean : '${clean.substring(0, 300)}...';
  }
}
