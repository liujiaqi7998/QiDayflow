import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

abstract interface class UpdateCheckTransport {
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  });

  void close();
}

final class UpdateHttpResponse {
  const UpdateHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

final class HttpUpdateCheckTransport implements UpdateCheckTransport {
  HttpUpdateCheckTransport([http.Client? client])
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  @override
  Future<UpdateHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abort.future,
    )..headers.addAll(headers);
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(
          timeout,
          onTimeout: () {
            if (!abort.isCompleted) abort.complete();
            throw TimeoutException('Update check request timed out', timeout);
          },
        );
    return UpdateHttpResponse(
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }
}

final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.checkedAt,
    this.latestVersion,
    this.releaseName,
    this.releaseUrl,
    this.updateAvailable = false,
    this.error,
  });

  final String currentVersion;
  final String? latestVersion;
  final String? releaseName;
  final Uri? releaseUrl;
  final bool updateAvailable;
  final DateTime checkedAt;
  final String? error;
}

final class UpdateBuildMetadata {
  const UpdateBuildMetadata({required this.buildTime, required this.buildTag});

  final DateTime buildTime;
  final String buildTag;

  static UpdateBuildMetadata? tryParse({
    required String buildTimeValue,
    required String buildTagValue,
  }) {
    final buildTime = DateTime.tryParse(buildTimeValue.trim());
    final buildTag = buildTagValue.trim();
    if (buildTime == null || buildTag.isEmpty) return null;
    return UpdateBuildMetadata(
      buildTime: buildTime.toUtc(),
      buildTag: buildTag,
    );
  }
}

final class UpdateCheckService {
  UpdateCheckService({
    required this.currentVersion,
    required DateTime currentBuildTime,
    this.currentBuildTag = '',
    UpdateCheckTransport? transport,
    DateTime Function()? now,
  }) : currentBuildTime = currentBuildTime.toUtc(),
       _transport = transport ?? HttpUpdateCheckTransport(),
       _now = now ?? DateTime.now;

  static final Uri latestReleaseApiUri = Uri.parse(
    'https://api.github.com/repos/liujiaqi7998/QiDayflow/releases/latest',
  );
  static final Uri releasesPageUri = Uri.parse(
    'https://github.com/liujiaqi7998/QiDayflow/releases',
  );
  static const Duration requestTimeout = Duration(seconds: 5);

  final String currentVersion;
  final DateTime currentBuildTime;
  final String currentBuildTag;
  final UpdateCheckTransport _transport;
  final DateTime Function() _now;

  Future<UpdateCheckResult> check() async {
    final checkedAt = _now();
    try {
      final response = await _transport.get(
        latestReleaseApiUri,
        headers: <String, String>{
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'QiDayFlow/${currentVersion.trim()}',
        },
        timeout: requestTimeout,
      );
      if (response.statusCode != 200) {
        return _failure(checkedAt, _httpError(response.statusCode));
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _failure(checkedAt, '版本信息格式无效，请稍后重试');
      }
      final tagValue = decoded['tag_name'];
      final name = decoded['name'];
      final htmlUrlValue = decoded['html_url'];
      final publishedAtValue = decoded['published_at'];
      if (tagValue is! String ||
          tagValue.trim().isEmpty ||
          (name != null && name is! String) ||
          htmlUrlValue is! String ||
          htmlUrlValue.trim().isEmpty ||
          publishedAtValue is! String) {
        return _failure(checkedAt, '版本信息格式无效，请稍后重试');
      }
      final tag = tagValue.trim();
      final releaseUrl = Uri.tryParse(htmlUrlValue.trim());
      final publishedAt = DateTime.tryParse(publishedAtValue.trim());
      if (releaseUrl == null ||
          !releaseUrl.hasScheme ||
          releaseUrl.host.isEmpty ||
          publishedAt == null) {
        return _failure(checkedAt, '版本信息格式无效，请稍后重试');
      }
      final buildTag = currentBuildTag.trim();
      final isSameBuild = buildTag.isNotEmpty && tag == buildTag;
      return UpdateCheckResult(
        currentVersion: currentVersion,
        latestVersion: _displayReleaseTag(tag),
        releaseName: name is String && name.trim().isNotEmpty
            ? name.trim()
            : tag,
        releaseUrl: releaseUrl,
        updateAvailable:
            !isSameBuild && publishedAt.toUtc().isAfter(currentBuildTime),
        checkedAt: checkedAt,
      );
    } on TimeoutException {
      return _failure(checkedAt, '检查更新超时，请检查网络后重试');
    } on FormatException {
      return _failure(checkedAt, '版本信息格式无效，请稍后重试');
    } on Object {
      return _failure(checkedAt, '检查更新失败，请检查网络后重试');
    }
  }

  UpdateCheckResult _failure(DateTime checkedAt, String error) =>
      UpdateCheckResult(
        currentVersion: currentVersion,
        checkedAt: checkedAt,
        error: error,
      );

  String _httpError(int statusCode) {
    if (statusCode == 403 || statusCode == 429) {
      return 'GitHub 请求过于频繁，请稍后重试';
    }
    if (statusCode == 404) return '暂未找到可用的发布版本';
    return '检查更新失败（HTTP $statusCode）';
  }

  void close() => _transport.close();
}

String _displayReleaseTag(String tag) {
  if (tag.length > 1 && tag.startsWith('v') && _startsWithAsciiDigit(tag, 1)) {
    return tag.substring(1);
  }
  return tag;
}

bool _startsWithAsciiDigit(String value, int index) {
  final codeUnit = value.codeUnitAt(index);
  return codeUnit >= 0x30 && codeUnit <= 0x39;
}
