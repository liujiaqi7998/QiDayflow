import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';

void main() {
  test('accepts HTTPS and all supported HTTP loopback hosts', () {
    for (final value in <String>[
      'https://api.example.com/v1',
      'http://localhost:8080/v1',
      'http://127.0.0.1:8080/v1',
      'http://[::1]:8080/v1',
    ]) {
      expect(validateApiBaseUrl(value), isNull, reason: value);
    }
  });

  test('rejects remote HTTP, user info, query, and fragment consistently', () {
    final cases = <String, String>{
      'http://api.example.com/v1': '远程服务必须使用 HTTPS',
      'https://user:secret@api.example.com/v1': '不能包含用户信息',
      'https://api.example.com/v1?key=value': '不能包含查询参数',
      'https://api.example.com/v1#section': '不能包含片段',
    };
    for (final entry in cases.entries) {
      expect(
        validateApiBaseUrl(entry.key),
        contains(entry.value),
        reason: entry.key,
      );
    }
  });
}
