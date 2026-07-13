import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/features/presentation/app_theme.dart';

void main() {
  test('light and dark themes use the bundled MiSans family', () {
    expect(QiDayFlowTheme.light().textTheme.bodyMedium?.fontFamily, 'MiSans');
    expect(QiDayFlowTheme.dark().textTheme.bodyMedium?.fontFamily, 'MiSans');
  });

  test('pubspec declares the MiSans font asset', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains('family: MiSans'));
    expect(pubspec, contains('asset: fonts/MiSans-Regular.ttf'));
  });
}
