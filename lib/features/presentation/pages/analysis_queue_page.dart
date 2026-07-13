import 'package:flutter/material.dart';

import '../../../core/domain/domain.dart';
import '../../../core/utils/formatters.dart';
import '../app_view_model.dart';
import '../widgets/ui_actions.dart';

class AnalysisQueuePage extends StatefulWidget {
  const AnalysisQueuePage({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  State<AnalysisQueuePage> createState() => _AnalysisQueuePageState();
}

class _AnalysisQueuePageState extends State<AnalysisQueuePage> {
  bool _refreshing = false;
  bool _retrying = false;

  Future<void> _refresh() async {
    if (_refreshing || _retrying) return;
    setState(() => _refreshing = true);
    try {
      await runUiAction(context, widget.viewModel.refreshAnalysisQueue);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _retryFailed() async {
    if (_retrying || _refreshing) return;
    setState(() => _retrying = true);
    try {
      await runUiAction(context, () async {
        await widget.viewModel.retryFailedChunks();
        await widget.viewModel.refreshAnalysisQueue();
      });
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = widget.viewModel.analysisQueue;
    final activeItems = queue.items
        .where((item) => item.status != ProcessingStatus.completed)
        .toList(growable: false);
    return Column(
      key: const ValueKey('analysis-queue-page'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '分析队列',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              key: const ValueKey('analysis-queue-refresh'),
              tooltip: '刷新分析队列',
              onPressed: _refreshing || _retrying ? null : _refresh,
              icon: SizedBox.square(
                dimension: 24,
                child: _refreshing
                    ? const Padding(
                        padding: EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _QueueSummary(queue: queue),
        if (queue.failedCount > 0) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey('analysis-queue-retry-failed'),
              onPressed: _retrying || _refreshing ? null : _retryFailed,
              icon: SizedBox.square(
                dimension: 18,
                child: _retrying
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : const Icon(Icons.replay, size: 18),
              ),
              label: Text(_retrying ? '正在重试' : '重试失败任务'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: activeItems.isEmpty
              ? const _EmptyQueue()
              : ListView.separated(
                  key: const ValueKey('analysis-queue-list'),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: activeItems.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _QueueItem(
                    key: ValueKey(
                      'analysis-queue-item-${activeItems[index].id}',
                    ),
                    item: activeItems[index],
                  ),
                ),
        ),
      ],
    );
  }
}

class _QueueSummary extends StatelessWidget {
  const _QueueSummary({required this.queue});

  final AnalysisQueueViewData queue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entries = <_CountData>[
      _CountData(
        key: const ValueKey('analysis-queue-count-processing'),
        label: '正在分析',
        count: queue.processingCount,
        icon: Icons.autorenew,
        color: const Color(0xFF187A68),
      ),
      _CountData(
        key: const ValueKey('analysis-queue-count-pending'),
        label: '等待',
        count: queue.pendingCount,
        icon: Icons.schedule_outlined,
        color: const Color(0xFF9A6700),
      ),
      _CountData(
        key: const ValueKey('analysis-queue-count-failed'),
        label: '失败',
        count: queue.failedCount,
        icon: Icons.error_outline,
        color: colors.error,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 420) {
          return Column(
            children: [
              for (var index = 0; index < entries.length; index++) ...[
                _CountTile(data: entries[index]),
                if (index != entries.length - 1) const SizedBox(height: 8),
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var index = 0; index < entries.length; index++) ...[
              Expanded(child: _CountTile(data: entries[index])),
              if (index != entries.length - 1) const SizedBox(width: 10),
            ],
          ],
        );
      },
    );
  }
}

class _CountData {
  const _CountData({
    required this.key,
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
  });

  final Key key;
  final String label;
  final int count;
  final IconData icon;
  final Color color;
}

class _CountTile extends StatelessWidget {
  const _CountTile({required this.data});

  final _CountData data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: data.key,
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: data.color.withValues(alpha: 0.08),
        border: Border.all(color: data.color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(data.icon, size: 20, color: data.color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              data.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${data.count}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: data.color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('analysis-queue-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.task_alt,
            size: 42,
            color: colors.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 12),
          Text(
            '分析队列为空',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({super.key, required this.item});

  final AnalysisQueueItemViewData item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = switch (item.status) {
      ProcessingStatus.processing => const Color(0xFF187A68),
      ProcessingStatus.pending => const Color(0xFF9A6700),
      ProcessingStatus.failed => colors.error,
      ProcessingStatus.completed => colors.outline,
    };
    final statusIcon = switch (item.status) {
      ProcessingStatus.processing => Icons.autorenew,
      ProcessingStatus.pending => Icons.schedule_outlined,
      ProcessingStatus.failed => Icons.error_outline,
      ProcessingStatus.completed => Icons.check_circle_outline,
    };
    final identifier = item.isDailyReport
        ? '日报 · ${item.reportDate}'
        : item.batchId == null
        ? '切片 #${item.chunkId}'
        : '批次 #${item.batchId} · 切片 #${item.chunkId}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(statusIcon, size: 18, color: statusColor),
                  const SizedBox(width: 7),
                  Text(
                    _statusLabel(item.status),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Text(
                identifier,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              if (!item.isDailyReport) ...[
                _MetadataText(
                  icon: Icons.videocam_outlined,
                  text:
                      '录制 ${formatClock(item.recordedAt)} - '
                      '${formatClock(item.recordedUntil)}',
                ),
                _MetadataText(
                  icon: Icons.timelapse,
                  text: '时长 ${formatDuration(item.recordingDuration)}',
                ),
              ],
              _MetadataText(
                icon: Icons.playlist_add,
                text: '入队 ${_formatTimestamp(item.enqueuedAt)}',
              ),
              _MetadataText(
                icon: Icons.replay,
                text: '重试 ${item.retryCount} 次',
              ),
            ],
          ),
          if (item.status == ProcessingStatus.processing) ...[
            const SizedBox(height: 12),
            _StatusDetail(
              icon: Icons.hourglass_top,
              color: statusColor,
              text: item.isDailyReport
                  ? '正在后台生成日报'
                  : _processingText(item.processingStartedAt),
            ),
          ],
          if (item.status == ProcessingStatus.failed) ...[
            const SizedBox(height: 12),
            _StatusDetail(
              icon: Icons.info_outline,
              color: statusColor,
              text: item.errorSummary ?? '分析失败，未提供错误详情',
            ),
          ],
        ],
      ),
    );
  }
}

class _MetadataText extends StatelessWidget {
  const _MetadataText({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDetail extends StatelessWidget {
  const _StatusDetail({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

String _statusLabel(ProcessingStatus status) => switch (status) {
  ProcessingStatus.processing => '正在分析',
  ProcessingStatus.pending => '等待分析',
  ProcessingStatus.failed => '分析失败',
  ProcessingStatus.completed => '已完成',
};

String _formatTimestamp(DateTime value) =>
    '${formatIsoDate(value)} ${formatClock(value)}';

String _processingText(DateTime? startedAt) {
  if (startedAt == null) return '正在分析';
  final elapsed = DateTime.now().difference(startedAt);
  final safeElapsed = elapsed.isNegative ? Duration.zero : elapsed;
  return '已分析 ${formatDuration(safeElapsed)}';
}
