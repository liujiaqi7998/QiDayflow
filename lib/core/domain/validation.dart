final RegExp _reportDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String requireNonBlank(String value, String fieldName) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, fieldName, 'must not be blank');
  }
  return trimmed;
}

void requireEpochRange({
  required int startedAtMs,
  required int endedAtMs,
  String startField = 'startedAtMs',
  String endField = 'endedAtMs',
}) {
  if (startedAtMs < 0) {
    throw ArgumentError.value(startedAtMs, startField, 'must be non-negative');
  }
  if (endedAtMs <= startedAtMs) {
    throw ArgumentError.value(
      endedAtMs,
      endField,
      'must be later than $startField',
    );
  }
}

String requireReportDate(String value) {
  if (!_reportDatePattern.hasMatch(value)) {
    throw ArgumentError.value(value, 'reportDate', 'must use YYYY-MM-DD');
  }
  final parts = value.split('-').map(int.parse).toList(growable: false);
  final parsed = DateTime.utc(parts[0], parts[1], parts[2]);
  if (parsed.year != parts[0] ||
      parsed.month != parts[1] ||
      parsed.day != parts[2]) {
    throw ArgumentError.value(value, 'reportDate', 'is not a valid date');
  }
  return value;
}

double requireScore(double value, String fieldName, {double max = 100}) {
  if (!value.isFinite || value < 0 || value > max) {
    throw ArgumentError.value(value, fieldName, 'must be between 0 and $max');
  }
  return value;
}

Map<String, Object?> strictJsonObject(
  Object? value,
  String path, {
  required Set<String> allowedKeys,
}) {
  if (value is! Map) {
    throw FormatException('$path 必须是 JSON 对象');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path 的键必须是字符串');
    }
    final key = entry.key! as String;
    if (!allowedKeys.contains(key)) {
      throw FormatException('$path 包含未知字段: $key');
    }
    result[key] = entry.value;
  }
  return result;
}

String jsonString(
  Map<String, Object?> json,
  String key, {
  bool allowEmpty = false,
}) {
  if (!json.containsKey(key) || json[key] is! String) {
    throw FormatException('$key 必须是字符串');
  }
  final value = (json[key]! as String).trim();
  if (!allowEmpty && value.isEmpty) {
    throw FormatException('$key 不能为空');
  }
  return value;
}

String? jsonOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$key 必须是字符串或 null');
  }
  final result = value.trim();
  return result.isEmpty ? null : result;
}

int jsonInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value is bool) {
    throw FormatException('$key 必须是整数');
  }
  return value;
}

double jsonDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value is bool || !value.isFinite) {
    throw FormatException('$key 必须是有限数字');
  }
  return value.toDouble();
}

bool jsonBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$key 必须是布尔值');
  }
  return value;
}

List<Object?> jsonList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$key 必须是数组');
  }
  return List<Object?>.from(value);
}

DateTime jsonIsoTime(Map<String, Object?> json, String key) {
  final value = jsonString(json, key);
  try {
    return DateTime.parse(value);
  } on FormatException {
    throw FormatException('$key 必须是 ISO 8601 时间');
  }
}
