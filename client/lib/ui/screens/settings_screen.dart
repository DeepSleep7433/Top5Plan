import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide appBuildNumber;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/db/database.dart';
import '../../core/app_info.dart';
import '../../core/providers.dart';
import '../../core/updates/android_apk_installer.dart';
import '../../core/updates/update_service.dart';
import '../../core/sync/entity_codec.dart';
import '../../core/sync/background_sync.dart';
import '../../desktop/desktop_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/reports_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _baseUrl = TextEditingController();
  final _deviceName = TextEditingController();
  final _pairCode = TextEditingController();
  final _dailyLimit = TextEditingController(text: '20');
  final _dailyTime = TextEditingController(text: '21:00');
  final _weeklyTime = TextEditingController(text: '21:30');
  final _excludedIds = TextEditingController();
  final _hotkey = TextEditingController();
  bool _paired = false;
  bool _busy = false;
  bool _dailyEnabled = false;
  bool _weeklyEnabled = false;
  String _timezone = 'Asia/Shanghai';
  List<String> _excludedLists = [];
  List<Map<String, dynamic>> _configs = [];
  String? _defaultConfig;
  String? _errorMessage;
  int _focusMinutes = 25;
  int _shortBreak = 5;
  int _longBreak = 15;
  int _longBreakEvery = 4;
  bool _autoStart = false;
  bool _syncPaused = false;
  bool _autoUpdateCheck = true;
  bool _installingApk = false;
  double _apkProgress = 0;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(appPreferencesProvider);
    _baseUrl.text = prefs.baseUrl;
    _deviceName.text = prefs.deviceName;
    _hotkey.text = prefs.hotkey;
    _timezone = prefs.timezone;
    _focusMinutes = prefs.focusMinutes;
    _shortBreak = prefs.shortBreakMinutes;
    _longBreak = prefs.longBreakMinutes;
    _longBreakEvery = prefs.longBreakEvery;
    _autoStart = prefs.autoStart;
    _syncPaused = prefs.syncPaused;
    _autoUpdateCheck = prefs.autoUpdateCheck;
    Future.microtask(_init);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _deviceName.dispose();
    _pairCode.dispose();
    _dailyLimit.dispose();
    _dailyTime.dispose();
    _weeklyTime.dispose();
    _excludedIds.dispose();
    _hotkey.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final token = await ref.read(appPreferencesProvider).readToken();
    if (mounted) setState(() => _paired = token != null && token.isNotEmpty);
    await _loadRemote();
  }

  Future<void> _loadRemote() async {
    if (!_paired) return;
    try {
      final api = ref.read(apiClientProvider);
      final remote = await api.getSettings();
      final configs = await api.listAIConfigs();
      if (!mounted) return;
      final s = remote['settings'] as Map<String, dynamic>? ?? {};
      setState(() {
        _timezone = remote['timezone']?.toString() ?? ref.read(appPreferencesProvider).timezone;
        _dailyLimit.text = (s['ai_daily_limit'] ?? 20).toString();
        _dailyEnabled = s['daily_report_enabled'] == true;
        _weeklyEnabled = s['weekly_report_enabled'] == true;
        _dailyTime.text = s['daily_report_time']?.toString() ?? '21:00';
        _weeklyTime.text = s['weekly_report_time']?.toString() ?? '21:30';
        _excludedLists = ((s['excluded_lists'] as List?) ?? const []).map((e) => e.toString()).toList();
        _excludedIds.text = ((s['excluded_entity_ids'] as List?) ?? const []).join(', ');
        _defaultConfig = s['default_ai_config_id']?.toString();
        _configs = ((configs['configs'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _errorMessage = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.isUnauthorized ? '设备令牌已失效，请重新配对' : e.message);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = ref.watch(conflictsProvider).value ?? [];
    final theme = ref.watch(themeModeProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设置', style: Theme.of(context).textTheme.headlineLarge),
                  const SizedBox(height: 3),
                  Text('同步、AI、外观与本地数据',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted)),
                ],
              ),
            ),
            const SyncStatusChip(),
          ],
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(_errorMessage!, style: const TextStyle(fontSize: 12, color: AppColors.danger)),
          ),
        ],
        const SizedBox(height: 16),
        _Section(
          title: '服务器与配对',
          icon: Icons.cloud_outlined,
          children: [
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://your-server.example.com',
                helperText: '生产环境必须使用 HTTPS；客户端不会直接连接 MySQL',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _deviceName,
              decoration: const InputDecoration(labelText: '本设备名称'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pairCode,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '6 位一次性绑定码',
                      hintText: '30 秒有效，需要时再生成',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _pair,
                  child: const Text('配对'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _paired && !_busy ? _syncNow : null,
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('立即同步'),
                ),
                OutlinedButton.icon(
                  onPressed: _paired ? _togglePause : null,
                  icon: Icon(_syncPaused ? Icons.play_arrow : Icons.pause, size: 16),
                  label: Text(_syncPaused ? '恢复同步' : '暂停同步'),
                ),
                if (_paired)
                  OutlinedButton.icon(
                    onPressed: _showPairingCode,
                    icon: const Icon(Icons.pin_outlined, size: 16),
                    label: const Text('生成 30 秒绑定码'),
                  ),
                if (_paired)
                  TextButton.icon(
                    onPressed: _manageDevices,
                    icon: const Icon(Icons.devices_outlined, size: 16),
                    label: const Text('设备管理'),
                  ),
                if (_paired)
                  TextButton.icon(
                    onPressed: _unpair,
                    icon: const Icon(Icons.link_off, size: 16),
                    label: const Text('解除本机令牌'),
                    style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                  ),
              ],
            ),
            if (_paired)
              Text('设备令牌保存在操作系统安全存储中。',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ],
        ),
        const SizedBox(height: 14),
        _Section(
          title: '应用更新',
          icon: Icons.system_update_alt,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('当前版本 v$appVersion (build $appBuildNumber)',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                      Text(
                        '服务器发布新版本后，应用会在启动、恢复前台及每 6 小时检查并提示；也可手动检查。',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _checkingUpdate ? null : _checkUpdates,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(_checkingUpdate ? '检查中…' : '检查更新'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('接收云端更新提示'),
              subtitle: const Text('仅检查版本公告，不自动下载或安装'),
              value: _autoUpdateCheck,
              onChanged: _setAutoUpdateCheck,
            ),
            _UpdateResult(
              state: ref.watch(updateProvider),
              installingApk: _installingApk,
              apkProgress: _apkProgress,
              onOpenDownload: _openUpdateDownload,
              onInstallAndroid: _installAndroidUpdate,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Section(
          title: '账户时区与复盘调度',
          icon: Icons.schedule_outlined,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _timezone,
              decoration: const InputDecoration(
                labelText: '账户时区',
                helperText: '修改时区不会自动迁移已有每日记录的业务日期',
              ),
              items: [
                for (final tz in [
                  'Asia/Shanghai',
                  'Asia/Hong_Kong',
                  'Asia/Tokyo',
                  'Asia/Singapore',
                  'Europe/London',
                  'America/New_York',
                  'America/Los_Angeles',
                  'UTC',
                  if (![
                    'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Tokyo', 'Asia/Singapore',
                    'Europe/London', 'America/New_York', 'America/Los_Angeles', 'UTC'
                  ].contains(_timezone))
                    _timezone,
                ])
                  DropdownMenuItem(value: tz, child: Text(tz)),
              ],
              onChanged: _paired ? (v) => setState(() => _timezone = v ?? _timezone) : null,
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('每日自动复盘'),
              subtitle: const Text('服务器在设定时间生成；设备关机也会执行'),
              value: _dailyEnabled,
              onChanged: _paired ? (v) => setState(() => _dailyEnabled = v) : null,
            ),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _dailyTime,
                enabled: _paired,
                decoration: const InputDecoration(labelText: '日报时间 HH:MM'),
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('每周自动复盘'),
              subtitle: const Text('默认周日 21:30；只补最近一个错过的周期'),
              value: _weeklyEnabled,
              onChanged: _paired ? (v) => setState(() => _weeklyEnabled = v) : null,
            ),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _weeklyTime,
                enabled: _paired,
                decoration: const InputDecoration(labelText: '周报时间 HH:MM'),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _dailyLimit,
              enabled: _paired,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '每日 AI 调用上限'),
            ),
            const SizedBox(height: 10),
            Text('发送范围排除项',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              children: [
                for (final l in ref.watch(listsProvider).value ?? [])
                  FilterChip(
                    selected: _excludedLists.contains(l.id),
                    label: Text(l.name),
                    onSelected: _paired
                        ? (v) => setState(() {
                              if (v) {
                                _excludedLists.add(l.id);
                              } else {
                                _excludedLists.remove(l.id);
                              }
                            })
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _excludedIds,
              enabled: _paired,
              decoration: const InputDecoration(
                labelText: '排除记录 ID（逗号分隔，可选）',
                helperText: '自动报告只使用已经同步到服务器的授权记录',
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: _defaultConfig,
              decoration: const InputDecoration(labelText: '默认 AI 配置'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('自动选择第一个启用配置')),
                for (final c in _configs)
                  DropdownMenuItem<String?>(value: c['id']?.toString(), child: Text(c['name']?.toString() ?? '配置')),
              ],
              onChanged: _paired ? (v) => setState(() => _defaultConfig = v) : null,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy || !_paired ? null : _saveRemote,
                child: const Text('保存服务器设置'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Section(
          title: 'AI 模型配置',
          icon: Icons.auto_awesome_outlined,
          children: [
            if (!_paired)
              const Text('配对服务器后可配置模型。未配置 AI 时，待办、记录与专注仍可正常使用。',
                  style: TextStyle(fontSize: 12, color: AppColors.muted))
            else ...[
              for (final c in _configs)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(c['enabled'] == true ? Icons.check_circle : Icons.pause_circle_outline,
                          size: 17, color: c['enabled'] == true ? AppColors.success : AppColors.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c['name']?.toString() ?? 'AI 配置',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                            Text('${c['model']} · ${c['base_url']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _testExistingConfig(c['id'].toString()),
                        child: const Text('测试'),
                      ),
                      IconButton(
                        onPressed: () => _editConfig(c),
                        icon: const Icon(Icons.edit_outlined, size: 17),
                      ),
                      IconButton(
                        onPressed: () => _deleteConfig(c['id'].toString()),
                        icon: const Icon(Icons.delete_outline, size: 17),
                      ),
                    ],
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _addConfig,
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('添加模型配置'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showReports,
                    icon: const Icon(Icons.article_outlined, size: 17),
                    label: const Text('查看自动复盘报告'),
                  ),
                ],
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        _Section(
          title: '冲突处理',
          icon: Icons.call_merge,
          children: [
            if (conflicts.isEmpty)
              const Text('没有待处理冲突。冲突时双方内容都会保留，不会静默覆盖。',
                  style: TextStyle(fontSize: 12, color: AppColors.muted))
            else
              for (final c in conflicts)
                _ConflictRow(conflict: c),
          ],
        ),
        const SizedBox(height: 14),
        _Section(
          title: '外观与专注',
          icon: Icons.palette_outlined,
          children: [
            DropdownButtonFormField<ThemeMode>(
              initialValue: theme,
              decoration: const InputDecoration(labelText: '主题'),
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
              ],
              onChanged: (v) => ref.read(themeModeProvider.notifier).setMode(v ?? ThemeMode.system),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _NumberField(label: '专注分钟', value: _focusMinutes, onChanged: (v) => setState(() => _focusMinutes = v))),
                const SizedBox(width: 8),
                Expanded(child: _NumberField(label: '短休息', value: _shortBreak, onChanged: (v) => setState(() => _shortBreak = v))),
                const SizedBox(width: 8),
                Expanded(child: _NumberField(label: '长休息', value: _longBreak, onChanged: (v) => setState(() => _longBreak = v))),
                const SizedBox(width: 8),
                Expanded(child: _NumberField(label: '每几次长休息', value: _longBreakEvery, onChanged: (v) => setState(() => _longBreakEvery = v))),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(onPressed: _saveLocalFocus, child: const Text('保存本地偏好')),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Section(
          title: '清单与标签',
          icon: Icons.label_outline,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final l in ref.watch(listsProvider).value ?? [])
                  Chip(label: Text(l.name)),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 15),
                  label: const Text('新建清单'),
                  onPressed: _addList,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in ref.watch(tagsProvider).value ?? [])
                  Chip(label: Text(t.name)),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 15),
                  label: const Text('新建标签'),
                  onPressed: _addTag,
                ),
              ],
            ),
          ],
        ),
        if (Platform.isWindows) ...[
          const SizedBox(height: 14),
          _Section(
            title: 'Windows 桌面',
            icon: Icons.desktop_windows_outlined,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开机启动'),
                subtitle: const Text('默认关闭；开启后随 Windows 登录启动'),
                value: _autoStart,
                onChanged: _setAutoStart,
              ),
              TextField(
                controller: _hotkey,
                decoration: const InputDecoration(
                  labelText: '全局快速记录快捷键',
                  hintText: '例如 ctrl+alt+t',
                  helperText: '若被其他应用占用，会保留原快捷键并提示',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _saveHotkey, child: const Text('应用快捷键')),
              const SizedBox(height: 8),
              const Text('关闭主窗口后默认驻留托盘；从托盘菜单可彻底退出。',
                  style: TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _Section(
          title: '本地数据与导出',
          icon: Icons.save_alt_outlined,
          children: [
            const Text('第一版通过操作系统文件权限保护本地 SQLite；不宣称端到端加密或全盘加密。',
                style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _exportJson,
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: const Text('完整 JSON 导出'),
                ),
                OutlinedButton.icon(
                  onPressed: _exportMarkdown,
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: const Text('Markdown 记录导出'),
                ),
                OutlinedButton.icon(
                  onPressed: _importJson,
                  icon: const Icon(Icons.file_upload_outlined, size: 16),
                  label: const Text('JSON 恢复导入'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Center(
          child: Text('T5 · 本地优先 · 单人使用', style: TextStyle(fontSize: 11, color: AppColors.muted)),
        ),
      ],
    );
  }

  bool get _checkingUpdate => ref.watch(updateProvider).checking;

  Future<void> _checkUpdates() async {
    final state = await ref.read(updateProvider.notifier).check(force: true);
    if (!mounted) return;
    if (state.error != null) {
      await showError(context, state.error!);
    } else if (state.updateAvailable) {
      await showNotice(context, '发现新版本 ${state.latest?.version ?? ''}');
    } else {
      await showNotice(context, '当前已是最新版本');
    }
  }

  Future<void> _setAutoUpdateCheck(bool value) async {
    ref.read(appPreferencesProvider).autoUpdateCheck = value;
    setState(() => _autoUpdateCheck = value);
  }

  Future<void> _installAndroidUpdate() async {
    final release = ref.read(updateProvider).latest;
    if (release == null || _installingApk) return;
    setState(() {
      _installingApk = true;
      _apkProgress = 0;
    });
    try {
      final result = await AndroidApkInstaller().downloadAndInstall(
        release,
        onProgress: (value) {
          if (mounted) setState(() => _apkProgress = value);
        },
      );
      if (!mounted) return;
      await showNotice(
        context,
        result.permissionRequired
            ? '已打开“安装未知应用”设置；允许 T5 后返回，再点击“下载并安装”'
            : 'APK 已校验并调起系统安装器',
      );
    } on ApkUpdateException catch (e) {
      if (mounted) await showError(context, e.message);
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => _installingApk = false);
    }
  }

  Future<void> _openUpdateDownload() async {
    final url = ref.read(updateProvider).latest?.downloadUrl;
    if (url == null || url.isEmpty) return;
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) await showError(context, '无法打开下载页面');
  }

  Future<void> _pair() async {
    final base = _baseUrl.text.trim();
    final code = _pairCode.text.trim();
    if (base.isEmpty || code.isEmpty) {
      setState(() => _errorMessage = '请填写服务器地址和配对码');
      return;
    }
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final prefs = ref.read(appPreferencesProvider);
      prefs.baseUrl = base;
      prefs.deviceName = _deviceName.text;
      final api = ref.read(apiClientProvider)..baseUrl = base;
      final result = await api.pair(
        pairingToken: code,
        deviceName: _deviceName.text.trim().isEmpty ? 'T5 device' : _deviceName.text.trim(),
        platform: Platform.isWindows ? 'windows' : 'android',
      );
      final token = result['device_token']?.toString() ?? '';
      await prefs.writeToken(token);
      api.token = token;
      if (Platform.isAndroid) {
        await registerPeriodicBackgroundSync();
      }
      setState(() {
        _paired = true;
        _pairCode.clear();
      });
      await ref.read(syncServiceProvider).syncNow();
      await _loadRemote();
      if (mounted) await showNotice(context, '配对成功，已开始同步');
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除本机令牌？'),
        content: const Text('本地数据会保留。再次同步需要重新配对。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('解除')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(appPreferencesProvider).clearToken();
    ref.read(apiClientProvider).token = null;
    setState(() => _paired = false);
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final snap = await ref.read(syncServiceProvider).syncNow();
    if (!mounted) return;
    setState(() => _busy = false);
    await showNotice(context, snap.lastError ?? '同步完成');
  }

  Future<void> _togglePause() async {
    final next = !_syncPaused;
    final prefs = ref.read(appPreferencesProvider);
    prefs.syncPaused = next;
    ref.read(syncServiceProvider).setPaused(next);
    setState(() => _syncPaused = next);
  }

  Future<void> _showPairingCode() async {
    await showDialog<void>(
      context: context,
      builder: (context) => const _PairingCodeDialog(),
    );
  }

  Future<void> _manageDevices() async {
    try {
      final result = await ref.read(apiClientProvider).listDevices();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) {
          final devices = ((result['devices'] as List?) ?? const [])
              .cast<Map<String, dynamic>>();
          return AlertDialog(
            title: const Text('已配对设备'),
            content: SizedBox(
              width: 520,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final d in devices)
                    ListTile(
                      leading: Icon(d['platform'] == 'windows'
                          ? Icons.desktop_windows_outlined
                          : Icons.phone_android),
                      title: Text(d['name']?.toString() ?? '设备'),
                      subtitle: Text(
                        '${d['platform']} · ${d['revoked_at'] == null ? '有效' : '已撤销'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: d['revoked_at'] == null
                          ? TextButton(
                              onPressed: () async {
                                await ref.read(apiClientProvider).revokeDevice(d['id'].toString());
                                if (context.mounted) Navigator.pop(context);
                              },
                              child: const Text('撤销'),
                            )
                          : null,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _showReports() async {
    await showDialog<void>(context: context, builder: (context) => const ReportsDialog());
  }

  Future<void> _saveRemote() async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final settings = {
        'ai_daily_limit': int.tryParse(_dailyLimit.text) ?? 20,
        'daily_report_enabled': _dailyEnabled,
        'daily_report_time': _dailyTime.text,
        'weekly_report_enabled': _weeklyEnabled,
        'weekly_report_time': _weeklyTime.text,
        'excluded_lists': _excludedLists,
        'excluded_entity_ids': _excludedIds.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        'default_ai_config_id': _defaultConfig ?? '',
      };
      await ref.read(apiClientProvider).putSettings(_timezone, settings);
      await ref.read(timezoneProvider.notifier).setTimezone(_timezone);
      if (mounted) await showNotice(context, '服务器设置已保存');
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addConfig() async {
    final out = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _AIConfigDialog(),
    );
    if (out == null) return;
    try {
      await ref.read(apiClientProvider).createAIConfig(out);
      await _loadRemote();
    } on ApiException catch (e) {
      if (mounted) await showError(context, e.message);
    }
  }

  Future<void> _editConfig(Map<String, dynamic> cfg) async {
    final out = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _AIConfigDialog(existing: cfg),
    );
    if (out == null) return;
    try {
      await ref.read(apiClientProvider).updateAIConfig(cfg['id'].toString(), out);
      await _loadRemote();
    } on ApiException catch (e) {
      if (mounted) await showError(context, e.message);
    }
  }

  Future<void> _deleteConfig(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型配置？'),
        content: const Text('历史 AI 结果和报告会保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(apiClientProvider).deleteAIConfig(id);
    await _loadRemote();
  }

  Future<void> _testExistingConfig(String id) async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final result = await ref.read(apiClientProvider).testAIConfig(id);
      if (mounted) Navigator.pop(context);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(result['ok'] == true ? '连接成功' : '连接失败'),
          content: Text(
            result['ok'] == true
                ? '真实模型调用成功。\n模型：${result['model']}\n返回：${result['sample'] ?? ''}'
                : '${result['code'] ?? 'provider_error'}：${result['message'] ?? ''}',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
        ),
      );
    } catch (e) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _addList() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建清单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '清单名称'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('创建')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await ref.read(taskRepositoryProvider).createList(name.trim());
    }
  }

  Future<void> _addTag() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '标签名称'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('创建')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await ref.read(taskRepositoryProvider).createTag(name.trim());
    }
  }

  Future<void> _saveLocalFocus() async {
    final prefs = ref.read(appPreferencesProvider);
    prefs.focusMinutes = _focusMinutes;
    prefs.shortBreakMinutes = _shortBreak;
    prefs.longBreakMinutes = _longBreak;
    prefs.longBreakEvery = _longBreakEvery;
    if (mounted) await showNotice(context, '本地专注偏好已保存');
  }

  Future<void> _setAutoStart(bool value) async {
    try {
      await ref.read(desktopControllerProvider).setAutoStart(value);
      ref.read(appPreferencesProvider).autoStart = value;
      setState(() => _autoStart = value);
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _saveHotkey() async {
    final key = _hotkey.text.trim();
    if (key.isEmpty) return;
    try {
      await ref.read(desktopControllerProvider).registerHotkey(key);
      ref.read(appPreferencesProvider).hotkey = key;
      if (mounted) await showNotice(context, '全局快捷键已注册');
    } catch (e) {
      if (mounted) await showError(context, '快捷键注册失败：$e');
    }
  }

  Future<void> _exportJson() async {
    try {
      final path = await ref.read(exportServiceProvider).exportJson();
      if (path != null && mounted) await showNotice(context, '已导出到 $path');
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _exportMarkdown() async {
    try {
      final path = await ref.read(exportServiceProvider).exportMarkdown();
      if (path != null && mounted) await showNotice(context, '已导出到 $path');
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _importJson() async {
    try {
      final picked = await ref.read(exportServiceProvider).pickImport();
      if (picked == null || !mounted) return;
      final preview = ref.read(exportServiceProvider).preview(picked.$2, picked.$1.path);
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入预览'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文件：${preview.fileName}'),
                if (preview.exportedAt != null) Text('导出时间：${preview.exportedAt}'),
                const SizedBox(height: 10),
                for (final e in preview.counts.entries) Text('${e.key}: ${e.value} 条'),
                const SizedBox(height: 10),
                const Text('导入会为所有记录创建新 ID，不会覆盖现有数据；随后进入同步队列。',
                    style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认导入')),
          ],
        ),
      );
      if (ok != true) return;
      final count = await ref.read(exportServiceProvider).importAsNew(picked.$2);
      await ref.read(syncServiceProvider).syncNow();
      if (mounted) await showNotice(context, '已导入 $count 条记录');
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }
}

class _UpdateResult extends StatelessWidget {
  const _UpdateResult({
    required this.state,
    required this.installingApk,
    required this.apkProgress,
    required this.onOpenDownload,
    required this.onInstallAndroid,
  });
  final UpdateState state;
  final bool installingApk;
  final double apkProgress;
  final VoidCallback onOpenDownload;
  final VoidCallback onInstallAndroid;

  @override
  Widget build(BuildContext context) {
    if (state.checking) {
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('检查更新失败：${state.error}',
            style: const TextStyle(fontSize: 11.5, color: AppColors.warning)),
      );
    }
    if (!state.checked) return const SizedBox.shrink();
    if (!state.updateAvailable) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          state.lastCheckedAt == null
              ? '尚未检查'
              : '已是最新版本 · ${state.lastCheckedAt!.toLocal()}',
          style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
        ),
      );
    }
    final release = state.latest!;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppColors.blueSoft,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.new_releases_outlined, size: 17, color: AppColors.blue),
              const SizedBox(width: 6),
              Expanded(
                child: Text('新版本 v${release.version}${release.mandatory ? ' · 重要更新' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
              ),
              if (Platform.isAndroid)
                FilledButton.icon(
                  onPressed: installingApk ? null : onInstallAndroid,
                  icon: const Icon(Icons.system_update_alt, size: 16),
                  label: Text(installingApk ? '下载中…' : '下载并安装'),
                )
              else
                TextButton.icon(
                  onPressed: onOpenDownload,
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('打开下载'),
                ),
            ],
          ),
          if (release.releaseNotes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(release.releaseNotes,
                  style: const TextStyle(fontSize: 11.5, height: 1.45)),
            ),
          if (release.sha256.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: SelectableText('SHA-256: ${release.sha256}',
                  style: const TextStyle(fontSize: 10, fontFamily: 'Consolas', color: AppColors.muted)),
            ),
          if (Platform.isAndroid && installingApk)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: LinearProgressIndicator(
                value: apkProgress <= 0 ? null : apkProgress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          if (Platform.isAndroid)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                'APK 会先校验公告中的 SHA-256，再调起系统安装器；需要允许 T5 安装未知应用。',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _PairingCodeDialog extends ConsumerStatefulWidget {
  const _PairingCodeDialog();
  @override
  ConsumerState<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends ConsumerState<_PairingCodeDialog> {
  String? _code;
  int _remaining = 0;
  String? _error;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _requestCode();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining > 0) {
        setState(() => _remaining--);
      } else if (!_loading) {
        _requestCode();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final out = await ref.read(apiClientProvider).createPairingCode();
      if (!mounted) return;
      final seconds = (out['expires_in_seconds'] as num?)?.toInt() ?? 30;
      setState(() {
        _code = out['pairing_code']?.toString();
        _remaining = seconds.clamp(1, 60);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final spaced = code == null || code.length != 6
        ? '------'
        : '${code.substring(0, 3)} ${code.substring(3)}';
    return AlertDialog(
      title: const Text('临时绑定码'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              spaced,
              style: const TextStyle(
                fontSize: 42,
                fontWeight: FontWeight.w700,
                letterSpacing: 5,
                fontFamily: 'Consolas',
              ),
            ),
            const SizedBox(height: 5),
            Text(
              _error ?? (_code == null ? '正在申请…' : '$_remaining 秒后自动轮换'),
              style: TextStyle(
                fontSize: 12,
                color: _error == null ? AppColors.muted : AppColors.danger,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '在另一台设备的服务器配对框输入此 6 位码。码只在此弹窗打开期间申请，关闭后不再刷新；旧码会被新码作废。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, height: 1.45),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: code == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('绑定码已复制')),
                    );
                  }
                },
          child: const Text('复制'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.blue),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 13),
          ...children,
        ],
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: value.toString(),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (v) {
        final n = int.tryParse(v);
        if (n != null) onChanged(n);
      },
    );
  }
}

class _ConflictRow extends ConsumerWidget {
  const _ConflictRow({required this.conflict});
  final ConflictCopy conflict;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${conflict.entityType} · ${conflict.entityId.substring(0, 8)}…',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text('服务端版本 ${conflict.serverVersion} · ${conflict.createdAt.toLocal()}',
              style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            children: [
              OutlinedButton(
                onPressed: () => ref.read(syncServiceProvider).resolveKeepLocal(conflict),
                child: const Text('保留本地'),
              ),
              OutlinedButton(
                onPressed: () => ref.read(syncServiceProvider).resolveKeepCloud(conflict),
                child: const Text('保留云端'),
              ),
              OutlinedButton(
                onPressed: () => _manualMerge(context, ref),
                child: const Text('手动合并'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _manualMerge(BuildContext context, WidgetRef ref) async {
    final local = decodeJsonObject(conflict.localJson);
    final server = decodeJsonObject(conflict.serverJson);
    final controller = TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(local));
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动合并'),
        content: SizedBox(
          width: 700,
          height: 520,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('本地内容（可编辑为合并结果）',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        expands: true,
                        maxLines: null,
                        style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                        decoration: const InputDecoration(fillColor: Color(0xFFF7F8FA)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('服务端内容（只读）',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ').convert(server),
                            style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('提交合并结果')),
        ],
      ),
    );
    if (result != true) return;
    try {
      final merged = jsonDecode(controller.text);
      if (merged is! Map<String, dynamic>) throw const FormatException('必须是 JSON 对象');
      await ref.read(syncServiceProvider).resolveManual(conflict, merged);
    } catch (e) {
      if (context.mounted) await showError(context, e);
    }
    controller.dispose();
  }
}

class _AIConfigDialog extends StatefulWidget {
  const _AIConfigDialog({this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<_AIConfigDialog> createState() => _AIConfigDialogState();
}

class _AIConfigDialogState extends State<_AIConfigDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _key;
  late final TextEditingController _timeout;
  late final TextEditingController _maxTokens;
  bool _enabled = true;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?['name']?.toString() ?? '');
    _baseUrl = TextEditingController(text: e?['base_url']?.toString() ?? 'https://api.deepseek.com/v1');
    _model = TextEditingController(text: e?['model']?.toString() ?? 'deepseek-chat');
    _key = TextEditingController();
    _timeout = TextEditingController(text: (e?['timeout_seconds'] ?? 120).toString());
    _maxTokens = TextEditingController(text: (e?['max_output_tokens'] ?? 2000).toString());
    _enabled = e?['enabled'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _timeout.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _payload => {
        'name': _name.text.trim(),
        'base_url': _baseUrl.text.trim(),
        'model': _model.text.trim(),
        'api_key': _key.text.trim(),
        'timeout_seconds': int.tryParse(_timeout.text) ?? 120,
        'max_output_tokens': int.tryParse(_maxTokens.text) ?? 2000,
        'enabled': _enabled,
      };

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? '编辑 AI 配置' : '添加 AI 配置'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: '配置名称')),
              const SizedBox(height: 8),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.deepseek.com/v1',
                  helperText: 'OpenAI Chat Completions 兼容接口',
                ),
              ),
              const SizedBox(height: 8),
              TextField(controller: _model, decoration: const InputDecoration(labelText: '模型名称')),
              const SizedBox(height: 8),
              TextField(
                controller: _key,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: editing ? 'API Key（留空保留原密钥）' : 'API Key',
                  helperText: '密钥只保存在服务器，使用主密钥加密',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: TextField(controller: _timeout, decoration: const InputDecoration(labelText: '超时秒数'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: _maxTokens, decoration: const InputDecoration(labelText: '最大输出 tokens'))),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用此配置'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              if (_testResult != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.blueSoft,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(_testResult!, style: const TextStyle(fontSize: 11.5)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : _test,
          child: Text(_testing ? '测试中…' : '测试连接'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().isEmpty || _model.text.trim().isEmpty) return;
            if (!editing && _key.text.trim().isEmpty) return;
            Navigator.pop(context, _payload);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final api = ProviderScope.containerOf(context).read(apiClientProvider);
      final result = _key.text.trim().isEmpty && widget.existing != null
          ? await api.testAIConfig(widget.existing!['id'].toString())
          : await api.testAIDraft(_payload);
      setState(() {
        _testResult = result['ok'] == true
            ? '真实调用成功 · 模型 ${result['model']}'
            : '失败：${result['code']} ${result['message'] ?? ''}';
      });
    } catch (e) {
      setState(() => _testResult = '失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }
}

