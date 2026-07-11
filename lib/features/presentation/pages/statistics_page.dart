import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../app_theme.dart';
import '../app_view_model.dart';
import '../widgets/ui_actions.dart';

class StatisticsPage extends StatelessWidget {
  const StatisticsPage({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final data = viewModel.statistics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatisticsHeader(viewModel: viewModel),
        const SizedBox(height: 24),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _Metrics(data: data),
              const SizedBox(height: 24),
              _ResponsivePair(
                left: _Section(
                  key: const ValueKey('daily-category-section'),
                  title: '每日分类时间',
                  subtitle: '按实际发生日期堆叠，悬停查看分类明细',
                  child: _DailyStackedChart(data: data.dailyCategoryMinutes),
                ),
                right: _Section(
                  title: '每日效率趋势',
                  subtitle: '按当日每段活动时长加权，满分 100',
                  child: _EfficiencyTrend(
                    productivity: data.dailyWeightedProductivity,
                    dailyMinutes: data.dailyMinutes,
                  ),
                ),
              ),
              _ResponsivePair(
                left: _Section(
                  title: '类别分布',
                  child: _CategoryDistribution(
                    minutes: data.categoryMinutes,
                    shares: data.categoryShares,
                  ),
                ),
                right: _Section(
                  title: '今日目标',
                  child: _DailyGoal(data: data, viewModel: viewModel),
                ),
              ),
              _Section(
                title: '24 小时分布',
                subtitle: '按实际分钟拆分到每小时，颜色表示加权效率',
                child: _HourlyHeatmap(data: data.hourlyEfficiency),
              ),
              _ResponsivePair(
                left: _Section(
                  title: '应用使用排行',
                  subtitle: '最多 10 个应用，进度与占比基于本周期应用时长',
                  child: _ApplicationRanking(
                    data: data.topApps,
                    viewModel: viewModel,
                  ),
                ),
                right: _Section(
                  title: '本周 vs 上周',
                  child: _WeekComparison(data: data),
                ),
              ),
              _Section(
                title: '最近 14 天日期对比',
                subtitle: '任选两天比较类别时长',
                child: _DateComparison(data: data.recentDailyCategoryMinutes),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatisticsHeader extends StatelessWidget {
  const _StatisticsHeader({required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('统计概览', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '近 ${viewModel.statisticsDays} 天 · 截至今日，按本地日期和实际记录时长统计',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final range = SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 7, label: Text('近 7 天')),
        ButtonSegment(value: 30, label: Text('近 30 天')),
      ],
      selected: {viewModel.statisticsDays},
      onSelectionChanged: (values) =>
          runUiAction(context, () => viewModel.setStatisticsDays(values.first)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 16), range],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 24),
            range,
          ],
        );
      },
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.data});

  final StatisticsViewData data;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1120
            ? 5
            : constraints.maxWidth >= 820
            ? 3
            : constraints.maxWidth >= 560
            ? 2
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _Metric(
              width: width,
              icon: Icons.schedule,
              label: '总记录时长',
              value: formatMinutes(data.totalMinutes),
              comparison: data.totalDurationComparison,
            ),
            _Metric(
              width: width,
              icon: Icons.bolt,
              label: '加权平均效率',
              value: '${data.weightedProductivity.toStringAsFixed(0)} 分',
              comparison: data.productivityComparison,
              detail: '高效 ${formatMinutes(data.highEfficiencyMinutes)}',
            ),
            _Metric(
              width: width,
              icon: Icons.center_focus_strong,
              label: '深度工作',
              value: '${data.deepWorkCount} 次',
              comparison: data.deepWorkComparison,
              detail: '单次活动不少于 60 分钟',
            ),
            _Metric(
              width: width,
              icon: Icons.window_outlined,
              label: '活跃应用',
              value: '${data.activeApplicationCount} 个',
              detail: '本周期有使用记录',
            ),
            _Metric(
              width: width,
              icon: Icons.view_timeline_outlined,
              label: '活动数',
              value: '${data.activityCount} 项',
              comparison: data.activityComparison,
            ),
          ],
        );
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    this.comparison,
    this.detail,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;
  final StatisticsMetricComparisonViewData? comparison;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final difference = comparison?.difference ?? 0;
    final positive = difference > 0;
    final neutral = difference.abs() < 0.0001;
    final changeColor = neutral
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : positive
        ? const Color(0xFF16856D)
        : Theme.of(context).colorScheme.error;
    final percent = comparison?.percentChange;
    final changeText = comparison == null
        ? null
        : neutral
        ? '与上一周期持平'
        : percent == null
        ? '上一周期为 0，本期新增'
        : '${positive ? '+' : ''}${percent.toStringAsFixed(0)}% 环比';
    return SizedBox(
      width: width,
      height: 126,
      child: Card(
        elevation: .5,
        shadowColor: const Color(0x16000000),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 5),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    Text(
                      detail ?? changeText ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: detail == null ? changeColor : null,
                      ),
                    ),
                    if (detail != null && changeText != null)
                      Text(
                        changeText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: changeColor),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: .5,
        shadowColor: const Color(0x12000000),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _ResponsivePair extends StatelessWidget {
  const _ResponsivePair({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 860) {
          return Column(children: [left, right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

class _DailyStackedChart extends StatefulWidget {
  const _DailyStackedChart({required this.data});

  final Map<DateTime, Map<String, double>> data;

  @override
  State<_DailyStackedChart> createState() => _DailyStackedChartState();
}

class _DailyStackedChartState extends State<_DailyStackedChart> {
  _DailyChartSegment? _hovered;
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    final entries = widget.data.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    if (entries.isEmpty) return const _EmptyStat();
    final colors = <String, Color>{
      for (final category in entries.expand((entry) => entry.value.keys))
        category: categoryColor(category, Theme.of(context).brightness),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('时长（小时）', style: Theme.of(context).textTheme.labelSmall),
            Text('日期', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          key: const ValueKey('daily-category-chart'),
          height: 232,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = math.max(
                constraints.maxWidth,
                entries.length * 34.0 + _dailyChartLeft + _dailyChartRight,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: MouseRegion(
                  onExit: (_) => _clearHover(),
                  onHover: (event) => _updateHover(
                    event.localPosition,
                    Size(width, 232),
                    entries,
                  ),
                  child: SizedBox(
                    width: width,
                    height: 232,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _DailyStackedPainter(
                              entries: entries,
                              categoryColors: colors,
                              gridColor: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                              textColor: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              hovered: _hovered,
                            ),
                          ),
                        ),
                        if (_hovered case final hovered?)
                          _DailyChartTooltip(
                            segment: hovered,
                            pointer: _pointer ?? hovered.rect.center,
                            chartSize: Size(width, 232),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _updateHover(
    Offset position,
    Size size,
    List<MapEntry<DateTime, Map<String, double>>> entries,
  ) {
    final hit = _dailyChartSegments(
      entries,
      size,
    ).where((segment) => segment.rect.contains(position)).firstOrNull;
    if (hit == _hovered && _pointer == position) return;
    setState(() {
      _hovered = hit;
      _pointer = hit == null ? null : position;
    });
  }

  void _clearHover() {
    if (_hovered == null && _pointer == null) return;
    setState(() {
      _hovered = null;
      _pointer = null;
    });
  }
}

const _dailyChartLeft = 44.0;
const _dailyChartRight = 12.0;
const _dailyChartTop = 12.0;
const _dailyChartBottom = 32.0;

final class _DailyChartSegment {
  const _DailyChartSegment({
    required this.day,
    required this.category,
    required this.minutes,
    required this.dayTotal,
    required this.rect,
  });

  final DateTime day;
  final String category;
  final double minutes;
  final double dayTotal;
  final Rect rect;

  double get share => dayTotal <= 0 ? 0 : (minutes / dayTotal).clamp(0, 1);

  @override
  bool operator ==(Object other) =>
      other is _DailyChartSegment &&
      day == other.day &&
      category == other.category &&
      rect == other.rect;

  @override
  int get hashCode => Object.hash(day, category, rect);
}

List<_DailyChartSegment> _dailyChartSegments(
  List<MapEntry<DateTime, Map<String, double>>> entries,
  Size size,
) {
  if (entries.isEmpty) return const [];
  final chartHeight = math.max(
    0.0,
    size.height - _dailyChartTop - _dailyChartBottom,
  );
  final plotWidth = math.max(
    0.0,
    size.width - _dailyChartLeft - _dailyChartRight,
  );
  final totals = entries
      .map(
        (entry) => entry.value.values.fold<double>(
          0,
          (sum, value) => value.isFinite && value > 0 ? sum + value : sum,
        ),
      )
      .toList(growable: false);
  final maxValue = totals.fold<double>(0, math.max);
  if (maxValue <= 0 || plotWidth <= 0 || chartHeight <= 0) return const [];
  final slot = plotWidth / entries.length;
  final barWidth = math.min(24.0, slot * .62);
  final segments = <_DailyChartSegment>[];
  for (var index = 0; index < entries.length; index++) {
    var y = _dailyChartTop + chartHeight;
    final categories = entries[index].value.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final category in categories) {
      final minutes = category.value;
      if (!minutes.isFinite || minutes <= 0) continue;
      final height = minutes / maxValue * chartHeight;
      final rect = Rect.fromLTWH(
        _dailyChartLeft + slot * index + (slot - barWidth) / 2,
        y - height,
        barWidth,
        height,
      );
      segments.add(
        _DailyChartSegment(
          day: entries[index].key,
          category: category.key,
          minutes: minutes,
          dayTotal: totals[index],
          rect: rect,
        ),
      );
      y -= height;
    }
  }
  return segments;
}

class _DailyChartTooltip extends StatelessWidget {
  const _DailyChartTooltip({
    required this.segment,
    required this.pointer,
    required this.chartSize,
  });

  final _DailyChartSegment segment;
  final Offset pointer;
  final Size chartSize;

  @override
  Widget build(BuildContext context) {
    final width = math.max(0.0, math.min(190.0, chartSize.width - 8));
    const height = 66.0;
    final maxLeft = math.max(4.0, chartSize.width - width - 4);
    final left = (pointer.dx + 12).clamp(4.0, maxLeft);
    final top = (pointer.dy - height - 10).clamp(
      4.0,
      chartSize.height - height - 4,
    );
    final day = segment.day;
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('daily-category-tooltip'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.inverseSurface,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${day.year}年${day.month}月${day.day}日 · ${segment.category}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${formatMinutes(segment.minutes)} · '
                '当日 ${(segment.share * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DailyStackedPainter extends CustomPainter {
  const _DailyStackedPainter({
    required this.entries,
    required this.categoryColors,
    required this.gridColor,
    required this.textColor,
    required this.hovered,
  });

  final List<MapEntry<DateTime, Map<String, double>>> entries;
  final Map<String, Color> categoryColors;
  final Color gridColor;
  final Color textColor;
  final _DailyChartSegment? hovered;

  @override
  void paint(Canvas canvas, Size size) {
    const top = _dailyChartTop;
    const bottom = _dailyChartBottom;
    final chartHeight = size.height - top - bottom;
    final totals = entries
        .map(
          (entry) => entry.value.values.fold<double>(
            0,
            (sum, value) => value.isFinite && value > 0 ? sum + value : sum,
          ),
        )
        .toList(growable: false);
    final maxValue = totals.fold<double>(0, math.max);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var line = 0; line <= 4; line++) {
      final y = top + chartHeight * line / 4;
      canvas.drawLine(
        Offset(_dailyChartLeft, y),
        Offset(size.width - _dailyChartRight, y),
        gridPaint,
      );
      final value = maxValue * (4 - line) / 4 / 60;
      final label = TextPainter(
        text: TextSpan(
          text: value.toStringAsFixed(value >= 10 ? 0 : 1),
          style: TextStyle(color: textColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(_dailyChartLeft - label.width - 6, y - label.height / 2),
      );
    }
    final plotWidth = size.width - _dailyChartLeft - _dailyChartRight;
    final slot = plotWidth / entries.length;
    final labelEvery = math.max(1, (entries.length / 8).ceil());
    for (final segment in _dailyChartSegments(entries, size)) {
      final rect = RRect.fromRectAndRadius(
        segment.rect,
        const Radius.circular(2),
      );
      final isHovered = hovered == segment;
      canvas.drawRRect(
        rect,
        Paint()..color = categoryColors[segment.category] ?? textColor,
      );
      if (isHovered) {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = Colors.white.withValues(alpha: .55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    for (var index = 0; index < entries.length; index++) {
      if (index % labelEvery == 0 || index == entries.length - 1) {
        final day = entries[index].key;
        final painter = TextPainter(
          text: TextSpan(
            text: '${day.month}/${day.day}',
            style: TextStyle(color: textColor, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          Offset(
            _dailyChartLeft + slot * (index + 0.5) - painter.width / 2,
            size.height - 18,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DailyStackedPainter oldDelegate) =>
      oldDelegate.entries != entries ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.textColor != textColor ||
      oldDelegate.hovered != hovered;
}

class _EfficiencyTrend extends StatelessWidget {
  const _EfficiencyTrend({
    required this.productivity,
    required this.dailyMinutes,
  });

  final Map<DateTime, double> productivity;
  final Map<DateTime, double> dailyMinutes;

  @override
  Widget build(BuildContext context) {
    final entries = productivity.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    if (entries.isEmpty) return const _EmptyStat();
    final width = math.max(620.0, entries.length * 34.0);
    return SizedBox(
      height: 210,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: CustomPaint(
          size: Size(width, 200),
          painter: _EfficiencyPainter(
            entries: entries,
            dailyMinutes: dailyMinutes,
            lineColor: Theme.of(context).colorScheme.primary,
            gridColor: Theme.of(context).colorScheme.outlineVariant,
            textColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _EfficiencyPainter extends CustomPainter {
  const _EfficiencyPainter({
    required this.entries,
    required this.dailyMinutes,
    required this.lineColor,
    required this.gridColor,
    required this.textColor,
  });

  final List<MapEntry<DateTime, double>> entries;
  final Map<DateTime, double> dailyMinutes;
  final Color lineColor;
  final Color gridColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 30.0;
    const top = 8.0;
    const bottom = 26.0;
    final width = size.width - left - 8;
    final height = size.height - top - bottom;
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final score in <int>[0, 25, 50, 75, 100]) {
      final y = top + height * (1 - score / 100);
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      final label = TextPainter(
        text: TextSpan(
          text: '$score',
          style: TextStyle(color: textColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(left - label.width - 5, y - label.height / 2));
    }
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = lineColor;
    final path = Path();
    var started = false;
    final labelEvery = math.max(1, (entries.length / 8).ceil());
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final x = entries.length == 1
          ? left + width / 2
          : left + width * index / (entries.length - 1);
      if ((dailyMinutes[entry.key] ?? 0) > 0) {
        final y = top + height * (1 - entry.value.clamp(0, 100) / 100);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 3, dotPaint);
      }
      if (index % labelEvery == 0 || index == entries.length - 1) {
        final day = entry.key;
        final label = TextPainter(
          text: TextSpan(
            text: '${day.month}/${day.day}',
            style: TextStyle(color: textColor, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, Offset(x - label.width / 2, size.height - 17));
      }
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _EfficiencyPainter oldDelegate) =>
      oldDelegate.entries != entries ||
      oldDelegate.dailyMinutes != dailyMinutes ||
      oldDelegate.lineColor != lineColor;
}

class _CategoryDistribution extends StatelessWidget {
  const _CategoryDistribution({required this.minutes, required this.shares});

  final Map<String, double> minutes;
  final Map<String, double> shares;

  @override
  Widget build(BuildContext context) {
    final entries = minutes.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    if (entries.isEmpty) return const _EmptyStat();
    final colors = <String, Color>{
      for (final entry in entries)
        entry.key: categoryColor(entry.key, Theme.of(context).brightness),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        final ring = SizedBox.square(
          dimension: 132,
          child: CustomPaint(
            painter: _DonutPainter(
              shares: shares,
              colors: colors,
              trackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Center(
              child: Text(
                formatMinutes(minutes.values.fold<double>(0, (a, b) => a + b)),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
        );
        final list = Column(
          children: [
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(width: 9, height: 9, color: colors[entry.key]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(entry.key, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${((shares[entry.key] ?? 0) * 100).toStringAsFixed(0)}%',
                    ),
                    const SizedBox(width: 8),
                    Text(formatMinutes(entry.value)),
                  ],
                ),
              ),
          ],
        );
        return compact
            ? Column(children: [ring, const SizedBox(height: 14), list])
            : Row(
                children: [
                  ring,
                  const SizedBox(width: 20),
                  Expanded(child: list),
                ],
              );
      },
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.shares,
    required this.colors,
    required this.trackColor,
  });

  final Map<String, double> shares;
  final Map<String, Color> colors;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 10;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15;
    canvas.drawCircle(center, radius, paint..color = trackColor);
    var start = -math.pi / 2;
    for (final entry in shares.entries) {
      final sweep = math.pi * 2 * entry.value.clamp(0, 1);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        false,
        paint..color = colors[entry.key] ?? trackColor,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.shares != shares || oldDelegate.trackColor != trackColor;
}

class _DailyGoal extends StatelessWidget {
  const _DailyGoal({required this.data, required this.viewModel});

  final StatisticsViewData data;
  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton.outlined(
              key: const ValueKey('goal-decrease'),
              tooltip: '减少目标小时数',
              onPressed: data.dailyGoalHours <= 1
                  ? null
                  : () => runUiAction(
                      context,
                      () => viewModel.updateDailyGoalHours(
                        data.dailyGoalHours - 1,
                      ),
                    ),
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Text(
                '${data.dailyGoalHours} 小时',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton.outlined(
              key: const ValueKey('goal-increase'),
              tooltip: '增加目标小时数',
              onPressed: data.dailyGoalHours >= 16
                  ? null
                  : () => runUiAction(
                      context,
                      () => viewModel.updateDailyGoalHours(
                        data.dailyGoalHours + 1,
                      ),
                    ),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 18),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 12,
            value: data.todayGoalProgress,
            color: colors.primary,
            backgroundColor: colors.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '今日 ${formatMinutes(data.todayMinutes)} · '
          '完成 ${(data.todayGoalProgress * 100).toStringAsFixed(0)}%',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _HourlyHeatmap extends StatelessWidget {
  const _HourlyHeatmap({required this.data});

  final List<HourEfficiencyViewData> data;

  @override
  Widget build(BuildContext context) {
    final values = data.isEmpty
        ? List<HourEfficiencyViewData>.generate(
            24,
            (hour) => HourEfficiencyViewData(
              hour: hour,
              durationMinutes: 0,
              weightedProductivity: 0,
            ),
          )
        : data;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 76,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final item in values)
              Tooltip(
                message: item.durationMinutes <= 0
                    ? '${item.hour.toString().padLeft(2, '0')}:00 · 无记录'
                    : '${item.hour.toString().padLeft(2, '0')}:00 · '
                          '${formatMinutes(item.durationMinutes)} · '
                          '${item.weightedProductivity.toStringAsFixed(0)} 分',
                child: SizedBox(
                  width: 38,
                  child: Column(
                    children: [
                      Container(
                        width: 30,
                        height: 36,
                        decoration: BoxDecoration(
                          color: item.durationMinutes <= 0
                              ? colors.surfaceContainerHighest
                              : Color.lerp(
                                  colors.errorContainer,
                                  const Color(0xFF16856D),
                                  (item.weightedProductivity / 100).clamp(0, 1),
                                ),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.hour % 3 == 0
                            ? item.hour.toString().padLeft(2, '0')
                            : '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ApplicationRanking extends StatefulWidget {
  const _ApplicationRanking({required this.data, required this.viewModel});

  final List<StatisticsAppViewData> data;
  final QiDayFlowViewModel viewModel;

  @override
  State<_ApplicationRanking> createState() => _ApplicationRankingState();
}

class _ApplicationRankingState extends State<_ApplicationRanking> {
  final Map<String, Future<Uint8List?>> _icons = {};

  @override
  void didUpdateWidget(covariant _ApplicationRanking oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) _icons.clear();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) return const _EmptyStat();
    return Column(
      children: [
        for (var index = 0; index < widget.data.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${index + 1}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _icon(widget.data[index]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.data[index].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              formatMinutes(widget.data[index].durationMinutes),
                              textAlign: TextAlign.right,
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 38,
                              child: Text(
                                '${(_safeShare(widget.data[index].share) * 100).toStringAsFixed(0)}%',
                                textAlign: TextAlign.right,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            minHeight: 5,
                            value: _safeShare(widget.data[index].share),
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _icon(StatisticsAppViewData app) {
    final path = app.executablePath?.trim();
    if (path == null || path.isEmpty) return _fallback(app.name);
    final future = _icons.putIfAbsent(path, () => _loadIcon(path));
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return _fallback(app.name);
        return _ApplicationIconFrame(
          child: Image.memory(
            bytes,
            key: ValueKey('statistics-app-icon-${app.name}'),
            width: 28,
            height: 28,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallback(app.name),
          ),
        );
      },
    );
  }

  Future<Uint8List?> _loadIcon(String path) async {
    try {
      return await widget.viewModel.loadApplicationIcon(path);
    } catch (_) {
      return null;
    }
  }

  Widget _fallback(String name) => _ApplicationIconFrame(
    key: ValueKey('statistics-app-icon-fallback-$name'),
    child: const Icon(Icons.apps_outlined, size: 21),
  );

  static double _safeShare(double value) =>
      value.isFinite ? value.clamp(0, 1).toDouble() : 0;
}

class _ApplicationIconFrame extends StatelessWidget {
  const _ApplicationIconFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: child,
      ),
    );
  }
}

class _WeekComparison extends StatelessWidget {
  const _WeekComparison({required this.data});

  final StatisticsViewData data;

  @override
  Widget build(BuildContext context) {
    final categories = data.weeklyCategoryDifference.entries.toList()
      ..sort((left, right) => right.value.abs().compareTo(left.value.abs()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _WeekValue(label: '本周', data: data.thisWeek),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _WeekValue(label: '上周', data: data.lastWeek),
            ),
          ],
        ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 16),
          for (final entry in categories.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(child: Text(entry.key)),
                  Text(
                    '${entry.value >= 0 ? '+' : ''}${formatMinutes(entry.value.abs())}',
                    style: TextStyle(
                      color: entry.value >= 0
                          ? const Color(0xFF16856D)
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _WeekValue extends StatelessWidget {
  const _WeekValue({required this.label, required this.data});

  final String label;
  final StatisticsPeriodViewData data;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 5),
        Text(
          formatMinutes(data.totalMinutes),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text('${data.weightedProductivity.toStringAsFixed(0)} 分效率'),
      ],
    );
  }
}

class _DateComparison extends StatefulWidget {
  const _DateComparison({required this.data});

  final Map<DateTime, Map<String, double>> data;

  @override
  State<_DateComparison> createState() => _DateComparisonState();
}

class _DateComparisonState extends State<_DateComparison> {
  DateTime? _left;
  DateTime? _right;

  List<DateTime> get _dates =>
      widget.data.keys.toList()..sort((left, right) => right.compareTo(left));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureSelections();
  }

  @override
  void didUpdateWidget(covariant _DateComparison oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureSelections();
  }

  void _ensureSelections() {
    final dates = _dates;
    if (dates.isEmpty) {
      _left = null;
      _right = null;
      return;
    }
    if (!dates.contains(_left)) _left = dates.first;
    if (!dates.contains(_right)) {
      _right = dates.length > 1 ? dates[1] : dates.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dates = _dates;
    if (dates.isEmpty || _left == null || _right == null) {
      return const _EmptyStat();
    }
    final leftData = widget.data[_left] ?? const <String, double>{};
    final rightData = widget.data[_right] ?? const <String, double>{};
    final categories = <String>{...leftData.keys, ...rightData.keys}.toList()
      ..sort();
    final maxValue = categories.fold<double>(0, (current, category) {
      return math.max(
        current,
        math.max(leftData[category] ?? 0, rightData[category] ?? 0),
      );
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 10,
          children: [
            _DateSelector(
              key: const ValueKey('date-compare-left'),
              label: '日期 A',
              value: _left!,
              dates: dates,
              onChanged: (value) => setState(() => _left = value),
            ),
            _DateSelector(
              key: const ValueKey('date-compare-right'),
              label: '日期 B',
              value: _right!,
              dates: dates,
              onChanged: (value) => setState(() => _right = value),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (categories.isEmpty)
          const _EmptyStat()
        else
          for (final category in categories)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(category, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ComparisonBars(
                      left: leftData[category] ?? 0,
                      right: rightData[category] ?? 0,
                      max: maxValue,
                      color: categoryColor(
                        category,
                        Theme.of(context).brightness,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

class _DateSelector extends StatelessWidget {
  const _DateSelector({
    super.key,
    required this.label,
    required this.value,
    required this.dates,
    required this.onChanged,
  });

  final String label;
  final DateTime value;
  final List<DateTime> dates;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: DropdownButtonFormField<DateTime>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final date in dates)
            DropdownMenuItem(
              value: date,
              child: Text(
                formatIsoDate(date),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }
}

class _ComparisonBars extends StatelessWidget {
  const _ComparisonBars({
    required this.left,
    required this.right,
    required this.max,
    required this.color,
  });

  final double left;
  final double right;
  final double max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ComparisonBar(value: left, max: max, color: color, label: 'A'),
        const SizedBox(height: 5),
        _ComparisonBar(
          value: right,
          max: max,
          color: color.withValues(alpha: 0.55),
          label: 'B',
        ),
      ],
    );
  }
}

class _ComparisonBar extends StatelessWidget {
  const _ComparisonBar({
    required this.value,
    required this.max,
    required this.color,
    required this.label,
  });

  final double value;
  final double max;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: LinearProgressIndicator(
            minHeight: 8,
            value: max <= 0 ? 0 : value / max,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 78,
          child: Text(formatMinutes(value), textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

class _EmptyStat extends StatelessWidget {
  const _EmptyStat();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: Center(
        child: Text(
          '暂无可统计的活动',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }
}
