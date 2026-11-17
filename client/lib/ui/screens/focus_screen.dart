import 'dart:ui' show FontFeature;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/db/database.dart';
import '../../core/focus/local_focus.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/task_picker.dart';

class FocusScreen extends ConsumerStatefulWidget {
  const FocusScreen({super.key});
  @override
  ConsumerState<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends ConsumerState<FocusScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('专注', style: Theme.of(context).textTheme.headlineLarge),
                    const SizedBox(height: 3),
                    Text('记录实际专注时间；休息与暂停不计入',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.muted)),
                  ],
                ),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('计时')),
                  ButtonSegment(value: 1, label: Text('统计')),
                ],
                selected: {_tab},
                onSelectionChanged: (v) => setState(() => _tab = v.first),
                showSelectedIcon: false,
              ),
            ],
          ),
        ),
        Expanded(child: _tab == 0 ? const _TimerPane() : const FocusStatsPane()),
      ],
    );
  }
}

class _TimerPane extends ConsumerWidget {
  const _TimerPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(localFocusProvider);
    final big = MediaQuery.sizeOf(context).width > 800;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: big
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: _LocalTimerCard(state: local)),
                const SizedBox(width: 16),
                const Expanded(flex: 2, child: _SharedFocusCard()),
              ],
            )
          : Column(
              children: [
                _LocalTimerCard(state: local),
                const SizedBox(height: 14),
                const _SharedFocusCard(),
              ],
            ),
    );
  }
}

class _LocalTimerCard extends ConsumerStatefulWidget {
  const _LocalTimerCard({required this.state});
  final LocalFocusState state;

  @override
  ConsumerState<_LocalTimerCard> createState() => _LocalTimerCardState();
}

class _LocalTimerCardState extends ConsumerState<_LocalTimerCard> {
  Task? _task;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final notifier = ref.read(localFocusProvider.notifier);
    final prefs = ref.read(appPreferencesProvider);
    final progress = s.progress;
    final size = math.min(MediaQuery.sizeOf(context).width * 0.56, 280.0);
    return SectionCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: SectionTitle('本机独立专注', subtitle: '离线可用；结束后上传历史记录'),
              ),
              if (s.active)
                StatusPill(
                  label: s.paused ? '已暂停' : '进行中',
                  color: s.paused ? AppColors.warning : AppColors.success,
                ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: size,
                  height: size,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 8,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _clock(s.remainingSeconds),
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: s.paused ? AppColors.muted : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.active ? (s.paused ? '暂停中' : '保持专注') : '${prefs.focusMinutes} 分钟',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (!s.active && !s.finished)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickTask,
                  icon: const Icon(Icons.link, size: 16),
                  label: Text(_task == null ? '关联任务（可选）' : _task!.title),
                ),
                const SizedBox(height: 9),
                FilledButton.icon(
                  onPressed: () {
                    notifier.start(taskId: _task?.id, label: _task?.title ?? '');
                  },
                  icon: const Icon(Icons.play_arrow, size: 19),
                  label: const Text('开始专注'),
                ),
              ],
            )
          else if (s.finished)
            Column(
              children: [
                const Text('本次专注已结束', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: notifier.dismissFinished,
                  child: const Text('完成'),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: s.paused
                      ? FilledButton.icon(
                          onPressed: notifier.resume,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('继续'),
                        )
                      : OutlinedButton.icon(
                          onPressed: notifier.pause,
                          icon: const Icon(Icons.pause, size: 18),
                          label: const Text('暂停'),
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => notifier.end(),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('提前结束'),
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _pickTask() async {
    final t = await showTaskPicker(context, ref, title: '关联专注任务');
    if (t != null) setState(() => _task = t);
  }

  String _clock(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _SharedFocusCard extends ConsumerStatefulWidget {
  const _SharedFocusCard();
  @override
  ConsumerState<_SharedFocusCard> createState() => _SharedFocusCardState();
}

class _SharedFocusCardState extends ConsumerState<_SharedFocusCard> {
  Map<String, dynamic>? _session;
  DateTime? _lastFetch;
  Timer? _poll;
  Timer? _uiTick;
  bool _loading = false;
  String? _error;
  bool _offline = false;
  String? _taskId;
  String _label = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _uiTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _session != null;
    final deviceId = ref.read(deviceIdProvider);
    final control = _session?['control_device_id'] == deviceId;
    final state = _session?['state']?.toString();
    final remaining = _estimatedRemaining();
    final elapsed = _estimatedElapsed();
    return SectionCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: SectionTitle('跨设备专注', subtitle: '控制权需要联网确认'),
              ),
              IconButton(
                onPressed: _loading ? null : _refresh,
                icon: _loading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!active) ...[
            const Text('没有正在进行的共享计时。',
                style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickTask,
              icon: const Icon(Icons.link, size: 16),
              label: Text(_taskId == null ? '关联任务（可选）' : '已关联任务'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _loading ? null : _startShared,
              icon: const Icon(Icons.group_work_outlined, size: 17),
              label: const Text('开始共享计时'),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: state == 'paused' ? AppColors.warning.withValues(alpha: 0.08) : AppColors.blueSoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Column(
                children: [
                  Text(
                    _clock(remaining),
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    state == 'paused' ? '已暂停' : '运行中',
                    style: TextStyle(
                      fontSize: 12,
                      color: state == 'paused' ? AppColors.warning : AppColors.blue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    control ? '本机持有控制权' : '另一台设备正在控制',
                    style: const TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                  if (_offline)
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Text('网络中断：仅显示预计剩余时间，控制操作需联网确认',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 10.5, color: AppColors.warning)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (!control)
              FilledButton(
                onPressed: _offline ? null : _takeover,
                child: const Text('在此设备继续'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: state == 'paused'
                        ? FilledButton(onPressed: _offline ? null : _resume, child: const Text('继续'))
                        : OutlinedButton(onPressed: _offline ? null : _pause, child: const Text('暂停')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _offline ? null : _end,
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                      child: const Text('结束'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 6),
            Text('已专注 ${_clock(elapsed)} · 版本 ${_session?['version']}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 9),
            Text(_error!, style: const TextStyle(fontSize: 11, color: AppColors.danger)),
          ],
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref.read(apiClientProvider).focusCurrent();
      if (!mounted) return;
      final session = response['session'] as Map<String, dynamic>?;
      setState(() {
        _session = session;
        _lastFetch = DateTime.now();
        _offline = false;
      });
      _schedulePoll(session != null);
      _scheduleUiTick(session != null);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _offline = true;
        _error = e.isUnauthorized ? '请先在设置中配对服务器' : e.message;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _offline = true;
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _schedulePoll(bool active) {
    _poll?.cancel();
    if (!active) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _pollOnce());
  }

  void _scheduleUiTick(bool active) {
    _uiTick?.cancel();
    _uiTick = null;
    if (!active) return;
    _uiTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _session != null) setState(() {});
    });
  }

  Future<void> _pollOnce() async {
    try {
      final response = await ref.read(apiClientProvider).focusCurrent();
      if (!mounted) return;
      final session = response['session'] as Map<String, dynamic>?;
      setState(() {
        _session = session;
        _lastFetch = DateTime.now();
        _offline = false;
        _error = null;
      });
      _schedulePoll(session != null);
      _scheduleUiTick(session != null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _offline = true;
          _error = '刷新失败：$e';
        });
      }
    }
  }

  int _estimatedElapsed() {
    if (_session == null) return 0;
    var elapsed = (_session!['elapsed_ms'] as num?)?.toInt() ?? 0;
    final state = _session!['state']?.toString();
    if (state == 'running' && _lastFetch != null) {
      elapsed += DateTime.now().difference(_lastFetch!).inMilliseconds;
    }
    return elapsed ~/ 1000;
  }

  int _estimatedRemaining() {
    final target = ((_session?['target_seconds'] as num?)?.toInt() ?? 0) * 1000;
    return math.max(0, target - _estimatedElapsed() * 1000) ~/ 1000;
  }

  String _clock(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  Future<void> _startShared() async {
    setState(() => _loading = true);
    try {
      final response = await ref.read(apiClientProvider).focusCommand({
        'action': 'start',
        'expected_version': 0,
        'task_id': _taskId,
        'label': _label,
        'target_seconds': ref.read(appPreferencesProvider).focusMinutes * 60,
      });
      if (!mounted) return;
      setState(() {
        _session = response['session'] as Map<String, dynamic>?;
        _lastFetch = DateTime.now();
        _error = null;
      });
      _schedulePoll(true);
      _scheduleUiTick(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _command(String action) async {
    final version = (_session?['version'] as num?)?.toInt() ?? 0;
    setState(() => _loading = true);
    try {
      final response = await ref.read(apiClientProvider).focusCommand({
        'action': action,
        'expected_version': version,
        'session_id': _session?['id'],
      });
      if (!mounted) return;
      setState(() {
        _session = response['session'] as Map<String, dynamic>?;
        _lastFetch = DateTime.now();
        _error = null;
        _offline = false;
      });
      _schedulePoll(_session != null);
      _scheduleUiTick(_session != null);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
        await _pollOnce();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _takeover() => _command('takeover');
  Future<void> _pause() => _command('pause');
  Future<void> _resume() => _command('resume');
  Future<void> _end() => _command('end');

  Future<void> _pickTask() async {
    final t = await showTaskPicker(context, ref, title: '关联共享专注任务');
    if (t != null) {
      setState(() {
        _taskId = t.id;
        _label = t.title;
      });
    }
  }
}

class FocusStatsPane extends ConsumerStatefulWidget {
  const FocusStatsPane({super.key});
  @override
  ConsumerState<FocusStatsPane> createState() => _FocusStatsPaneState();
}

class _FocusStatsPaneState extends ConsumerState<FocusStatsPane> {
  int _range = 0; // today, week, month
  late Future<List<Map<String, Object?>>> _future;
  late Future<List<Map<String, Object?>>> _taskFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final now = DateTime.now();
    final start = switch (_range) {
      0 => DateTime(now.year, now.month, now.day),
      1 => DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1)),
      _ => DateTime(now.year, now.month, 1),
    };
    final end = switch (_range) {
      0 => start.add(const Duration(days: 1)),
      1 => start.add(const Duration(days: 7)),
      _ => DateTime(now.year, now.month + 1, 1),
    };
    _future = ref.read(taskRepositoryProvider).focusByDay(start, end);
    _taskFuture = ref.read(taskRepositoryProvider).focusByTask(start, end);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final (i, label) in ['今天', '本周', '本月'].indexed)
                ChoiceChip(
                  label: Text(label),
                  selected: _range == i,
                  onSelected: (_) {
                    setState(() {
                      _range = i;
                      _load();
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<Map<String, Object?>>>(
            future: _future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: Padding(padding: EdgeInsets.all(30), child: CircularProgressIndicator(strokeWidth: 2)));
              }
              final rows = snapshot.data!;
              final total = rows.fold<int>(0, (a, r) => a + ((r['seconds'] as num?)?.toInt() ?? 0));
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionTitle('专注总览', subtitle: '重叠区间已去重，不会重复计入'),
                    const SizedBox(height: 15),
                    Text('${total ~/ 3600}h ${(total % 3600) ~/ 60}m',
                        style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    if (rows.isEmpty)
                      const Text('这个区间还没有专注记录',
                          style: TextStyle(fontSize: 12, color: AppColors.muted))
                    else
                      SizedBox(
                        height: 150,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final r in rows)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 3),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text('${(((r['seconds'] as num?)?.toInt() ?? 0) / 60).round()}m',
                                          style: const TextStyle(fontSize: 9, color: AppColors.muted)),
                                      const SizedBox(height: 3),
                                      Container(
                                        height: math.max(
                                            3,
                                            100 *
                                                ((r['seconds'] as num?)?.toInt() ?? 0) /
                                                math.max(1, rows.map((e) => (e['seconds'] as num?)?.toInt() ?? 0).reduce(math.max))),
                                        decoration: BoxDecoration(
                                          color: AppColors.blue,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        (r['day']?.toString() ?? '').substring(5),
                                        style: const TextStyle(fontSize: 9, color: AppColors.muted),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<Map<String, Object?>>>(
            future: _taskFuture,
            builder: (context, snapshot) {
              final rows = snapshot.data ?? [];
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionTitle('按任务', subtitle: '未关联任务的独立专注单独列出'),
                    const SizedBox(height: 10),
                    if (rows.isEmpty)
                      const Text('暂无数据', style: TextStyle(fontSize: 12, color: AppColors.muted))
                    else
                      for (final r in rows)
                        FutureBuilder<Task?>(
                          future: r['task_id'] == null
                              ? Future.value(null)
                              : ref.read(taskRepositoryProvider).getTask(r['task_id'].toString()),
                          builder: (context, taskSnapshot) {
                            final task = taskSnapshot.data;
                            final seconds = (r['seconds'] as num?)?.toInt() ?? 0;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Icon(task == null ? Icons.timer_outlined : Icons.task_alt,
                                      size: 15, color: AppColors.muted),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(task?.title ?? '未关联任务',
                                          style: const TextStyle(fontSize: 12.5))),
                                  Text(formatDuration(seconds),
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            );
                          },
                        ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
