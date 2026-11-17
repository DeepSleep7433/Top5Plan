import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/updates/update_service.dart';
import '../../desktop/desktop_controller.dart';
import '../screens/focus_screen.dart';
import '../screens/issues_screen.dart';
import '../screens/review_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/tasks_screen.dart';
import '../screens/today_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/task_editor.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  final List<Widget?> _pageCache = List<Widget?>.filled(6, null);
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _updateTimer;
  String? _lastPromptedUpdate;

  static const _desktopItems = [
    (Icons.today_outlined, Icons.today, '今日'),
    (Icons.checklist_outlined, Icons.checklist, '待办'),
    (Icons.inbox_outlined, Icons.inbox, '问题箱'),
    (Icons.auto_awesome_outlined, Icons.auto_awesome, '复盘'),
    (Icons.timer_outlined, Icons.timer, '专注'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows) {
        unawaited(ref.read(desktopControllerProvider).initialize());
      }
      unawaited(ref.read(syncServiceProvider).syncNow(silent: true));
      unawaited(ref.read(reminderServiceProvider).rescheduleAll().catchError((_) {}));
      unawaited(_checkForUpdates());
      _updateTimer = Timer.periodic(const Duration(hours: 6), (_) {
        unawaited(_checkForUpdates());
      });
    });
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((e) => e != ConnectivityResult.none);
      if (online) unawaited(ref.read(syncServiceProvider).syncNow(silent: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.cancel();
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(syncServiceProvider).syncNow(silent: true));
      unawaited(_checkForUpdates());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(quickCaptureTickerProvider, (previous, next) {
      if (previous != next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) openTaskEditor(context, ref, initialDueDate: ref.read(todayProvider));
        });
      }
    });
    final wide = MediaQuery.sizeOf(context).width >= 860;
    if (!wide) return _mobile(context);
    return Scaffold(
      body: Row(
        children: [
          _DesktopSidebar(
            index: _index,
            items: _desktopItems,
            onSelect: _select,
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                for (var i = 0; i < _pageCache.length; i++)
                  _pageCache[i] ?? const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageFor(int index) {
    return _pageCache[index] ??= switch (index) {
      0 => TodayScreen(onNavigate: _navigate),
      1 => const TasksScreen(),
      2 => const IssuesScreen(),
      3 => const ReviewScreen(),
      4 => const FocusScreen(),
      5 => const SettingsScreen(),
      _ => const SizedBox.shrink(),
    };
  }

  Future<void> _checkForUpdates() async {
    if (!ref.read(appPreferencesProvider).autoUpdateCheck) return;
    final update = await ref.read(updateProvider.notifier).check();
    if (!mounted || !update.updateAvailable) return;
    final version = update.latest?.version ?? '';
    if (version.isEmpty || version == _lastPromptedUpdate) return;
    _lastPromptedUpdate = version;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('发现 T5 新版本 $version'),
      action: SnackBarAction(label: '查看更新', onPressed: () => _navigate(5)),
    ));
  }

  void _select(int index) {
    if (index >= 0 && index < _pageCache.length) {
      _pageFor(index);
      setState(() => _index = index);
    }
  }

  Widget _mobile(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('T5', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            onPressed: () => _mobileNavigate(5),
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _index.clamp(0, 3),
          children: [
            for (var i = 0; i <= 3; i++)
              _pageCache[i] ?? const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index.clamp(0, 3),
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.checklist_outlined), selectedIcon: Icon(Icons.checklist), label: '待办'),
          NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox), label: '问题箱'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: '复盘'),
        ],
      ),
    );
  }

  void _navigate(int index) {
    final wide = MediaQuery.sizeOf(context).width >= 860;
    if (wide || index < 4) {
      _select(index);
    } else {
      _mobileNavigate(index);
    }
  }

  void _mobileNavigate(int index) {
    if (index == 4 || index == 5) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(index == 4 ? '专注与统计' : '设置'),
            leading: const BackButton(),
          ),
          body: index == 4 ? const FocusScreen() : const SettingsScreen(),
        ),
      ));
    }
  }
}

class _DesktopSidebar extends ConsumerWidget {
  const _DesktopSidebar({
    required this.index,
    required this.items,
    required this.onSelect,
  });
  final int index;
  final List<(IconData, IconData, String)> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 208,
      color: dark ? const Color(0xFF191C21) : const Color(0xFFF8F9FA),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.blue,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: const Text('T5',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  const SizedBox(width: 9),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('T5', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      Text('决策与待办', style: TextStyle(fontSize: 10.5, color: AppColors.muted)),
                    ],
                  ),
                ],
              ),
            ),
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Material(
                  color: index == i
                      ? (dark ? const Color(0xFF27334A) : AppColors.blueSoft)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  child: InkWell(
                    onTap: () => onSelect(i),
                    borderRadius: BorderRadius.circular(9),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                      child: Row(
                        children: [
                          Icon(
                            index == i ? items[i].$2 : items[i].$1,
                            size: 18,
                            color: index == i ? AppColors.blue : AppColors.muted,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            items[i].$3,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: index == i ? FontWeight.w600 : FontWeight.w400,
                              color: index == i ? (dark ? Colors.white : AppColors.blue) : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  const SyncStatusChip(compact: true),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text('本地优先',
                        style: TextStyle(fontSize: 10.5, color: AppColors.muted)),
                  ),
                  IconButton(
                    onPressed: () => onSelect(5),
                    icon: const Icon(Icons.settings_outlined, size: 17),
                    tooltip: '设置',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
