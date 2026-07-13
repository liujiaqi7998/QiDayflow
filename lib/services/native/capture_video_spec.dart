const String activeWindowDisplayCaptureScope = 'active-window-display';
const int captureVideoWidth = 1920;
const int captureVideoHeight = 1080;
const int captureFramesPerSecond = 1;
const int captureChunkDurationSeconds = 60;

final class CaptureContentLayout {
  const CaptureContentLayout({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;
}

CaptureContentLayout calculateCaptureContentLayout({
  required int sourceWidth,
  required int sourceHeight,
  int canvasWidth = captureVideoWidth,
  int canvasHeight = captureVideoHeight,
}) {
  if (sourceWidth <= 0 ||
      sourceHeight <= 0 ||
      canvasWidth <= 0 ||
      canvasHeight <= 0) {
    throw ArgumentError('源画面和画布尺寸必须为正数');
  }

  late final int width;
  late final int height;
  if (sourceWidth * canvasHeight >= sourceHeight * canvasWidth) {
    width = canvasWidth;
    height = _boundedDimension(
      _divideRounded(sourceHeight * canvasWidth, sourceWidth),
      canvasHeight,
    );
  } else {
    height = canvasHeight;
    width = _boundedDimension(
      _divideRounded(sourceWidth * canvasHeight, sourceHeight),
      canvasWidth,
    );
  }
  return CaptureContentLayout(
    left: (canvasWidth - width) ~/ 2,
    top: (canvasHeight - height) ~/ 2,
    width: width,
    height: height,
  );
}

int calculateRegularChunkFrameCount({
  int captureIntervalSeconds = 1,
  int durationSeconds = captureChunkDurationSeconds,
}) {
  if (!_isSupportedCaptureInterval(captureIntervalSeconds) ||
      durationSeconds <= 0) {
    throw ArgumentError('截图间隔必须为 1、10、20 或 30 秒，切片时长必须为正数');
  }
  return (durationSeconds + captureIntervalSeconds - 1) ~/
      captureIntervalSeconds;
}

bool hasReachedRegularChunkBoundary({
  required int elapsedMilliseconds,
  int durationSeconds = captureChunkDurationSeconds,
}) {
  if (elapsedMilliseconds < 0 || durationSeconds <= 0) {
    throw ArgumentError('单调时钟时长不能为负数，切片时长必须为正数');
  }
  return elapsedMilliseconds >= durationSeconds * 1000;
}

bool _isSupportedCaptureInterval(int value) =>
    value == 1 || value == 10 || value == 20 || value == 30;

int _divideRounded(int numerator, int denominator) =>
    (numerator + denominator ~/ 2) ~/ denominator;

int _boundedDimension(int value, int maximum) {
  if (value < 1) return 1;
  if (value > maximum) return maximum;
  return value;
}
