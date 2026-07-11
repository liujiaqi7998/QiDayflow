import 'package:flutter/material.dart';

class QiDayFlowTheme {
  static ThemeData light() => _build(
    brightness: Brightness.light,
    scheme: const ColorScheme.light(
      primary: Color(0xFF176B5B),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFD2EEE6),
      onPrimaryContainer: Color(0xFF0B493D),
      secondary: Color(0xFFB55B26),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFF5DDCF),
      onSecondaryContainer: Color(0xFF4E2714),
      tertiary: Color(0xFF536A8A),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFDCE6F7),
      onTertiaryContainer: Color(0xFF24374F),
      error: Color(0xFFB3261E),
      onError: Colors.white,
      errorContainer: Color(0xFFFFDAD6),
      onErrorContainer: Color(0xFF6F0005),
      surface: Color(0xFFF8F9F7),
      onSurface: Color(0xFF202321),
      onSurfaceVariant: Color(0xFF555B57),
      outline: Color(0xFF737873),
      outlineVariant: Color(0xFFD9DEDA),
    ),
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    scheme: const ColorScheme.dark(
      primary: Color(0xFF77D4BF),
      onPrimary: Color(0xFF00382E),
      primaryContainer: Color(0xFF145A4C),
      onPrimaryContainer: Color(0xFFB1F0DF),
      secondary: Color(0xFFFFB68A),
      onSecondary: Color(0xFF542100),
      secondaryContainer: Color(0xFF753613),
      onSecondaryContainer: Color(0xFFFFDBCA),
      tertiary: Color(0xFFB9CAE8),
      onTertiary: Color(0xFF263A55),
      tertiaryContainer: Color(0xFF3D506D),
      onTertiaryContainer: Color(0xFFD9E5FA),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: Color(0xFFFFDAD6),
      surface: Color(0xFF171A18),
      onSurface: Color(0xFFE1E4E1),
      onSurfaceVariant: Color(0xFFBFC8C2),
      outline: Color(0xFF8C938E),
      outlineVariant: Color(0xFF3F4945),
    ),
  );

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
  }) {
    final isDark = brightness == Brightness.dark;
    final textTheme = _zeroLetterSpacing(
      ThemeData(brightness: brightness).textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
        fontFamily: 'Segoe UI',
      ),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF111412)
          : const Color(0xFFF2F4F2),
      textTheme: textTheme.copyWith(
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        labelLarge: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF202522) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minimumSize: const Size(44, 40),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minimumSize: const Size(44, 40),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF343A36) : const Color(0xFF2E3330),
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}

TextTheme _zeroLetterSpacing(TextTheme source) {
  TextStyle? zero(TextStyle? style) => style?.copyWith(letterSpacing: 0);
  return source.copyWith(
    displayLarge: zero(source.displayLarge),
    displayMedium: zero(source.displayMedium),
    displaySmall: zero(source.displaySmall),
    headlineLarge: zero(source.headlineLarge),
    headlineMedium: zero(source.headlineMedium),
    headlineSmall: zero(source.headlineSmall),
    titleLarge: zero(source.titleLarge),
    titleMedium: zero(source.titleMedium),
    titleSmall: zero(source.titleSmall),
    bodyLarge: zero(source.bodyLarge),
    bodyMedium: zero(source.bodyMedium),
    bodySmall: zero(source.bodySmall),
    labelLarge: zero(source.labelLarge),
    labelMedium: zero(source.labelMedium),
    labelSmall: zero(source.labelSmall),
  );
}

Color categoryColor(String category, Brightness brightness) {
  final color = switch (category) {
    '编程' => const Color(0xFF16856D),
    '工作' => const Color(0xFF3E6DA8),
    '学习' => const Color(0xFF7A5AA6),
    '会议' => const Color(0xFFC17A18),
    '社交' => const Color(0xFFC04D79),
    '娱乐' => const Color(0xFFC64D45),
    '休息' => const Color(0xFF68756E),
    _ => const Color(0xFF607D8B),
  };
  if (brightness == Brightness.light) {
    return color;
  }
  return Color.lerp(color, Colors.white, 0.25) ?? color;
}
