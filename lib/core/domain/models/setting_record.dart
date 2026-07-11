import '../validation.dart';

final class SettingRecord {
  SettingRecord({
    required String key,
    required this.value,
    required this.updatedAtMs,
  }) : key = requireNonBlank(key, 'key') {
    if (updatedAtMs < 0) {
      throw ArgumentError.value(updatedAtMs, 'updatedAtMs');
    }
  }

  final String key;
  final String value;
  final int updatedAtMs;
}
