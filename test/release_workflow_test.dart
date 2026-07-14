import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release workflow uses native PowerShell quoting for dart defines', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, isNot(contains(r'\"--dart-define')));
    expect(
      workflow,
      contains('"--dart-define=QI_DAY_FLOW_BUILD_TIME=\$buildTime"'),
    );
    expect(
      workflow,
      contains(
        '"--dart-define=QI_DAY_FLOW_BUILD_TAG=\$env:QI_DAY_FLOW_BUILD_TAG"',
      ),
    );
  });
}
