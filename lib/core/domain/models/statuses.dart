enum CaptureSessionStatus {
  recording,
  paused,
  stopped,
  failed;

  static CaptureSessionStatus fromStorage(String value) {
    return CaptureSessionStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () =>
          throw FormatException('Unknown capture session status: $value'),
    );
  }
}

enum ProcessingStatus {
  pending,
  processing,
  completed,
  failed;

  static ProcessingStatus fromStorage(String value) {
    return ProcessingStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => throw FormatException('Unknown processing status: $value'),
    );
  }
}
