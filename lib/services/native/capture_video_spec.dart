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
  num fps = captureFramesPerSecond,
  int durationSeconds = captureChunkDurationSeconds,
}) {
  if (!fps.isFinite || fps <= 0 || durationSeconds <= 0) {
    throw ArgumentError('FPS 和切片时长必须为正数');
  }
  return (fps * durationSeconds).round();
}

bool hasReachedRegularChunkBoundary(
  int frameCount, {
  num fps = captureFramesPerSecond,
  int durationSeconds = captureChunkDurationSeconds,
}) {
  if (frameCount < 0) {
    throw ArgumentError.value(frameCount, 'frameCount', '不能为负数');
  }
  return frameCount >=
      calculateRegularChunkFrameCount(
        fps: fps,
        durationSeconds: durationSeconds,
      );
}

int _divideRounded(int numerator, int denominator) =>
    (numerator + denominator ~/ 2) ~/ denominator;

int _boundedDimension(int value, int maximum) {
  if (value < 1) return 1;
  if (value > maximum) return maximum;
  return value;
}
