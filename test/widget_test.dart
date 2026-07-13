import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show SemanticsAction, SemanticsActionEvent;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/app.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/features/presentation/app_theme.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/features/presentation/pages/settings_page.dart';

void main() {
  testWidgets('renders and navigates the real application shell', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel();

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    expect(find.text('Qi Day Flow'), findsOneWidget);
    expect(find.text('时间轴'), findsWidgets);
    expect(find.text('日报'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('模型服务'), findsOneWidget);
    expect(find.text('采集'), findsOneWidget);
    expect(find.text('用户数据目录'), findsOneWidget);
    expect(find.textContaining(r'C:\QiDayFlow\captures'), findsOneWidget);
    expect(find.text('采集范围'), findsNothing);
    expect(find.text('采样频率'), findsNothing);
    expect(find.text('视频质量'), findsNothing);
    expect(find.text('AI 分析'), findsNothing);
    expect(find.text('高清视频：最高 3840×2160'), findsNothing);
    expect(find.text('AI 高精度抽帧'), findsNothing);
    final apiKeyField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('settings-api-key')),
        matching: find.byType(EditableText),
      ),
    );
    expect(apiKeyField.controller.text, 'test-only-key');
    expect(apiKeyField.obscureText, isTrue);

    await tester.tap(find.byTooltip('显示密钥'));
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('settings-api-key')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText,
      isFalse,
    );

    expect(find.text('分析完成后继续保留，达到上限后优先删除最旧的已分析视频和 JSON'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('本地数据'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    expect(find.text('本地数据'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-save')), findsNothing);
    expect(viewModel.savedSettings, isEmpty);
    expect(apiKeyField.controller.text, 'test-only-key');
  });

  testWidgets('analysis queue navigation opens an independent page', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel();

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    final navigation = find.byKey(const Key('nav-analysis-queue'));
    expect(navigation, findsOneWidget);
    expect(
      find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.pending_actions_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(navigation);
    await tester.pumpAndSettle();

    expect(viewModel.section, AppSection.analysisQueue);
    expect(find.byKey(const ValueKey('analysis-queue-page')), findsOneWidget);
    expect(find.text('分析队列'), findsWidgets);
    expect(
      find.byKey(const ValueKey('analysis-queue-refresh')),
      findsOneWidget,
    );
  });

  testWidgets('analysis queue renders three states and safe task details', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..section = AppSection.analysisQueue
      ..analysisQueue = _threeStateQueue();

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analysis-queue-count-processing')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analysis-queue-count-pending')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analysis-queue-count-failed')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    final processing = find.byKey(
      const ValueKey('analysis-queue-item-chunk-1'),
    );
    final pending = find.byKey(const ValueKey('analysis-queue-item-chunk-2'));
    final failed = find.byKey(const ValueKey('analysis-queue-item-chunk-3'));
    expect(processing, findsOneWidget);
    expect(pending, findsOneWidget);
    expect(failed, findsOneWidget);
    expect(
      find.descendant(of: processing, matching: find.text('正在分析')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pending, matching: find.text('等待分析')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: failed, matching: find.text('分析失败')),
      findsOneWidget,
    );
    expect(find.text('批次 #7 · 切片 #1'), findsOneWidget);
    expect(find.text('切片 #2'), findsOneWidget);
    expect(find.text('批次 #9 · 切片 #3'), findsOneWidget);
    expect(
      find.descendant(of: processing, matching: find.text('录制 09:00 - 09:01')),
      findsOneWidget,
    );
    expect(find.text('时长 1 分钟'), findsWidgets);
    expect(
      find.descendant(
        of: processing,
        matching: find.text('入队 2026-07-11 08:59'),
      ),
      findsOneWidget,
    );
    expect(find.text('重试 2 次'), findsOneWidget);
    expect(find.textContaining('已分析'), findsOneWidget);
    expect(find.text('网络连接失败'), findsOneWidget);
    expect(find.textContaining('sk-secret'), findsNothing);
    expect(find.textContaining('Authorization'), findsNothing);
    expect(find.textContaining(r'C:\private\chunk.mp4'), findsNothing);
    expect(
      find.byKey(const ValueKey('analysis-queue-retry-failed')),
      findsOneWidget,
    );
  });

  testWidgets('analysis queue empty state follows view-model updates', (
    WidgetTester tester,
  ) async {
    final viewModel = _TestViewModel()..section = AppSection.analysisQueue;
    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    expect(find.byKey(const ValueKey('analysis-queue-empty')), findsOneWidget);
    expect(find.text('分析队列为空'), findsOneWidget);

    viewModel.analysisQueue = AnalysisQueueViewData(
      items: <AnalysisQueueItemViewData>[
        _queueItem(chunkId: 8, status: ProcessingStatus.pending),
      ],
    );
    viewModel.notifyListeners();
    await tester.pump();

    expect(find.byKey(const ValueKey('analysis-queue-empty')), findsNothing);
    expect(
      find.byKey(const ValueKey('analysis-queue-item-chunk-8')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analysis-queue-count-pending')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('analysis queue remains usable in a narrow window', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..section = AppSection.analysisQueue
      ..analysisQueue = _threeStateQueue();

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('analysis-queue-item-chunk-3')),
      find.byKey(const ValueKey('analysis-queue-list')),
      const Offset(0, -300),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analysis-queue-item-chunk-3')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('analysis queue refresh and retry ignore duplicate clicks', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final refreshGate = Completer<void>();
    final retryGate = Completer<void>();
    final viewModel = _TestViewModel()
      ..section = AppSection.analysisQueue
      ..analysisQueue = _threeStateQueue()
      ..refreshGate = refreshGate
      ..retryGate = retryGate;

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    final refresh = find.byKey(const ValueKey('analysis-queue-refresh'));
    await tester.tap(refresh);
    await tester.pump();
    expect(viewModel.analysisQueueRefreshCalls, 1);
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    await tester.tap(refresh);
    await tester.pump();
    expect(viewModel.analysisQueueRefreshCalls, 1);
    refreshGate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

    final retry = find.byKey(const ValueKey('analysis-queue-retry-failed'));
    await tester.tap(retry);
    await tester.pump();
    expect(viewModel.retryFailedCalls, 1);
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);
    await tester.tap(retry);
    await tester.pump();
    expect(viewModel.retryFailedCalls, 1);
    retryGate.complete();
    await tester.pumpAndSettle();
    expect(viewModel.analysisQueueRefreshCalls, 2);
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
  });

  testWidgets(
    'capture interval is locked while recording and editable after stopping',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      final viewModel = _TestViewModel()
        ..section = AppSection.settings
        ..recordingStatus = RecordingViewStatus.recording;

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.pumpAndSettle();

      final interval = find.byKey(const ValueKey('settings-capture-interval'));
      final lockedSemantics = tester.getSemantics(interval);
      expect(lockedSemantics.label, '截图间隔，当前 10 秒。录制中，设置已锁定');
      expect(lockedSemantics.hasChildren, isFalse);
      expect(find.text('录制期间截图间隔已锁定，停止录制后可更改。'), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<int>>(
              find.descendant(
                of: interval,
                matching: find.byType(SegmentedButton<int>),
              ),
            )
            .onSelectionChanged,
        isNull,
      );

      await tester.tap(find.text('20 秒'));
      await tester.pump();
      expect(viewModel.savedSettings, isEmpty);

      viewModel.recordingStatus = RecordingViewStatus.paused;
      viewModel.notifyListeners();
      await tester.pump();
      expect(tester.getSemantics(interval).label, '截图间隔，当前 10 秒。已暂停，设置已锁定');

      viewModel.recordingStatus = RecordingViewStatus.stopped;
      viewModel.notifyListeners();
      await tester.pump();

      expect(
        tester
            .widget<SegmentedButton<int>>(
              find.descendant(
                of: interval,
                matching: find.byType(SegmentedButton<int>),
              ),
            )
            .onSelectionChanged,
        isNotNull,
      );
      await tester.tap(find.text('20 秒'));
      await tester.pumpAndSettle();
      expect(viewModel.savedSettings, hasLength(1));
      expect(viewModel.savedSettings.single.captureIntervalSeconds, 20);
      semantics.dispose();
    },
  );

  for (final status in <RecordingViewStatus>[
    RecordingViewStatus.starting,
    RecordingViewStatus.recording,
    RecordingViewStatus.paused,
    RecordingViewStatus.stopping,
  ]) {
    testWidgets('capture interval is disabled while status is ${status.name}', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()
        ..section = AppSection.settings
        ..recordingStatus = status;

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.pump();

      final interval = find.byKey(const ValueKey('settings-capture-interval'));
      final selector = tester.widget<SegmentedButton<int>>(
        find.descendant(
          of: interval,
          matching: find.byType(SegmentedButton<int>),
        ),
      );
      expect(selector.onSelectionChanged, isNull);
    });
  }

  for (final status in <RecordingViewStatus>[
    RecordingViewStatus.stopped,
    RecordingViewStatus.error,
  ]) {
    testWidgets('capture interval is enabled while status is ${status.name}', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()
        ..section = AppSection.settings
        ..recordingStatus = status;

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.pump();

      final interval = find.byKey(const ValueKey('settings-capture-interval'));
      final selector = tester.widget<SegmentedButton<int>>(
        find.descendant(
          of: interval,
          matching: find.byType(SegmentedButton<int>),
        ),
      );
      expect(selector.onSelectionChanged, isNotNull);
    });
  }

  testWidgets('narrow capture interval dropdown is disabled while recording', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..section = AppSection.settings
      ..recordingStatus = RecordingViewStatus.paused;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(viewModel: viewModel)),
      ),
    );
    await tester.pumpAndSettle();

    final interval = find.byKey(const ValueKey('settings-capture-interval'));
    final dropdown = tester.widget<DropdownButtonFormField<int>>(
      find.descendant(
        of: interval,
        matching: find.byType(DropdownButtonFormField<int>),
      ),
    );
    expect(dropdown.onChanged, isNull);
    expect(find.text('录制期间截图间隔已锁定，停止录制后可更改。'), findsOneWidget);
    expect(viewModel.savedSettings, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('user data directory can be opened while recording', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()..section = AppSection.settings;

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('settings-user-data-directory')),
      r'  C:\Current QiDayFlow  ',
    );
    viewModel.recordingStatus = RecordingViewStatus.recording;
    viewModel.notifyListeners();
    await tester.pump();

    final openButton = find.byKey(
      const ValueKey('settings-open-user-data-directory'),
    );
    expect(openButton, findsOneWidget);
    expect(find.byTooltip('在资源管理器中打开用户数据目录'), findsOneWidget);
    expect(tester.widget<IconButton>(openButton).onPressed, isNotNull);

    await tester.tap(openButton);
    await tester.pumpAndSettle();
    expect(viewModel.openedUserDataDirectories, <String>[
      r'C:\Current QiDayFlow',
    ]);
  });

  testWidgets('user data directory open failure shows a closable snackbar', (
    WidgetTester tester,
  ) async {
    final viewModel = _TestViewModel()
      ..section = AppSection.settings
      ..openUserDataDirectoryError = StateError('Explorer unavailable');

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-open-user-data-directory')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('打开用户数据目录失败'), findsOneWidget);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).showCloseIcon,
      isTrue,
    );
  });

  testWidgets(
    'clear cached videos confirms, cancels safely, and works when narrow',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()..section = AppSection.settings;
      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.pumpAndSettle();

      final clearButton = find.byKey(
        const ValueKey('settings-clear-cached-videos'),
      );
      for (
        var attempt = 0;
        attempt < 10 && clearButton.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(clearButton, findsOneWidget);
      await tester.ensureVisible(clearButton);
      await tester.pumpAndSettle();
      await tester.tap(clearButton);
      await tester.pumpAndSettle();
      expect(find.text('确认清除缓存视频？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(viewModel.clearCachedVideoCalls, 0);

      await tester.tap(clearButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清除'));
      await tester.pumpAndSettle();
      expect(viewModel.clearCachedVideoCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('log level selector applies changes immediately', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()..section = AppSection.settings;
    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    final selector = find.byKey(const ValueKey('settings-log-level'));
    for (
      var attempt = 0;
      attempt < 8 && selector.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(selector, findsOneWidget);
    await tester.ensureVisible(selector);
    await tester.pumpAndSettle();
    expect(find.text('INFO'), findsOneWidget);
    expect(find.text('WARNING'), findsOneWidget);
    expect(find.text('ERROR'), findsOneWidget);
    await tester.tap(find.text('DEBUG'));
    await tester.pumpAndSettle();
    expect(viewModel.logLevelUpdates, <AppLogLevel>[AppLogLevel.debug]);
  });

  testWidgets(
    'managed log size and confirmed clear remain usable when narrow',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()
        ..section = AppSection.settings
        ..managedLogBytes = 1536;
      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.pumpAndSettle();

      final clearButton = find.byKey(
        const ValueKey('settings-clear-managed-logs'),
      );
      for (
        var attempt = 0;
        attempt < 10 && clearButton.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, -250));
        await tester.pumpAndSettle();
      }
      expect(clearButton, findsOneWidget);
      expect(find.text('1.5 KB'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.dragUntilVisible(
        clearButton,
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(clearButton);
      await tester.pumpAndSettle();
      expect(find.text('确认清理日志？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(viewModel.clearManagedLogCalls, 0);

      await tester.tap(clearButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清理'));
      await tester.pumpAndSettle();
      expect(viewModel.clearManagedLogCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('managed log failure is visible without reporting success', (
    WidgetTester tester,
  ) async {
    final viewModel = _TestViewModel()
      ..section = AppSection.settings
      ..managedLogBytes = 4096
      ..managedLogError = '1 个日志文件清理失败，未删除的受管理日志已保留';
    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    final errorText = find.text(viewModel.managedLogError!);
    for (
      var attempt = 0;
      attempt < 8 && errorText.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(errorText, findsOneWidget);
    expect(find.text('日志已清理'), findsNothing);
  });

  testWidgets(
    'settings text debounces, switches save now, and dispose flushes',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()..section = AppSection.settings;
      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-save')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('settings-model')),
        'debounced-model',
      );
      await tester.pump(const Duration(milliseconds: 499));
      expect(viewModel.savedSettings, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(viewModel.savedSettings, hasLength(1));
      expect(viewModel.savedSettings.single.model, 'debounced-model');
      expect(viewModel.savedSettings.single.apiKeyChanged, isFalse);

      final idleSwitch = find.widgetWithText(SwitchListTile, '空闲自动暂停');
      await tester.ensureVisible(idleSwitch);
      await tester.tap(idleSwitch);
      await tester.pump();
      expect(viewModel.savedSettings, hasLength(2));

      final modelField = find.byKey(const ValueKey('settings-model'));
      for (
        var attempt = 0;
        attempt < 6 && modelField.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, 300));
        await tester.pumpAndSettle();
      }
      await tester.enterText(modelField, 'flush-on-dispose');
      await tester.pump(const Duration(milliseconds: 100));
      viewModel.selectSection(AppSection.timeline);
      await tester.pump();
      expect(viewModel.savedSettings.last.model, 'flush-on-dispose');
    },
  );

  testWidgets('settings save status exposes saved and error states', (
    WidgetTester tester,
  ) async {
    final viewModel = _TestViewModel()
      ..section = AppSection.settings
      ..settingsSaveStatus = SettingsSaveStatus.saved;
    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.pumpAndSettle();
    expect(find.text('已保存'), findsOneWidget);

    viewModel
      ..settingsSaveStatus = SettingsSaveStatus.error
      ..settingsSaveError = '磁盘写入失败';
    viewModel.notifyListeners();
    await tester.pump();
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.textContaining('磁盘写入失败'), findsOneWidget);
  });

  testWidgets(
    'capture interval selector is accessible and saves exact values',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      try {
        final viewModel = _TestViewModel()..section = AppSection.settings;
        await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
        await tester.pumpAndSettle();

        final selector = find.byKey(
          const ValueKey('settings-capture-interval'),
        );
        expect(selector, findsOneWidget);
        expect(tester.getSemantics(selector).label, '截图间隔，当前 10 秒');
        for (final interval in const <int>[1, 10, 20, 30]) {
          expect(
            find.descendant(of: selector, matching: find.text('$interval 秒')),
            findsOneWidget,
          );
        }
        expect(
          find.text('频率越低，本地视频体积、CPU 和 AI 候选图片越少，但短暂活动可能不被图像捕获。'),
          findsOneWidget,
        );
        expect(find.text('更改将在下次开始录制时生效。'), findsOneWidget);

        await tester.tap(
          find.descendant(of: selector, matching: find.text('30 秒')),
        );
        await tester.pumpAndSettle();

        expect(viewModel.savedSettings, hasLength(1));
        expect(viewModel.savedSettings.single.captureIntervalSeconds, 30);
        expect(tester.getSemantics(selector).label, '截图间隔，当前 30 秒');
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'timeline search filters content and keeps the query across dates',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()
        ..timelineCards = [
          _viewCard(
            id: '1',
            title: '实现统计服务',
            summary: '处理加权效率',
            category: '编程',
            app: 'Visual Studio Code',
            duration: const Duration(hours: 1),
          ),
          _viewCard(
            id: '2',
            title: '阅读文档',
            summary: '查看 API 说明',
            category: '学习',
            app: 'Microsoft Edge',
            duration: const Duration(minutes: 30),
          ),
        ];

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
      await tester.enterText(
        find.byKey(const ValueKey('timeline-search')),
        '  eDgE  ',
      );
      await tester.pump();

      expect(find.text('阅读文档'), findsOneWidget);
      expect(find.text('实现统计服务'), findsNothing);
      expect(find.text('1 项活动 · 30 分钟'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('timeline-search')),
        '不存在',
      );
      await tester.pump();
      expect(find.text('没有匹配的活动'), findsOneWidget);
      expect(find.text('这一天还没有活动'), findsNothing);

      await tester.tap(find.byTooltip('前一天'));
      await tester.pump();
      expect(find.text('没有匹配的活动'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('timeline-search')))
            .controller
            ?.text,
        '不存在',
      );

      await tester.tap(find.byKey(const ValueKey('timeline-search-clear')));
      await tester.pump();
      expect(find.text('实现统计服务'), findsOneWidget);
      expect(find.text('阅读文档'), findsOneWidget);
    },
  );

  testWidgets('timeline sorts deterministically and keeps the selected order', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sharedStart = DateTime.utc(2026, 7, 10, 10);
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: 'a',
          title: '相同结束 A',
          summary: '',
          category: '工作',
          app: 'Editor',
          duration: const Duration(hours: 1),
          startedAt: sharedStart,
        ),
        _viewCard(
          id: 'old',
          title: '较早活动',
          summary: '',
          category: '工作',
          app: 'Editor',
          duration: const Duration(minutes: 20),
          startedAt: sharedStart.subtract(const Duration(hours: 1)),
        ),
        _viewCard(
          id: 'c',
          title: '较晚结束 C',
          summary: '',
          category: '工作',
          app: 'Editor',
          duration: const Duration(hours: 2),
          startedAt: sharedStart,
        ),
        _viewCard(
          id: 'b',
          title: '相同结束 B',
          summary: '',
          category: '工作',
          app: 'Editor',
          duration: const Duration(hours: 1),
          startedAt: sharedStart,
        ),
      ];

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    List<String> visibleCardIds() => find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'timeline-card-',
              ),
        )
        .evaluate()
        .map(
          (element) => ((element.widget.key! as ValueKey<String>).value)
              .replaceFirst('timeline-card-', ''),
        )
        .toList();

    expect(visibleCardIds(), ['c', 'b', 'a', 'old']);
    expect(find.text('最新优先'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline-sort-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最早优先').last);
    await tester.pumpAndSettle();
    expect(visibleCardIds(), ['old', 'a', 'b', 'c']);

    await tester.enterText(
      find.byKey(const ValueKey('timeline-search')),
      '相同结束',
    );
    await tester.pump();
    expect(visibleCardIds(), ['a', 'b']);

    await tester.tap(find.byTooltip('前一天'));
    await tester.pump();
    expect(find.text('最早优先'), findsOneWidget);
    expect(visibleCardIds(), ['a', 'b']);

    viewModel.timelineCards = [
      ...viewModel.timelineCards,
      _viewCard(
        id: 'aa',
        title: '相同结束 AA',
        summary: '',
        category: '工作',
        app: 'Editor',
        duration: const Duration(hours: 1),
        startedAt: sharedStart,
      ),
    ];
    viewModel.notifyListeners();
    await tester.pump();
    expect(visibleCardIds(), ['a', 'aa', 'b']);
    expect(find.text('最早优先'), findsOneWidget);
  });

  testWidgets('timeline sort is one tappable semantic control', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(QiDayFlowApp(viewModel: _TestViewModel()));

      final sort = find.byKey(const ValueKey('timeline-sort'));
      final traversal = tester.semantics.simulatedAccessibilityTraversal();
      expect(
        traversal.where((node) => node.label == '时间轴排序：最新优先'),
        hasLength(1),
      );
      expect(traversal.where((node) => node.label == '最新优先'), isEmpty);

      final sortNode = tester.getSemantics(sort);
      expect(sortNode.label, '时间轴排序：最新优先');
      expect(
        sortNode.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );

      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          viewId: tester.view.viewId,
          nodeId: sortNode.id,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最早优先'), findsOneWidget);

      await tester.tap(find.text('最早优先'));
      await tester.pumpAndSettle();
      final updatedTraversal = tester.semantics
          .simulatedAccessibilityTraversal();
      expect(
        updatedTraversal.where((node) => node.label == '时间轴排序：最早优先'),
        hasLength(1),
      );
      expect(
        tester
            .getSemantics(sort)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('timeline traversal announces each category exactly once', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    try {
      final viewModel = _TestViewModel()
        ..timelineCards = [
          _viewCard(
            id: 'code',
            title: '实现功能',
            summary: '',
            category: '编程',
            app: 'Editor',
            duration: const Duration(hours: 1),
          ),
          _viewCard(
            id: 'meeting',
            title: '同步进度',
            summary: '',
            category: '会议',
            app: 'Meeting',
            duration: const Duration(minutes: 30),
          ),
        ];

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

      final traversal = tester.semantics.simulatedAccessibilityTraversal();
      for (final label in const ['编程，1 小时，占当日 67%', '会议，30 分钟，占当日 33%']) {
        expect(traversal.where((node) => node.label == label), hasLength(1));
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('timeline category legend is touch and keyboard accessible', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: 'code',
          title: '实现功能',
          summary: '',
          category: '编程',
          app: 'Editor',
          duration: const Duration(hours: 1),
        ),
      ];
    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    final item = find.byKey(const ValueKey('timeline-category-item-编程'));
    expect(tester.getSize(item).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(item).height, greaterThanOrEqualTo(48));

    const tooltipLabel = '编程，1 小时，占当日 100%';
    for (
      var tabs = 0;
      tabs < 20 && find.text(tooltipLabel).evaluate().isEmpty;
      tabs++
    ) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(find.text(tooltipLabel), findsOneWidget);

    Tooltip.dismissAllToolTips();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.longPress(item);
    await tester.pump();
    expect(find.text(tooltipLabel), findsOneWidget);
  });

  testWidgets(
    'timeline category distribution aggregates all cards and retains colors',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _TestViewModel()
        ..timelineCards = [
          _viewCard(
            id: 'code-1',
            title: '实现功能',
            summary: '',
            category: '编程',
            app: 'Editor',
            duration: const Duration(hours: 1),
          ),
          _viewCard(
            id: 'study',
            title: '阅读资料',
            summary: '',
            category: '学习',
            app: 'Browser',
            duration: const Duration(minutes: 30),
          ),
          _viewCard(
            id: 'code-2',
            title: '修复问题',
            summary: '',
            category: '编程',
            app: 'Editor',
            duration: const Duration(minutes: 30),
          ),
          _viewCard(
            id: 'meeting',
            title: '同步进度',
            summary: '',
            category: '会议',
            app: 'Meeting',
            duration: const Duration(minutes: 30),
          ),
          _viewCard(
            id: 'zero',
            title: '零时长',
            summary: '',
            category: '工作',
            app: 'Editor',
            duration: Duration.zero,
          ),
        ];

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

      expect(find.text('当日类别分布'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('timeline-category-item-编程')),
        findsOneWidget,
      );
      expect(find.text('1 小时 30 分钟 · 60%'), findsOneWidget);
      expect(find.text('30 分钟 · 20%'), findsNWidgets(2));
      final categoryItemKeys = find
          .byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'timeline-category-item-',
                ),
          )
          .evaluate()
          .map((element) => (element.widget.key! as ValueKey<String>).value)
          .toList();
      expect(categoryItemKeys, [
        'timeline-category-item-编程',
        'timeline-category-item-会议',
        'timeline-category-item-学习',
      ]);
      expect(
        find.byKey(const ValueKey('timeline-category-item-工作')),
        findsNothing,
      );
      expect(
        tester
            .widget<ColoredBox>(
              find.byKey(const ValueKey('timeline-category-segment-编程')),
            )
            .color,
        categoryColor('编程', Brightness.light),
      );

      await tester.enterText(
        find.byKey(const ValueKey('timeline-search')),
        '阅读资料',
      );
      await tester.pump();
      expect(find.text('实现功能'), findsNothing);
      expect(find.text('1 小时 30 分钟 · 60%'), findsOneWidget);
      expect(find.text('30 分钟 · 20%'), findsNWidgets(2));
    },
  );

  testWidgets('timeline distribution excludes zero and negative durations', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime.utc(2026, 7, 10, 8);
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: 'zero',
          title: '零时长',
          summary: '',
          category: '工作',
          app: 'Editor',
          duration: Duration.zero,
          startedAt: start,
        ),
        _viewCard(
          id: 'negative',
          title: '负时长',
          summary: '',
          category: '学习',
          app: 'Editor',
          duration: const Duration(minutes: -1),
          startedAt: start,
        ),
      ];

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    expect(find.text('这一天还没有可统计的活动'), findsOneWidget);
    expect(find.text('最新优先'), findsOneWidget);
    expect(find.textContaining('NaN'), findsNothing);
    expect(find.textContaining('Infinity'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'timeline distribution handles narrow positive data at large text scale',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const categories = [
        '这是一个非常长的类别名称用于验证窄屏布局',
        '会议',
        '学习',
        '设计',
        '写作',
        '沟通',
        '规划',
      ];
      final viewModel = _TestViewModel()
        ..timelineCards = [
          for (var index = 0; index < categories.length; index++)
            _viewCard(
              id: 'category-$index',
              title: '活动 $index',
              summary: '',
              category: categories[index],
              app: 'Editor',
              duration: Duration(minutes: index + 1),
            ),
        ];

      await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

      final legendScroll = find.byKey(
        const ValueKey('timeline-category-scroll'),
      );
      expect(legendScroll, findsOneWidget);
      final scrollable = find.descendant(
        of: legendScroll,
        matching: find.byType(Scrollable),
      );
      final scrollPosition = tester.state<ScrollableState>(scrollable).position;
      expect(scrollPosition.pixels, 0);

      for (final category in categories) {
        expect(
          find.byKey(ValueKey('timeline-category-segment-$category')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('timeline-category-item-$category')),
          findsOneWidget,
        );
      }

      final focusOrder = categories.reversed.toList(growable: false);
      Finder tooltipFor(String category) => find.descendant(
        of: find.byKey(ValueKey('timeline-category-item-$category')),
        matching: find.byType(Tooltip),
      );
      Focus.of(tester.element(tooltipFor(focusOrder.first))).requestFocus();
      await tester.pumpAndSettle();

      for (var index = 0; index < focusOrder.length; index++) {
        final category = focusOrder[index];
        expect(
          Focus.of(tester.element(tooltipFor(category))).hasPrimaryFocus,
          isTrue,
          reason: '$category should be reachable in keyboard order',
        );
        if (index < focusOrder.length - 1) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
        }
      }

      expect(scrollPosition.pixels, greaterThan(0));
      final viewportRect = tester.getRect(legendScroll);
      final finalItemRect = tester.getRect(
        find.byKey(ValueKey('timeline-category-item-${focusOrder.last}')),
      );
      expect(finalItemRect.left, greaterThanOrEqualTo(viewportRect.left));
      expect(finalItemRect.right, lessThanOrEqualTo(viewportRect.right));
      expect(find.text('${focusOrder.last}，1 分钟，占当日 4%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('timeline card edit validates, cancels, and saves once', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: '7',
          title: '原始标题',
          summary: '原始摘要',
          category: '工作',
          app: 'Visual Studio Code',
          duration: const Duration(hours: 1),
          executablePath: r'C:\Apps\Code.exe',
        ),
      ];

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.tap(find.byKey(const ValueKey('timeline-card-7')));
    await tester.pumpAndSettle();
    expect(find.text('编辑活动'), findsOneWidget);
    expect(find.text('Visual Studio Code'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('timeline-edit-title')),
      '   ',
    );
    await tester.tap(find.byKey(const ValueKey('timeline-edit-save')));
    await tester.pump();
    expect(find.text('标题不能为空'), findsOneWidget);
    expect(viewModel.edits, isEmpty);

    await tester.tap(find.byKey(const ValueKey('timeline-edit-cancel')));
    await tester.pumpAndSettle();
    expect(viewModel.edits, isEmpty);

    await tester.tap(find.byKey(const ValueKey('timeline-card-7')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('timeline-edit-title')),
      '更新后的标题',
    );
    await tester.enterText(
      find.byKey(const ValueKey('timeline-edit-summary')),
      '',
    );
    await tester.tap(find.byKey(const ValueKey('timeline-edit-save')));
    await tester.pumpAndSettle();

    expect(viewModel.edits, hasLength(1));
    expect(viewModel.edits.single.id, '7');
    expect(viewModel.edits.single.title, '更新后的标题');
    expect(viewModel.edits.single.summary, '');
  });

  testWidgets('application tag shows trusted path and reveals its folder', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: '9',
          title: '使用编辑器',
          summary: '',
          category: '编程',
          app: 'Visual Studio Code',
          duration: const Duration(minutes: 20),
          executablePath: r'C:\Apps\Code.exe',
          averageCpuUsagePercent: 12.34,
          peakCpuUsagePercent: 45.67,
          averageMemoryCommitBytes: 1572864,
          peakMemoryCommitBytes: 3221225472,
        ),
      ];

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.tap(find.text('Visual Studio Code'));
    await tester.pumpAndSettle();

    expect(find.text('软件信息'), findsOneWidget);
    expect(find.text(r'C:\Apps\Code.exe'), findsOneWidget);
    expect(find.text('使用时长'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('application-duration')))
          .data,
      '20 分钟',
    );
    expect(find.text('CPU 使用率'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('application-cpu-usage')))
          .data,
      '平均 12.3% · 峰值 45.7%',
    );
    expect(find.text('内存提交'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('application-memory-commit')))
          .data,
      '平均 1.5 MiB · 峰值 3.0 GiB',
    );
    expect(find.text('暂无资源数据'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('open-application-folder')));
    await tester.pumpAndSettle();
    expect(viewModel.revealedExecutables, [r'C:\Apps\Code.exe']);
  });

  testWidgets('application dialog handles missing resource data on narrow UI', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: '10',
          title: '查看旧记录',
          summary: '',
          category: '工作',
          app: 'Legacy Editor',
          duration: const Duration(minutes: 8),
        ),
      ];

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.tap(find.text('Legacy Editor'));
    await tester.pumpAndSettle();

    expect(find.text('软件信息'), findsOneWidget);
    expect(find.text('未记录可执行文件路径'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('application-duration')))
          .data,
      '8 分钟',
    );
    expect(find.text('暂无资源数据'), findsOneWidget);
    expect(find.byKey(const ValueKey('application-cpu-usage')), findsNothing);
    expect(
      find.byKey(const ValueKey('application-memory-commit')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('every application on a card exposes its resource dialog', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = _TestViewModel()
      ..timelineCards = [
        _viewCard(
          id: '11',
          title: '多软件工作流',
          summary: '',
          category: '工作',
          app: 'Editor',
          duration: const Duration(minutes: 30),
          additionalAppUsages: const <TimelineAppViewData>[
            TimelineAppViewData(
              name: 'Browser',
              duration: Duration(minutes: 8),
            ),
            TimelineAppViewData(name: 'Notes', duration: Duration(minutes: 4)),
            TimelineAppViewData(
              name: 'Terminal',
              duration: Duration(minutes: 6),
              averageCpuUsagePercent: 5,
              peakCpuUsagePercent: 9,
            ),
          ],
        ),
      ];

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));

    expect(find.text('Terminal'), findsOneWidget);
    await tester.tap(find.text('Terminal'));
    await tester.pumpAndSettle();
    expect(find.text('软件信息'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('application-cpu-usage')))
          .data,
      '平均 5.0% · 峰值 9.0%',
    );
  });

  testWidgets('statistics dashboard remains usable in a narrow window', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final firstDay = DateTime(2026, 7, 9);
    final secondDay = DateTime(2026, 7, 10);
    final viewModel = _TestViewModel()
      ..statistics = StatisticsViewData(
        totalMinutes: 180,
        weightedProductivity: 82,
        activityCount: 3,
        deepWorkCount: 1,
        highEfficiencyMinutes: 120,
        totalDurationComparison: const StatisticsMetricComparisonViewData(
          current: 180,
          previous: 120,
        ),
        productivityComparison: const StatisticsMetricComparisonViewData(
          current: 82,
          previous: 75,
        ),
        deepWorkComparison: const StatisticsMetricComparisonViewData(
          current: 1,
          previous: 0,
        ),
        activityComparison: const StatisticsMetricComparisonViewData(
          current: 3,
          previous: 2,
        ),
        categoryMinutes: const {'编程': 120, '会议': 60},
        categoryShares: const {'编程': 2 / 3, '会议': 1 / 3},
        dailyMinutes: {firstDay: 60, secondDay: 120},
        dailyCategoryMinutes: {
          firstDay: const {'会议': 60},
          secondDay: const {'编程': 120},
        },
        dailyWeightedProductivity: {firstDay: 70, secondDay: 88},
        hourlyEfficiency: List<HourEfficiencyViewData>.generate(
          24,
          (hour) => HourEfficiencyViewData(
            hour: hour,
            durationMinutes: hour == 9 ? 60 : 0,
            weightedProductivity: hour == 9 ? 88 : 0,
          ),
        ),
        topApps: const [
          StatisticsAppViewData(
            name: 'Visual Studio Code',
            durationMinutes: 120,
            share: 2 / 3,
          ),
          StatisticsAppViewData(
            name: 'Microsoft Teams',
            durationMinutes: 60,
            share: 1 / 3,
          ),
        ],
        thisWeek: const StatisticsPeriodViewData(
          totalMinutes: 180,
          weightedProductivity: 82,
          categoryMinutes: {'编程': 120, '会议': 60},
        ),
        lastWeek: const StatisticsPeriodViewData(
          totalMinutes: 120,
          weightedProductivity: 75,
          categoryMinutes: {'编程': 60, '会议': 60},
        ),
        weeklyCategoryDifference: const {'编程': 60, '会议': 0},
        recentDailyCategoryMinutes: {
          firstDay: const {'会议': 60},
          secondDay: const {'编程': 120},
        },
        todayMinutes: 120,
        dailyGoalHours: 8,
      );

    await tester.pumpWidget(QiDayFlowApp(viewModel: viewModel));
    await tester.tap(find.byKey(const Key('nav-statistics')));
    await tester.pumpAndSettle();

    expect(find.text('总记录时长'), findsOneWidget);
    expect(find.text('每日分类时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.dragUntilVisible(
      find.text('最近 14 天日期对比'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.pump();
    expect(find.text('最近 14 天日期对比'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

TimelineCardViewData _viewCard({
  required String id,
  required String title,
  required String summary,
  required String category,
  required String app,
  required Duration duration,
  String? executablePath,
  double? averageCpuUsagePercent,
  double? peakCpuUsagePercent,
  int? averageMemoryCommitBytes,
  int? peakMemoryCommitBytes,
  List<TimelineAppViewData> additionalAppUsages = const <TimelineAppViewData>[],
  DateTime? startedAt,
}) {
  final start = startedAt ?? DateTime.utc(2026, 7, 10, 8);
  return TimelineCardViewData(
    id: id,
    category: category,
    title: title,
    summary: summary,
    startedAt: start,
    endedAt: start.add(duration),
    productivityScore: 80,
    apps: [app, ...additionalAppUsages.map((item) => item.name)],
    appUsages: [
      TimelineAppViewData(
        name: app,
        duration: duration,
        executablePath: executablePath,
        averageCpuUsagePercent: averageCpuUsagePercent,
        peakCpuUsagePercent: peakCpuUsagePercent,
        averageMemoryCommitBytes: averageMemoryCommitBytes,
        peakMemoryCommitBytes: peakMemoryCommitBytes,
      ),
      ...additionalAppUsages,
    ],
  );
}

AnalysisQueueViewData _threeStateQueue() {
  return AnalysisQueueViewData(
    items: <AnalysisQueueItemViewData>[
      _queueItem(
        chunkId: 1,
        batchId: 7,
        status: ProcessingStatus.processing,
        retryCount: 0,
        processingStartedAt: DateTime.now().subtract(
          const Duration(minutes: 2),
        ),
      ),
      _queueItem(chunkId: 2, status: ProcessingStatus.pending),
      _queueItem(
        chunkId: 3,
        batchId: 9,
        status: ProcessingStatus.failed,
        retryCount: 2,
        errorSummary: '网络连接失败',
      ),
    ],
  );
}

AnalysisQueueItemViewData _queueItem({
  required int chunkId,
  int? batchId,
  required ProcessingStatus status,
  int retryCount = 0,
  DateTime? processingStartedAt,
  String? errorSummary,
}) {
  final recordedAt = DateTime(2026, 7, 11, 9);
  return AnalysisQueueItemViewData(
    chunkId: chunkId,
    batchId: batchId,
    status: status,
    recordedAt: recordedAt,
    recordedUntil: recordedAt.add(const Duration(minutes: 1)),
    enqueuedAt: DateTime(2026, 7, 11, 8, 59),
    updatedAt: DateTime(2026, 7, 11, 9, 2),
    retryCount: retryCount,
    processingStartedAt: processingStartedAt,
    errorSummary: errorSummary,
  );
}

final class _TestViewModel extends ChangeNotifier
    implements QiDayFlowViewModel {
  final List<TimelineCardEditDraft> edits = <TimelineCardEditDraft>[];
  final List<SettingsDraft> savedSettings = <SettingsDraft>[];
  int clearCachedVideoCalls = 0;
  int clearManagedLogCalls = 0;
  final List<AppLogLevel> logLevelUpdates = <AppLogLevel>[];
  final List<String> revealedExecutables = <String>[];
  final List<String> openedUserDataDirectories = <String>[];
  Object? openUserDataDirectoryError;
  final List<String> iconRequests = <String>[];
  int analysisQueueRefreshCalls = 0;
  int retryFailedCalls = 0;
  Completer<void>? refreshGate;
  Completer<void>? retryGate;

  @override
  AppSection section = AppSection.timeline;

  @override
  RecordingViewStatus recordingStatus = RecordingViewStatus.stopped;

  @override
  Duration recordingDuration = Duration.zero;

  @override
  String? statusMessage;

  @override
  DateTime timelineDate = DateTime(2026, 7, 10);

  @override
  List<TimelineCardViewData> timelineCards = const [];

  @override
  bool timelineLoading = false;

  @override
  String? dailyReport;

  @override
  bool reportLoading = false;

  @override
  int statisticsDays = 7;

  @override
  StatisticsViewData statistics = const StatisticsViewData();

  @override
  SettingsViewData settings = const SettingsViewData(
    apiUrl: 'https://api.openai.com/v1',
    hasApiKey: true,
    model: 'gpt-4.1-mini',
    userDataDirectory: r'C:\QiDayFlow',
    activeUserDataDirectory: r'C:\QiDayFlow',
    dataDirectoryRestartRequired: false,
    cacheLimitGb: 5,
    idlePauseEnabled: true,
    idleTimeoutMinutes: 10,
    captureIntervalSeconds: 10,
    themeMode: ThemeMode.system,
  );

  @override
  AnalysisQueueViewData analysisQueue = const AnalysisQueueViewData();

  @override
  int failedChunkCount = 0;

  @override
  int pendingChunkCount = 0;

  @override
  int cacheBytes = 0;

  @override
  int? managedLogBytes;

  @override
  bool clearingManagedLogs = false;

  @override
  String? managedLogError;

  @override
  bool savingSettings = false;

  @override
  SettingsSaveStatus settingsSaveStatus = SettingsSaveStatus.idle;

  @override
  String? settingsSaveError;

  @override
  void selectSection(AppSection value) {
    section = value;
    notifyListeners();
  }

  @override
  Future<void> startCapture() async {}

  @override
  Future<void> pauseOrResumeCapture() async {}

  @override
  Future<void> stopCapture() async {}

  @override
  Future<void> setTimelineDate(DateTime date) async {
    timelineDate = date;
    notifyListeners();
  }

  @override
  Future<void> updateTimelineCard(TimelineCardEditDraft draft) async {
    edits.add(draft);
  }

  @override
  Future<Uint8List?> loadApplicationIcon(String executablePath) async {
    iconRequests.add(executablePath);
    return null;
  }

  @override
  Future<void> revealExecutableInExplorer(String executablePath) async {
    revealedExecutables.add(executablePath);
  }

  @override
  Future<void> openUserDataDirectory(String directoryPath) async {
    openedUserDataDirectories.add(directoryPath);
    final error = openUserDataDirectoryError;
    if (error != null) throw error;
  }

  @override
  Future<void> generateDailyReport() async {}

  @override
  Future<void> setStatisticsDays(int days) async {
    statisticsDays = days;
    notifyListeners();
  }

  @override
  Future<void> updateDailyGoalHours(int hours) async {}

  @override
  Future<String> loadApiKeyForEditing() async => 'test-only-key';

  @override
  Future<void> saveSettings(SettingsDraft draft) async {
    savedSettings.add(draft);
  }

  @override
  Future<void> updateLogLevel(AppLogLevel level) async {
    logLevelUpdates.add(level);
  }

  @override
  Future<void> testApiConnection(SettingsDraft draft) async {}

  @override
  Future<String?> chooseUserDataDirectory() async => null;

  @override
  Future<void> clearCompletedVideos() async {
    clearCachedVideoCalls++;
  }

  @override
  Future<void> clearManagedLogs() async {
    clearManagedLogCalls++;
  }

  @override
  Future<void> refreshAnalysisQueue() async {
    analysisQueueRefreshCalls++;
    await refreshGate?.future;
  }

  @override
  Future<void> retryFailedChunks() async {
    retryFailedCalls++;
    await retryGate?.future;
  }

  @override
  Future<void> exitApplication() async {}
}
