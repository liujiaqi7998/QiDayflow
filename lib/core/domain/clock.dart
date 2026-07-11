abstract interface class Clock {
  int nowUtcEpochMs();
}

final class SystemClock implements Clock {
  const SystemClock();

  @override
  int nowUtcEpochMs() => DateTime.now().toUtc().millisecondsSinceEpoch;
}
