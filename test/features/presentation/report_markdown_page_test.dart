import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qi_day_flow/features/presentation/app_view_model.dart';
import 'package:qi_day_flow/features/presentation/pages/report_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = '# 今日总结\n\n完成了 **关键任务**。\n\n- 第一项\n- 第二项';

  test(
    'default copy writes the original Markdown to the system clipboard',
    () async {
      MethodCall? clipboardCall;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        clipboardCall = call;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await copyMarkdownToClipboard(source);

      expect(clipboardCall?.method, 'Clipboard.setData');
      expect(clipboardCall?.arguments, <String, Object>{'text': source});
    },
  );

  test('default export writes the original Markdown as UTF-8', () async {
    const channel = MethodChannel('qi_day_flow/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final directory = await Directory.systemTemp.createTemp(
      'hermes-verify-report-export-',
    );
    final output = File('${directory.path}\\日报.md');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'selectMarkdownExportPath');
      return output.path;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    expect(
      await exportMarkdownToFile(source, 'QiDayFlow-日报-2026-07-10.md'),
      isTrue,
    );
    expect(await output.readAsString(), source);
  });

  testWidgets('report renders Markdown and copies the original source', (
    tester,
  ) async {
    String? copied;
    final viewModel = _ReportViewModel(source);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportPage(
            viewModel: viewModel,
            copyMarkdown: (value) async => copied = value,
            exportMarkdown: (_, _) async => false,
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.data, source);
    expect(find.text('今日总结'), findsOneWidget);
    expect(find.textContaining('**关键任务**'), findsNothing);

    await tester.tap(find.byTooltip('复制 Markdown'));
    await tester.pumpAndSettle();

    expect(copied, source);
    expect(find.text('日报 Markdown 已复制'), findsOneWidget);
  });

  testWidgets('report exports with a safe date-based Markdown filename', (
    tester,
  ) async {
    String? exportedSource;
    String? suggestedFileName;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportPage(
            viewModel: _ReportViewModel(source),
            copyMarkdown: (_) async {},
            exportMarkdown: (value, fileName) async {
              exportedSource = value;
              suggestedFileName = fileName;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('导出 Markdown 文件'));
    await tester.pumpAndSettle();

    expect(exportedSource, source);
    expect(suggestedFileName, 'QiDayFlow-日报-2026-07-10.md');
    expect(find.text('日报 Markdown 已导出'), findsOneWidget);
  });

  testWidgets('cancelled Markdown export is silent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportPage(
            viewModel: _ReportViewModel(source),
            copyMarkdown: (_) async {},
            exportMarkdown: (_, _) async => false,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('导出 Markdown 文件'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed Markdown export shows an error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportPage(
            viewModel: _ReportViewModel(source),
            copyMarkdown: (_) async {},
            exportMarkdown: (_, _) async => throw StateError('无法写入文件'),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('导出 Markdown 文件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法写入文件'), findsOneWidget);
  });

  testWidgets('report actions do not overflow at narrow width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(240, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportPage(
            viewModel: _ReportViewModel(source),
            copyMarkdown: (_) async {},
            exportMarkdown: (_, _) async => false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('复制 Markdown'), findsOneWidget);
    expect(find.byTooltip('导出 Markdown 文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _ReportViewModel implements QiDayFlowViewModel {
  _ReportViewModel(this.dailyReport);

  @override
  final String dailyReport;

  @override
  DateTime timelineDate = DateTime(2026, 7, 10);

  @override
  bool reportLoading = false;

  @override
  AnalysisQueueViewData analysisQueue = const AnalysisQueueViewData();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> generateDailyReport() async {}

  @override
  Future<void> setTimelineDate(DateTime date) async => timelineDate = date;

  @override
  void selectSection(AppSection section) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
