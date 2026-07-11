import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/app.dart';
import 'package:qi_day_flow/core/domain/domain.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';

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
}) {
  final start = DateTime.utc(2026, 7, 10, 8);
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
