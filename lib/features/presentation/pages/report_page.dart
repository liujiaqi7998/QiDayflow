import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../app_view_model.dart';
import '../widgets/ui_actions.dart';

class ReportPage extends StatelessWidget {
  const ReportPage({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final report = viewModel.dailyReport;
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
            Row(
              mainAxisSize: MainAxisSize.min,
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
                const SizedBox(width: 10),
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
                  label: Text(report == null ? '生成日报' : '重新生成'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: report == null
              ? _EmptyReport(loading: viewModel.reportLoading)
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(4, 20, 12, 36),
                  child: _MarkdownDocument(source: report),
                ),
        ),
      ],
    );
  }
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
          if (loading)
            const SizedBox.square(
              dimension: 30,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            Icon(
              Icons.description_outlined,
              size: 46,
              color: Theme.of(context).colorScheme.outline,
            ),
          const SizedBox(height: 12),
          Text(
            loading ? '正在生成日报' : '尚未生成日报',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _MarkdownDocument extends StatelessWidget {
  const _MarkdownDocument({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    for (final line in source.split('\n')) {
      final trimmed = line.trimRight();
      TextStyle? style;
      var text = trimmed;
      if (trimmed.startsWith('# ')) {
        text = trimmed.substring(2);
        style = theme.textTheme.headlineSmall;
      } else if (trimmed.startsWith('## ')) {
        text = trimmed.substring(3);
        style = theme.textTheme.titleLarge;
      } else if (trimmed.startsWith('### ')) {
        text = trimmed.substring(4);
        style = theme.textTheme.titleMedium;
      } else if (trimmed.startsWith('- ')) {
        text = '• ${trimmed.substring(2)}';
      }
      spans.add(
        TextSpan(
          text: '$text\n',
          style:
              style?.copyWith(height: 1.7) ??
              theme.textTheme.bodyLarge?.copyWith(height: 1.7),
        ),
      );
    }
    return SelectableText.rich(TextSpan(children: spans));
  }
}
