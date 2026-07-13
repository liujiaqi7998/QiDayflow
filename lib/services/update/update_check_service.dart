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

final class UpdateCheckService {
  UpdateCheckService({
    required this.currentVersion,
    UpdateCheckTransport? transport,
    DateTime Function()? now,
  }) : _transport = transport ?? HttpUpdateCheckTransport(),
       _now = now ?? DateTime.now;

  static final Uri latestReleaseApiUri = Uri.parse(
    'https://api.github.com/repos/liujiaqi7998/QiDayflow/releases/latest',
  );
  static final Uri releasesPageUri = Uri.parse(
    'https://github.com/liujiaqi7998/QiDayflow/releases',
  );
  static const Duration requestTimeout = Duration(seconds: 5);

  final String currentVersion;
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
      final tag = decoded['tag_name'];
      final name = decoded['name'];
      final htmlUrl = decoded['html_url'];
      if (tag is! String ||
          (name != null && name is! String) ||
          htmlUrl is! String) {
        return _failure(checkedAt, '版本信息格式无效，请稍后重试');
      }
      final latest = _StableNumericVersion.tryParse(tag);
      final current = _StableNumericVersion.tryParse(currentVersion);
      final releaseUrl = Uri.tryParse(htmlUrl);
      if (latest == null ||
          current == null ||
          releaseUrl == null ||
          !releaseUrl.hasScheme ||
          releaseUrl.host.isEmpty) {
        return _failure(checkedAt, '版本信息格式无效，请稍后重试');
      }
      return UpdateCheckResult(
        currentVersion: currentVersion,
        latestVersion: latest.normalized,
        releaseName: name is String && name.trim().isNotEmpty
            ? name.trim()
            : tag.trim(),
        releaseUrl: releaseUrl,
        updateAvailable: latest.compareTo(current) > 0,
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

bool isNewerStableVersion({required String current, required String latest}) {
  final currentVersion = _StableNumericVersion.tryParse(current);
  final latestVersion = _StableNumericVersion.tryParse(latest);
  if (currentVersion == null || latestVersion == null) return false;
  return latestVersion.compareTo(currentVersion) > 0;
}

final class _StableNumericVersion implements Comparable<_StableNumericVersion> {
  const _StableNumericVersion(this.major, this.minor, this.patch);

  static final RegExp _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  final int major;
  final int minor;
  final int patch;

  String get normalized => '$major.$minor.$patch';

  static _StableNumericVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    return _StableNumericVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3) ?? '0'),
    );
  }

  @override
  int compareTo(_StableNumericVersion other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) return majorComparison;
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;
    return patch.compareTo(other.patch);
  }
}
