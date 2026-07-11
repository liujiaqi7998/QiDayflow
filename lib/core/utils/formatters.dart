String twoDigits(int value) => value.toString().padLeft(2, '0');

String formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}年${local.month}月${local.day}日';
}

String formatIsoDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
}

String formatClock(DateTime value) {
  final local = value.toLocal();
  return '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 1) {
    return '${duration.inSeconds.clamp(0, 59)} 秒';
  }
  if (minutes < 60) {
    return '$minutes 分钟';
  }
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
}

String formatMinutes(double minutes) {
  return formatDuration(Duration(seconds: (minutes * 60).round()));
}

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(1)} KB';
  }
  final mb = kb / 1024;
  if (mb < 1024) {
    return '${mb.toStringAsFixed(1)} MB';
  }
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

String formatIecBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kibibytes = bytes / 1024;
  if (kibibytes < 1024) {
    return '${kibibytes.toStringAsFixed(1)} KiB';
  }
  final mebibytes = kibibytes / 1024;
  if (mebibytes < 1024) {
    return '${mebibytes.toStringAsFixed(1)} MiB';
  }
  return '${(mebibytes / 1024).toStringAsFixed(1)} GiB';
}
