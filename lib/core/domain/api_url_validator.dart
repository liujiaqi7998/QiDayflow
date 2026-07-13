String? validateApiBaseUrl(String? value) {
  if (value == null || value.trim().isEmpty) return '请输入 API URL';
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return 'API URL 无效';
  if (uri.userInfo.isNotEmpty) return 'API URL 不能包含用户信息';
  if (uri.hasQuery) return 'API URL 不能包含查询参数';
  if (uri.hasFragment) return 'API URL 不能包含片段';

  final isLoopback = const <String>{
    'localhost',
    '127.0.0.1',
    '::1',
  }.contains(uri.host.toLowerCase());
  if (uri.scheme == 'http' && !isLoopback) {
    return '远程服务必须使用 HTTPS；仅 localhost、127.0.0.1、::1 可使用 HTTP';
  }
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    return 'API URL 必须使用 HTTPS；仅本机回环地址可使用 HTTP';
  }
  return null;
}
