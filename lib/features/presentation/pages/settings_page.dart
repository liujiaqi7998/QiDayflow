import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/domain/domain.dart';
import '../../../core/utils/formatters.dart';
import '../app_view_model.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _userDataDirectory;
  late int _cacheLimitGb;
  late bool _idlePauseEnabled;
  late int _idleTimeoutMinutes;
  late int _captureIntervalSeconds;
  late ThemeMode _themeMode;
  late AppLogLevel _logLevel;
  bool _showApiKey = false;
  bool _loadingApiKey = true;
  bool _apiKeyLoadFailed = false;
  bool _apiKeyDirty = false;
  bool _pendingTextSave = false;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    final value = widget.viewModel.settings;
    _apiUrl = TextEditingController(text: value.apiUrl);
    _apiKey = TextEditingController();
    _model = TextEditingController(text: value.model);
    _userDataDirectory = TextEditingController(text: value.userDataDirectory);
    _cacheLimitGb = value.cacheLimitGb;
    _idlePauseEnabled = value.idlePauseEnabled;
    _idleTimeoutMinutes = value.idleTimeoutMinutes;
    _captureIntervalSeconds = value.captureIntervalSeconds;
    _themeMode = value.themeMode;
    _logLevel = value.logLevel;
    unawaited(_loadApiKey());
  }

  Future<void> _loadApiKey() async {
    try {
      final value = await widget.viewModel.loadApiKeyForEditing();
      if (!mounted) return;
      _apiKey.text = value;
      setState(() => _loadingApiKey = false);
    } on Object {
      if (!mounted) return;
      setState(() {
        _loadingApiKey = false;
        _apiKeyLoadFailed = true;
      });
    }
  }

  @override
  void dispose() {
    final pendingDraft = _pendingTextSave && _draftLooksValid()
        ? _draft()
        : null;
    _saveDebounce?.cancel();
    _pendingTextSave = false;
    if (pendingDraft != null) {
      unawaited(widget.viewModel.saveSettings(pendingDraft).catchError((_) {}));
    }
    _apiKey.clear();
    _apiUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _userDataDirectory.dispose();
    super.dispose();
  }

  SettingsDraft _draft() => SettingsDraft(
    apiUrl: _apiUrl.text.trim(),
    apiKey: _apiKey.text,
    model: _model.text.trim(),
    userDataDirectory: _userDataDirectory.text.trim(),
    cacheLimitGb: _cacheLimitGb,
    idlePauseEnabled: _idlePauseEnabled,
    idleTimeoutMinutes: _idleTimeoutMinutes,
    captureIntervalSeconds: widget.viewModel.recordingStatus.isActive
        ? widget.viewModel.settings.captureIntervalSeconds
        : _captureIntervalSeconds,
    themeMode: _themeMode,
    logLevel: _logLevel,
    apiKeyChanged: _apiKeyDirty,
  );

  bool _draftLooksValid() =>
      _validateApiUrl(_apiUrl.text) == null &&
      _model.text.trim().isNotEmpty &&
      _userDataDirectory.text.trim().isNotEmpty &&
      (widget.viewModel.settings.hasApiKey || _apiKey.text.trim().isNotEmpty);

  void _scheduleTextSave() {
    _pendingTextSave = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _pendingTextSave = false;
      unawaited(_saveNow());
    });
  }

  void _saveImmediately() {
    _saveDebounce?.cancel();
    _pendingTextSave = false;
    unawaited(_saveNow());
  }

  Future<void> _saveNow() async {
    if (!mounted || !(_formKey.currentState?.validate() ?? false)) return;
    final draft = _draft();
    try {
      await widget.viewModel.saveSettings(draft);
      if (mounted && draft.apiKeyChanged && draft.apiKey == _apiKey.text) {
        _apiKeyDirty = false;
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('设置保存失败（${error.runtimeType}）'),
          showCloseIcon: true,
        ),
      );
    }
  }

  Future<void> _run(
    Future<void> Function() action,
    String success, {
    bool validateForm = true,
  }) async {
    if (validateForm && !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString()), showCloseIcon: true),
      );
    }
  }

  Future<void> _testConnection() async {
    final urlError = _validateApiUrl(_apiUrl.text);
    final missingModel = _model.text.trim().isEmpty;
    final missingKey =
        !widget.viewModel.settings.hasApiKey && _apiKey.text.trim().isEmpty;
    if (urlError != null || missingModel || missingKey) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写有效的 API 配置')));
      return;
    }
    await _run(
      () => widget.viewModel.testApiConnection(_draft()),
      '连接成功',
      validateForm: false,
    );
  }

  Future<void> _chooseUserDataDirectory() async {
    try {
      final directory = await widget.viewModel.chooseUserDataDirectory();
      if (!mounted || directory == null || directory.trim().isEmpty) return;
      setState(() => _userDataDirectory.text = directory);
      _saveImmediately();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录选择失败：$error'), showCloseIcon: true),
      );
    }
  }

  Future<void> _openUserDataDirectory() async {
    try {
      await widget.viewModel.openUserDataDirectory(
        _userDataDirectory.text.trim(),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开用户数据目录失败：$error'), showCloseIcon: true),
      );
    }
  }

  Future<void> _confirmClearCachedVideos() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清除缓存视频？'),
        content: const Text('只会删除已经分析完成的 MP4 和对应 JSON。待分析、处理中、失败及可重试数据会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      widget.viewModel.clearCompletedVideos,
      '缓存视频已清除',
      validateForm: false,
    );
  }

  Future<void> _confirmClearManagedLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清理日志？'),
        content: const Text(
          '只会清理当前用户数据目录中的 Qi Day Flow 应用日志、原生采集日志及其轮转备份。其他文件和目录会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(widget.viewModel.clearManagedLogs, '日志已清理', validateForm: false);
  }

  Future<void> _changeLogLevel(AppLogLevel value) async {
    if (value == _logLevel) return;
    final previous = _logLevel;
    setState(() => _logLevel = value);
    try {
      await widget.viewModel.updateLogLevel(value);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _logLevel = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志等级保存失败：$error'), showCloseIcon: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final captureIntervalLocked = vm.recordingStatus.isActive;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('设置', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          _SettingsSaveIndicator(viewModel: vm),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(right: 10, bottom: 28),
              children: [
                _SettingsSection(
                  title: '模型服务',
                  icon: Icons.cloud_outlined,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _apiUrl,
                        onChanged: (_) => _scheduleTextSave(),
                        decoration: const InputDecoration(
                          labelText: 'API URL',
                          hintText: 'https://api.openai.com/v1',
                        ),
                        validator: _validateApiUrl,
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final apiKeyField = TextFormField(
                            key: const ValueKey('settings-api-key'),
                            controller: _apiKey,
                            obscureText: !_showApiKey,
                            enabled: !_loadingApiKey,
                            enableSuggestions: false,
                            autocorrect: false,
                            onChanged: (_) {
                              _apiKeyDirty = true;
                              _scheduleTextSave();
                            },
                            decoration: InputDecoration(
                              labelText: vm.settings.hasApiKey
                                  ? 'API 密钥（已保存）'
                                  : 'API 密钥',
                              helperText: _loadingApiKey
                                  ? '正在读取 Windows DPAPI 加密值'
                                  : _apiKeyLoadFailed
                                  ? '读取失败，可重新输入后保存'
                                  : '由 Windows DPAPI 加密保存',
                              suffixIcon: IconButton(
                                tooltip: _showApiKey ? '隐藏密钥' : '显示密钥',
                                onPressed: () => setState(() {
                                  _showApiKey = !_showApiKey;
                                }),
                                icon: Icon(
                                  _showApiKey
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                            validator: (value) {
                              if (!vm.settings.hasApiKey &&
                                  (value == null || value.isEmpty)) {
                                return '请输入 API 密钥';
                              }
                              return null;
                            },
                          );
                          final modelField = TextFormField(
                            key: const ValueKey('settings-model'),
                            controller: _model,
                            onChanged: (_) => _scheduleTextSave(),
                            decoration: const InputDecoration(
                              labelText: '视觉模型',
                            ),
                            validator: _required,
                          );
                          if (constraints.maxWidth < 520) {
                            return Column(
                              children: [
                                apiKeyField,
                                const SizedBox(height: 12),
                                modelField,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: apiKeyField),
                              const SizedBox(width: 12),
                              Expanded(child: modelField),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: vm.savingSettings ? null : _testConnection,
                          icon: const Icon(Icons.network_check),
                          label: const Text('测试连接'),
                        ),
                      ),
                    ],
                  ),
                ),
                _SettingsSection(
                  title: '采集',
                  icon: Icons.monitor_outlined,
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _userDataDirectory,
                              enabled: !vm.recordingStatus.isActive,
                              onChanged: (_) {
                                setState(() {});
                                _scheduleTextSave();
                              },
                              onFieldSubmitted: (_) => _saveImmediately(),
                              decoration: InputDecoration(
                                labelText: '用户数据目录',
                                prefixIcon: const Icon(Icons.folder_outlined),
                                helperText:
                                    '采集目录：${p.windows.join(_userDataDirectory.text.trim(), 'captures')}',
                              ),
                              validator: _required,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: '选择用户数据目录',
                            child: IconButton.filledTonal(
                              onPressed: vm.recordingStatus.isActive
                                  ? null
                                  : _chooseUserDataDirectory,
                              icon: const Icon(Icons.folder_open),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: '在资源管理器中打开用户数据目录',
                            child: IconButton(
                              key: const ValueKey(
                                'settings-open-user-data-directory',
                              ),
                              onPressed: _openUserDataDirectory,
                              icon: const Icon(Icons.open_in_new),
                            ),
                          ),
                        ],
                      ),
                      if (vm.settings.dataDirectoryRestartRequired) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '数据库将在重启时复制到新目录，日志将在重启后写入新目录；旧缓存和日志保留在原目录。',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Semantics(
                        key: const ValueKey('settings-capture-interval'),
                        container: true,
                        explicitChildNodes: true,
                        label: captureIntervalLocked
                            ? '截图间隔，当前 $_captureIntervalSeconds 秒。录制正在进行，设置已锁定'
                            : '截图间隔，当前 $_captureIntervalSeconds 秒',
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            if (constraints.maxWidth < 420) {
                              return DropdownButtonFormField<int>(
                                initialValue: _captureIntervalSeconds,
                                decoration: const InputDecoration(
                                  labelText: '截图间隔',
                                ),
                                items: AppSettings
                                    .supportedCaptureIntervalSeconds
                                    .map(
                                      (interval) => DropdownMenuItem<int>(
                                        value: interval,
                                        child: Text('$interval 秒'),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: captureIntervalLocked
                                    ? null
                                    : (value) {
                                        if (value == null ||
                                            value == _captureIntervalSeconds) {
                                          return;
                                        }
                                        setState(
                                          () => _captureIntervalSeconds = value,
                                        );
                                        _saveImmediately();
                                      },
                              );
                            }
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: SegmentedButton<int>(
                                segments: AppSettings
                                    .supportedCaptureIntervalSeconds
                                    .map(
                                      (interval) => ButtonSegment<int>(
                                        value: interval,
                                        label: Text('$interval 秒'),
                                      ),
                                    )
                                    .toList(growable: false),
                                selected: <int>{_captureIntervalSeconds},
                                onSelectionChanged: captureIntervalLocked
                                    ? null
                                    : (values) {
                                        final value = values.single;
                                        if (value == _captureIntervalSeconds) {
                                          return;
                                        }
                                        setState(
                                          () => _captureIntervalSeconds = value,
                                        );
                                        _saveImmediately();
                                      },
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          captureIntervalLocked
                              ? '录制期间截图间隔已锁定，停止录制后可更改。'
                              : '频率越低，本地视频体积、CPU 和 AI 候选图片越少，但短暂活动可能不被图像捕获。',
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (!captureIntervalLocked)
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('更改将在下次开始录制时生效。'),
                        ),
                      const SizedBox(height: 16),
                      _SliderSetting(
                        title: '缓存上限',
                        valueText: '$_cacheLimitGb GB',
                        value: _cacheLimitGb.toDouble(),
                        min: 1,
                        max: 50,
                        divisions: 49,
                        onChanged: (value) =>
                            setState(() => _cacheLimitGb = value.round()),
                        onChangeEnd: (_) => _saveImmediately(),
                      ),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('分析完成后继续保留，达到上限后优先删除最旧的已分析视频和 JSON'),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('空闲自动暂停'),
                        value: _idlePauseEnabled,
                        onChanged: (value) {
                          setState(() => _idlePauseEnabled = value);
                          _saveImmediately();
                        },
                      ),
                      if (_idlePauseEnabled)
                        _SliderSetting(
                          title: '空闲阈值',
                          valueText: '$_idleTimeoutMinutes 分钟',
                          value: _idleTimeoutMinutes.toDouble(),
                          min: 1,
                          max: 60,
                          divisions: 59,
                          onChanged: (value) => setState(
                            () => _idleTimeoutMinutes = value.round(),
                          ),
                          onChangeEnd: (_) => _saveImmediately(),
                        ),
                    ],
                  ),
                ),
                _SettingsSection(
                  title: '日志',
                  icon: Icons.receipt_long_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < 520) {
                            return DropdownButtonFormField<AppLogLevel>(
                              key: const ValueKey('settings-log-level'),
                              initialValue: _logLevel,
                              decoration: const InputDecoration(
                                labelText: '日志等级',
                              ),
                              items: AppLogLevel.values
                                  .map(
                                    (level) => DropdownMenuItem(
                                      value: level,
                                      child: Text(level.name.toUpperCase()),
                                    ),
                                  )
                                  .toList(growable: false),
                              onChanged: vm.clearingManagedLogs
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        unawaited(_changeLogLevel(value));
                                      }
                                    },
                            );
                          }
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: SegmentedButton<AppLogLevel>(
                              key: const ValueKey('settings-log-level'),
                              segments: AppLogLevel.values
                                  .map(
                                    (level) => ButtonSegment(
                                      value: level,
                                      label: Text(level.name.toUpperCase()),
                                    ),
                                  )
                                  .toList(growable: false),
                              selected: <AppLogLevel>{_logLevel},
                              onSelectionChanged: vm.clearingManagedLogs
                                  ? null
                                  : (values) => unawaited(
                                      _changeLogLevel(values.single),
                                    ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 18,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _DataValue(
                            label: '日志占用',
                            value: vm.managedLogBytes == null
                                ? '正在计算'
                                : formatBytes(vm.managedLogBytes!),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('settings-clear-managed-logs'),
                            onPressed: vm.clearingManagedLogs
                                ? null
                                : _confirmClearManagedLogs,
                            icon: vm.clearingManagedLogs
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.delete_sweep_outlined),
                            label: Text(
                              vm.clearingManagedLogs ? '正在清理' : '清理日志',
                            ),
                          ),
                        ],
                      ),
                      if (vm.managedLogError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          vm.managedLogError!,
                          key: const ValueKey('settings-managed-log-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _SettingsSection(
                  title: '外观',
                  icon: Icons.contrast,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        style: constraints.maxWidth < 360
                            ? const ButtonStyle(
                                minimumSize: WidgetStatePropertyAll(
                                  Size(48, 40),
                                ),
                                padding: WidgetStatePropertyAll(
                                  EdgeInsets.symmetric(horizontal: 8),
                                ),
                              )
                            : null,
                        segments: constraints.maxWidth < 360
                            ? const [
                                ButtonSegment(
                                  value: ThemeMode.system,
                                  icon: Tooltip(
                                    message: '跟随系统',
                                    child: Icon(Icons.brightness_auto),
                                  ),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.light,
                                  icon: Tooltip(
                                    message: '浅色',
                                    child: Icon(Icons.light_mode_outlined),
                                  ),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.dark,
                                  icon: Tooltip(
                                    message: '深色',
                                    child: Icon(Icons.dark_mode_outlined),
                                  ),
                                ),
                              ]
                            : const [
                                ButtonSegment(
                                  value: ThemeMode.system,
                                  icon: Icon(Icons.brightness_auto),
                                  label: Text('跟随系统'),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.light,
                                  icon: Icon(Icons.light_mode_outlined),
                                  label: Text('浅色'),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.dark,
                                  icon: Icon(Icons.dark_mode_outlined),
                                  label: Text('深色'),
                                ),
                              ],
                        selected: {_themeMode},
                        onSelectionChanged: (values) {
                          setState(() => _themeMode = values.first);
                          _saveImmediately();
                        },
                      ),
                    ),
                  ),
                ),
                _SettingsSection(
                  title: '本地数据',
                  icon: Icons.storage_outlined,
                  child: Wrap(
                    spacing: 28,
                    runSpacing: 10,
                    children: [
                      _DataValue(
                        label: '缓存占用',
                        value: formatBytes(vm.cacheBytes),
                      ),
                      _DataValue(
                        label: '待分析',
                        value: '${vm.pendingChunkCount} 个切片',
                      ),
                      _DataValue(
                        label: '分析失败',
                        value: '${vm.failedChunkCount} 个切片',
                      ),
                      if (vm.failedChunkCount > 0)
                        OutlinedButton.icon(
                          onPressed: vm.retryFailedChunks,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试失败任务'),
                        ),
                      OutlinedButton.icon(
                        key: const ValueKey('settings-clear-cached-videos'),
                        onPressed: _confirmClearCachedVideos,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('清除缓存视频'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String? _required(String? value) {
  return value == null || value.trim().isEmpty ? '此项不能为空' : null;
}

String? _validateApiUrl(String? value) {
  if (value == null || value.trim().isEmpty) return '请输入 API URL';
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return 'API URL 无效';
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    return '请输入 HTTP(S) 地址';
  }
  return null;
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 9),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 13),
          child,
          const SizedBox(height: 22),
          const Divider(),
        ],
      ),
    );
  }
}

class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.title,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String title;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final slider = Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 360) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: Text(title)),
                  Text(valueText, textAlign: TextAlign.right),
                ],
              ),
              slider,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 88, child: Text(title)),
            Expanded(child: slider),
            SizedBox(
              width: 86,
              child: Text(valueText, textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsSaveIndicator extends StatelessWidget {
  const _SettingsSaveIndicator({required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (viewModel.settingsSaveStatus) {
      SettingsSaveStatus.idle => const SizedBox(height: 20),
      SettingsSaveStatus.saving => const SizedBox(
        height: 20,
        child: Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('正在保存'),
          ],
        ),
      ),
      SettingsSaveStatus.saved => SizedBox(
        height: 20,
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: colors.primary),
            const SizedBox(width: 8),
            const Text('已保存'),
          ],
        ),
      ),
      SettingsSaveStatus.error => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 17, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '保存失败：${viewModel.settingsSaveError ?? '请重试'}',
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    };
  }
}

class _DataValue extends StatelessWidget {
  const _DataValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 3),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
