import 'package:flutter/material.dart';

import 'app_view_model.dart';
import 'pages/analysis_queue_page.dart';
import 'pages/report_page.dart';
import 'pages/settings_page.dart';
import 'pages/statistics_page.dart';
import 'pages/timeline_page.dart';
import 'widgets/ui_actions.dart';

class QiDayFlowShell extends StatelessWidget {
  const QiDayFlowShell({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final sidebarWidth = constraints.maxWidth < 1040 ? 190.0 : 216.0;
            return Row(
              children: [
                SizedBox(
                  width: sidebarWidth,
                  child: _Sidebar(viewModel: viewModel),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: Column(
                    children: [
                      _CaptureCommandBar(viewModel: viewModel),
                      Divider(
                        height: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
                          child: switch (viewModel.section) {
                            AppSection.timeline => TimelinePage(
                              viewModel: viewModel,
                            ),
                            AppSection.analysisQueue => AnalysisQueuePage(
                              viewModel: viewModel,
                            ),
                            AppSection.report => ReportPage(
                              viewModel: viewModel,
                            ),
                            AppSection.statistics => StatisticsPage(
                              viewModel: viewModel,
                            ),
                            AppSection.settings => SettingsPage(
                              viewModel: viewModel,
                            ),
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 22, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(
                      Icons.history_toggle_off,
                      size: 21,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Qi Day Flow',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            _NavItem(
              key: const Key('nav-timeline'),
              icon: Icons.view_timeline_outlined,
              selectedIcon: Icons.view_timeline,
              label: '时间轴',
              selected: viewModel.section == AppSection.timeline,
              onPressed: () => viewModel.selectSection(AppSection.timeline),
            ),
            _NavItem(
              key: const Key('nav-analysis-queue'),
              icon: Icons.pending_actions_outlined,
              selectedIcon: Icons.pending_actions,
              label: '分析队列',
              selected: viewModel.section == AppSection.analysisQueue,
              onPressed: () =>
                  viewModel.selectSection(AppSection.analysisQueue),
            ),
            _NavItem(
              key: const Key('nav-report'),
              icon: Icons.description_outlined,
              selectedIcon: Icons.description,
              label: '日报',
              selected: viewModel.section == AppSection.report,
              onPressed: () => viewModel.selectSection(AppSection.report),
            ),
            _NavItem(
              key: const Key('nav-statistics'),
              icon: Icons.bar_chart_outlined,
              selectedIcon: Icons.bar_chart,
              label: '统计',
              selected: viewModel.section == AppSection.statistics,
              onPressed: () => viewModel.selectSection(AppSection.statistics),
            ),
            _NavItem(
              key: const Key('nav-settings'),
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: '设置',
              selected: viewModel.section == AppSection.settings,
              onPressed: () => viewModel.selectSection(AppSection.settings),
            ),
            const Spacer(),
            if (viewModel.pendingChunkCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.secondary,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '待分析 ${viewModel.pendingChunkCount} 个',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            _NavItem(
              key: const Key('exit-application'),
              icon: Icons.exit_to_app,
              selectedIcon: Icons.exit_to_app,
              label: '退出',
              selected: false,
              onPressed: () => runUiAction(context, viewModel.exitApplication),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    selected ? selectedIcon : icon,
                    size: 20,
                    color: selected
                        ? colors.onSecondaryContainer
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: selected
                            ? colors.onSecondaryContainer
                            : colors.onSurfaceVariant,
                      ),
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

class _CaptureCommandBar extends StatelessWidget {
  const _CaptureCommandBar({required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final status = viewModel.recordingStatus;
    final colors = Theme.of(context).colorScheme;
    final statusColor = switch (status) {
      RecordingViewStatus.recording => const Color(0xFF208061),
      RecordingViewStatus.paused => const Color(0xFFC27318),
      RecordingViewStatus.error => colors.error,
      RecordingViewStatus.starting ||
      RecordingViewStatus.stopping => colors.secondary,
      RecordingViewStatus.stopped => colors.outline,
    };
    final message = viewModel.statusMessage?.trim();

    return ColoredBox(
      color: colors.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 76),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            status.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        if (status.isActive) ...[
                          const SizedBox(width: 10),
                          Text(
                            _formatRecordingDuration(
                              viewModel.recordingDuration,
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ],
                    ),
                    if (message != null && message.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: status == RecordingViewStatus.error
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              _CaptureButtons(viewModel: viewModel),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptureButtons extends StatelessWidget {
  const _CaptureButtons({required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final status = viewModel.recordingStatus;
    if (status == RecordingViewStatus.starting ||
        status == RecordingViewStatus.stopping) {
      return FilledButton.tonalIcon(
        onPressed: null,
        icon: const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text(status == RecordingViewStatus.starting ? '正在启动' : '正在停止'),
      );
    }

    if (status == RecordingViewStatus.stopped ||
        status == RecordingViewStatus.error) {
      return Tooltip(
        message: '开始采集',
        child: FilledButton.icon(
          key: const Key('capture-start-button'),
          onPressed: () => runUiAction(context, viewModel.startCapture),
          icon: const Icon(Icons.fiber_manual_record, size: 18),
          label: const Text('开始'),
        ),
      );
    }

    final paused = status == RecordingViewStatus.paused;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: paused ? '恢复采集' : '暂停采集',
          child: OutlinedButton.icon(
            key: const Key('capture-pause-resume-button'),
            onPressed: () =>
                runUiAction(context, viewModel.pauseOrResumeCapture),
            icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 18),
            label: Text(paused ? '恢复' : '暂停'),
          ),
        ),
        const SizedBox(width: 9),
        Tooltip(
          message: '停止采集',
          child: FilledButton.tonalIcon(
            key: const Key('capture-stop-button'),
            onPressed: () => runUiAction(context, viewModel.stopCapture),
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('停止'),
          ),
        ),
      ],
    );
  }
}

String _formatRecordingDuration(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
