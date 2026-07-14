import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../core/domain/domain.dart';
import '../../../core/utils/formatters.dart';
import '../../../services/native/native_capture_service.dart';
import '../app_view_model.dart';
import '../widgets/ui_actions.dart';

typedef CopyMarkdownAction = Future<void> Function(String source);
typedef ExportMarkdownAction =
    Future<bool> Function(String source, String suggestedFileName);

Future<void> copyMarkdownToClipboard(String source) =>
    Clipboard.setData(ClipboardData(text: source));

Future<bool> exportMarkdownToFile(
  String source,
  String suggestedFileName,
) async {
  final path = await NativeCaptureService().selectMarkdownExportPath(
    suggestedFileName,
  );
  if (path == null) return false;
  await File(path).writeAsString(source, encoding: utf8, flush: true);
  return true;
}

void _showReportMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class ReportPage extends StatelessWidget {
  const ReportPage({
    super.key,
    required this.viewModel,
    this.copyMarkdown = copyMarkdownToClipboard,
    this.exportMarkdown = exportMarkdownToFile,
  });

  final QiDayFlowViewModel viewModel;
  final CopyMarkdownAction copyMarkdown;
  final ExportMarkdownAction exportMarkdown;

  @override
  Widget build(BuildContext context) {
    final report = viewModel.dailyReport;
    final reportSource = report ?? '';
    final hasReport = reportSource.isNotEmpty;
    final failedJob = _failedReportJobForDate(
      viewModel.analysisQueue,
      formatIsoDate(viewModel.timelineDate),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 18,
          runSpacing: 12,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('日报', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  formatDate(viewModel.timelineDate),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                IconButton(
                  onPressed: () => runUiAction(
                    context,
                    () => viewModel.setTimelineDate(
                      viewModel.timelineDate.subtract(const Duration(days: 1)),
                    ),
                  ),
                  tooltip: '前一天',
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  onPressed: _isToday(viewModel.timelineDate)
                      ? null
                      : () => runUiAction(
                          context,
                          () => viewModel.setTimelineDate(
                            viewModel.timelineDate.add(const Duration(days: 1)),
                          ),
                        ),
                  tooltip: '后一天',
                  icon: const Icon(Icons.chevron_right),
                ),
                if (hasReport)
                  Tooltip(
                    message: '复制 Markdown',
                    child: OutlinedButton.icon(
                      key: const ValueKey('report-copy'),
                      onPressed: () => runUiAction(context, () async {
                        await copyMarkdown(reportSource);
                        if (context.mounted) {
                          _showReportMessage(context, '日报 Markdown 已复制');
                        }
                      }),
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const Text('一键复制'),
                    ),
                  ),
                if (hasReport)
                  Tooltip(
                    message: '导出 Markdown 文件',
                    child: OutlinedButton.icon(
                      key: const ValueKey('report-export'),
                      onPressed: () => runUiAction(context, () async {
                        final exported = await exportMarkdown(
                          reportSource,
                          'QiDayFlow-日报-${formatIsoDate(viewModel.timelineDate)}.md',
                        );
                        if (exported && context.mounted) {
                          _showReportMessage(context, '日报 Markdown 已导出');
                        }
                      }),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('导出 Markdown'),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: viewModel.reportLoading
                      ? null
                      : () =>
                            runUiAction(context, viewModel.generateDailyReport),
                  icon: viewModel.reportLoading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(hasReport ? '重新生成' : '生成日报'),
                ),
              ],
            ),
          ],
        ),
        if (viewModel.reportLoading) ...[
          const SizedBox(height: 12),
          _ReportQueueBanner(
            message: '已加入分析队列，后台生成中，可安全离开此页面',
            loading: true,
            onOpenQueue: () =>
                viewModel.selectSection(AppSection.analysisQueue),
          ),
        ] else if (failedJob != null) ...[
          const SizedBox(height: 12),
          _ReportQueueBanner(
            message: '日报生成失败：${failedJob.errorSummary ?? '可前往分析队列重试'}',
            loading: false,
            onOpenQueue: () =>
                viewModel.selectSection(AppSection.analysisQueue),
          ),
        ],
        const SizedBox(height: 18),
        Expanded(
          child: !hasReport
              ? _EmptyReport(loading: viewModel.reportLoading)
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(4, 20, 12, 36),
                  child: MarkdownBody(
                    data: reportSource,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(
                          p: Theme.of(
                            context,
                          ).textTheme.bodyLarge?.copyWith(height: 1.7),
                          listBullet: Theme.of(
                            context,
                          ).textTheme.bodyLarge?.copyWith(height: 1.7),
                        ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ReportQueueBanner extends StatelessWidget {
  const _ReportQueueBanner({
    required this.message,
    required this.loading,
    required this.onOpenQueue,
  });

  final String message;
  final bool loading;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget messageRow() => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (loading)
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(Icons.error_outline, size: 18, color: colors.error),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    );
    final openQueue = TextButton.icon(
      onPressed: onOpenQueue,
      icon: const Icon(Icons.list_alt, size: 18),
      label: const Text('去分析队列'),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: (loading ? colors.secondaryContainer : colors.errorContainer)
            .withValues(alpha: loading ? 0.45 : 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 360) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                messageRow(),
                Align(alignment: Alignment.centerRight, child: openQueue),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: messageRow()),
              const SizedBox(width: 8),
              openQueue,
            ],
          );
        },
      ),
    );
  }
}

AnalysisQueueItemViewData? _failedReportJobForDate(
  AnalysisQueueViewData queue,
  String reportDate,
) {
  for (final item in queue.items) {
    if (item.isDailyReport &&
        item.reportDate == reportDate &&
        item.status == ProcessingStatus.failed) {
      return item;
    }
  }
  return null;
}

bool _isToday(DateTime value) {
  final now = DateTime.now();
  return value.year == now.year &&
      value.month == now.month &&
      value.day == now.day;
}

class _EmptyReport extends StatelessWidget {
  const _EmptyReport({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loading ? Icons.schedule_outlined : Icons.description_outlined,
            size: 46,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            loading ? '日报已加入后台队列' : '尚未生成日报',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
