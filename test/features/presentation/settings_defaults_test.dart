import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';

void main() {
  test('settings presentation models default to a ten second interval', () {
    const draft = SettingsDraft(
      apiUrl: 'https://api.openai.com/v1',
      apiKey: '',
      model: 'model',
      userDataDirectory: r'C:\QiDayFlow',
      cacheLimitGb: 5,
      idlePauseEnabled: true,
      idleTimeoutMinutes: 10,
      themeMode: ThemeMode.system,
    );
    const viewData = SettingsViewData(
      apiUrl: 'https://api.openai.com/v1',
      hasApiKey: false,
      model: 'model',
      userDataDirectory: r'C:\QiDayFlow',
      activeUserDataDirectory: r'C:\QiDayFlow',
      dataDirectoryRestartRequired: false,
      cacheLimitGb: 5,
      idlePauseEnabled: true,
      idleTimeoutMinutes: 10,
      themeMode: ThemeMode.system,
      logLevel: AppLogLevel.info,
    );

    expect(draft.captureIntervalSeconds, 10);
    expect(viewData.captureIntervalSeconds, 10);
    expect(draft.autoStartRecording, isFalse);
    expect(draft.launchAtLogin, isFalse);
    expect(viewData.autoStartRecording, isFalse);
    expect(viewData.launchAtLogin, isFalse);
    expect(draft.analysisRetryCount, 3);
    expect(viewData.analysisRetryCount, 3);
  });
}
