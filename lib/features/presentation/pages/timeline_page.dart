import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/domain/domain.dart';
import '../../../core/utils/formatters.dart';
import '../app_theme.dart';
import '../app_view_model.dart';
import '../widgets/ui_actions.dart';

class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<TimelineCardViewData> _filteredCards(List<TimelineCardViewData> cards) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return cards;
    return cards
        .where((card) {
          return card.title.toLowerCase().contains(query) ||
              card.summary.toLowerCase().contains(query) ||
              card.category.toLowerCase().contains(query) ||
              card.apps.any((app) => app.toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final allCards = widget.viewModel.timelineCards;
    final cards = _filteredCards(allCards);
    final total = cards.fold<Duration>(
      Duration.zero,
      (sum, card) => sum + card.duration,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TimelineHeader(
          date: widget.viewModel.timelineDate,
          activityCount: cards.length,
          totalDuration: total,
          onDateChanged: (date) => runUiAction(
            context,
            () => widget.viewModel.setTimelineDate(date),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('timeline-search'),
          controller: _searchController,
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
            hintText: '搜索标题、软件或摘要',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('timeline-search-clear'),
                    tooltip: '清空搜索',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        if (widget.viewModel.failedChunkCount > 0)
          _FailureBanner(
            count: widget.viewModel.failedChunkCount,
            onRetry: () =>
                runUiAction(context, widget.viewModel.retryFailedChunks),
          ),
        const SizedBox(height: 16),
        Expanded(
          child: widget.viewModel.timelineLoading
              ? const Center(child: CircularProgressIndicator())
              : cards.isEmpty
              ? _EmptyTimeline(searching: _query.trim().isNotEmpty)
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: cards.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _ActivityCard(
                    key: ValueKey('timeline-card-${cards[index].id}'),
                    card: cards[index],
                    viewModel: widget.viewModel,
                  ),
                ),
        ),
      ],
    );
  }
}

class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({
    required this.date,
    required this.activityCount,
    required this.totalDuration,
    required this.onDateChanged,
  });

  final DateTime date;
  final int activityCount;
  final Duration totalDuration;
  final ValueChanged<DateTime> onDateChanged;

  @override
  Widget build(BuildContext context) {
    final localDate = DateTime(date.year, date.month, date.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 18,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('时间轴', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              '$activityCount 项活动 · ${formatDuration(totalDuration)}',
              key: const ValueKey('timeline-summary'),
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
              onPressed: () =>
                  onDateChanged(localDate.subtract(const Duration(days: 1))),
              tooltip: '前一天',
              icon: const Icon(Icons.chevron_left),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 112, maxWidth: 140),
              child: Text(
                formatDate(localDate),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              onPressed: localDate.isBefore(today)
                  ? () => onDateChanged(localDate.add(const Duration(days: 1)))
                  : null,
              tooltip: '后一天',
              icon: const Icon(Icons.chevron_right),
            ),
            TextButton(
              onPressed: localDate == today ? null : () => onDateChanged(today),
              child: const Text('今天'),
            ),
          ],
        ),
      ],
    );
  }
}

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.count, required this.onRetry});

  final int count;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count 个切片分析失败，原始关键帧已保留',
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
          IconButton(
            onPressed: onRetry,
            tooltip: '重试失败任务',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off : Icons.timeline,
            size: 46,
            color: colors.outline,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? '没有匹配的活动' : '这一天还没有活动',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (searching) ...[
            const SizedBox(height: 5),
            Text(
              '请尝试其他标题、软件、摘要或类别',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({super.key, required this.card, required this.viewModel});

  final TimelineCardViewData card;
  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = categoryColor(card.category, theme.brightness);
    final narrow = MediaQuery.sizeOf(context).width < 800;
    return Semantics(
      button: true,
      label: '编辑活动 ${card.title}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showEditDialog(context, card, viewModel),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(color: accent, child: const SizedBox(width: 5)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (narrow)
                          _NarrowCardHeading(card: card)
                        else
                          _WideCardHeading(card: card),
                        if (card.summary.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            card.summary,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _Meta(
                              icon: Icons.category_outlined,
                              text: card.category,
                            ),
                            _Meta(
                              icon: Icons.timer_outlined,
                              text: formatDuration(card.duration),
                            ),
                            for (final app in _applications(card))
                              _ApplicationTag(app: app, viewModel: viewModel),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Iterable<TimelineAppViewData> _applications(
    TimelineCardViewData card,
  ) => card.appUsages.isNotEmpty
      ? card.appUsages
      : card.apps.map(
          (name) => TimelineAppViewData(name: name, duration: Duration.zero),
        );
}

class _WideCardHeading extends StatelessWidget {
  const _WideCardHeading({required this.card});

  final TimelineCardViewData card;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            '${formatClock(card.startedAt)} - ${formatClock(card.endedAt)}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: Text(
            card.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(width: 12),
        _ScoreBadge(score: card.productivityScore),
      ],
    );
  }
}

class _NarrowCardHeading extends StatelessWidget {
  const _NarrowCardHeading({required this.card});

  final TimelineCardViewData card;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${formatClock(card.startedAt)} - ${formatClock(card.endedAt)}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            _ScoreBadge(score: card.productivityScore),
          ],
        ),
        const SizedBox(height: 6),
        Text(card.title, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _ApplicationTag extends StatelessWidget {
  const _ApplicationTag({required this.app, required this.viewModel});

  final TimelineAppViewData app;
  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '查看软件信息',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () => _showApplicationDialog(context, app, viewModel),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 230),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ApplicationIcon(
                    executablePath: app.executablePath,
                    viewModel: viewModel,
                    size: 17,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      app.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ApplicationIcon extends StatelessWidget {
  const _ApplicationIcon({
    required this.executablePath,
    required this.viewModel,
    required this.size,
  });

  final String? executablePath;
  final QiDayFlowViewModel viewModel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = executablePath;
    if (path == null) return Icon(Icons.apps, size: size);
    return FutureBuilder<Uint8List?>(
      future: viewModel.loadApplicationIcon(path),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return Icon(Icons.apps, size: size);
        return Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Icon(Icons.apps, size: size),
        );
      },
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    final color = score >= 80
        ? const Color(0xFF16856D)
        : score >= 60
        ? const Color(0xFFC17A18)
        : const Color(0xFFC64D45);
    return Tooltip(
      message: '效率评分',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 17, color: color),
          const SizedBox(width: 3),
          Text(
            score.round().toString(),
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 230),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showApplicationDialog(
  BuildContext context,
  TimelineAppViewData app,
  QiDayFlowViewModel viewModel,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final path = app.executablePath;
      return AlertDialog(
        title: const Text('软件信息'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _ApplicationDialogContent(app: app, viewModel: viewModel),
          ),
        ),
        actions: [
          Tooltip(
            message: path == null ? '没有可用的绝对可执行文件路径' : '在 Explorer 中定位',
            child: FilledButton.icon(
              key: const ValueKey('open-application-folder'),
              onPressed: path == null
                  ? null
                  : () => runUiAction(
                      dialogContext,
                      () => viewModel.revealExecutableInExplorer(path),
                    ),
              icon: const Icon(Icons.folder_open),
              label: const Text('打开所在文件夹'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

class _ApplicationDialogContent extends StatelessWidget {
  const _ApplicationDialogContent({required this.app, required this.viewModel});

  final TimelineAppViewData app;
  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final path = app.executablePath;
    final cpuParts = <String>[
      if (app.averageCpuUsagePercent != null)
        '平均 ${app.averageCpuUsagePercent!.toStringAsFixed(1)}%',
      if (app.peakCpuUsagePercent != null)
        '峰值 ${app.peakCpuUsagePercent!.toStringAsFixed(1)}%',
    ];
    final memoryParts = <String>[
      if (app.averageMemoryCommitBytes != null)
        '平均 ${formatIecBytes(app.averageMemoryCommitBytes!)}',
      if (app.peakMemoryCommitBytes != null)
        '峰值 ${formatIecBytes(app.peakMemoryCommitBytes!)}',
    ];
    final hasResourceData = cpuParts.isNotEmpty || memoryParts.isNotEmpty;
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(app.name, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _ApplicationInfoRow(
          label: '路径',
          child: SelectableText(
            path ?? '未记录可执行文件路径',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (path == null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 72),
            child: Text(
              '旧记录或采集时未能解析路径，无法定位文件。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        _ApplicationInfoRow(
          label: '使用时长',
          child: Text(
            formatDuration(app.duration),
            key: const ValueKey('application-duration'),
          ),
        ),
        const SizedBox(height: 14),
        Text('资源使用（该时段样本）', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        if (!hasResourceData)
          Text(
            '暂无资源数据',
            key: const ValueKey('application-resource-empty'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          )
        else ...[
          _ApplicationInfoRow(
            label: 'CPU 使用率',
            child: Text(
              cpuParts.isEmpty ? '暂无可用样本' : cpuParts.join(' · '),
              key: const ValueKey('application-cpu-usage'),
            ),
          ),
          const SizedBox(height: 8),
          _ApplicationInfoRow(
            label: '内存提交',
            child: Text(
              memoryParts.isEmpty ? '暂无可用样本' : memoryParts.join(' · '),
              key: const ValueKey('application-memory-commit'),
            ),
          ),
        ],
      ],
    );

    final icon = _ApplicationIcon(
      executablePath: path,
      viewModel: viewModel,
      size: 48,
    );
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [icon, const SizedBox(height: 12), details],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        icon,
        const SizedBox(width: 16),
        Expanded(child: details),
      ],
    );
  }
}

class _ApplicationInfoRow extends StatelessWidget {
  const _ApplicationInfoRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

Future<bool?> _showEditDialog(
  BuildContext context,
  TimelineCardViewData card,
  QiDayFlowViewModel viewModel,
) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _TimelineEditDialog(card: card, viewModel: viewModel),
);

class _TimelineEditDialog extends StatefulWidget {
  const _TimelineEditDialog({required this.card, required this.viewModel});

  final TimelineCardViewData card;
  final QiDayFlowViewModel viewModel;

  @override
  State<_TimelineEditDialog> createState() => _TimelineEditDialogState();
}

class _TimelineEditDialogState extends State<_TimelineEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _summary;
  late String _category;
  late double _score;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.card.title);
    _summary = TextEditingController(text: widget.card.summary);
    _category = timelineCategories.contains(widget.card.category)
        ? widget.card.category
        : '其他';
    _score = widget.card.productivityScore.clamp(0, 100);
  }

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.viewModel.updateTimelineCard(
        TimelineCardEditDraft(
          id: widget.card.id,
          category: _category,
          title: _title.text.trim(),
          summary: _summary.text.trim(),
          productivityScore: _score.roundToDouble(),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请检查输入后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final apps = widget.card.apps.isEmpty ? '无' : widget.card.apps.join('、');
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('编辑活动'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ReadOnlyValue(
                    label: '时间范围',
                    value:
                        '${formatClock(widget.card.startedAt)} - '
                        '${formatClock(widget.card.endedAt)} · '
                        '${formatDuration(widget.card.duration)}',
                  ),
                  const SizedBox(height: 10),
                  _ReadOnlyValue(label: '应用', value: apps),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('timeline-edit-category'),
                    initialValue: _category,
                    decoration: const InputDecoration(labelText: '类别'),
                    items: [
                      for (final category in timelineCategories)
                        DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _category = value!),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('timeline-edit-title'),
                    controller: _title,
                    enabled: !_saving,
                    decoration: const InputDecoration(labelText: '标题'),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '标题不能为空' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('timeline-edit-summary'),
                    controller: _summary,
                    enabled: !_saving,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '摘要',
                      hintText: '可留空',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Text('效率评分'),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('timeline-edit-score'),
                          value: _score,
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: _score.round().toString(),
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _score = value),
                        ),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          _score.round().toString(),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('timeline-edit-cancel'),
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey('timeline-edit-save'),
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyValue extends StatelessWidget {
  const _ReadOnlyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}
