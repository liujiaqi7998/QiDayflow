enum AnalysisFailureKind {
  configuration,
  input,
  io,
  timeout,
  network,
  http,
  protocol,
  invalidJson,
  validation,
}

final class AnalysisException implements Exception {
  const AnalysisException(
    this.kind,
    this.message, {
    this.retryable = false,
    this.statusCode,
    this.cause,
  });

  final AnalysisFailureKind kind;
  final String message;
  final bool retryable;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'AnalysisException.${kind.name}$status: $message';
  }
}
