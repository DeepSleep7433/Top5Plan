import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';

import '../core/providers.dart';

class QuickCaptureTicker extends Notifier<int> {
  @override
  int build() => 0;
  void trigger() => state++;
}

final quickCaptureTickerProvider =
    NotifierProvider<QuickCaptureTicker, int>(QuickCaptureTicker.new, name: 'quickCapture');

final desktopControllerProvider =
    Provider<DesktopController>((ref) => DesktopController(ref));

class DesktopController with WindowListener, TrayListener {
  DesktopController(this.ref);
  final Ref ref;
  bool _initialized = false;
  bool _quitting = false;
  HotKey? _hotkey;
  Timer? _visibilityTimer;
  bool _lastVisible = true;

  Future<void> initialize() async {
    if (_initialized || !Platform.isWindows) return;
    _initialized = true;
    try {
      await windowManager.ensureInitialized();
      const options = WindowOptions(
        size: Size(1280, 820),
        minimumSize: Size(900, 620),
        center: true,
        title: 'T5 决策与待办',
        titleBarStyle: TitleBarStyle.normal,
        backgroundColor: Color(0xFFF3F4F6),
      );
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e) {
      _log('window_manager failed: $e');
    }
    try {
      await _setupTray();
    } catch (e) {
      _log('tray setup failed: $e');
    }
    try {
      launchAtStartup.setup(
        appName: 'T5',
        appPath: Platform.resolvedExecutable,
        packageName: 'com.t5plan.T5Plan',
      );
    } catch (e) {
      _log('launch_at_startup failed: $e');
    }
    try {
      await registerHotkey(ref.read(appPreferencesProvider).hotkey);
    } catch (e) {
      // A user-configured hotkey may be occupied. The app remains usable and
      // the settings page reports the failure on the next attempt.
      _log('hotkey failed: $e');
    }
    _visibilityTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final visible = await windowManager.isVisible();
        if (visible != _lastVisible) {
          _lastVisible = visible;
          ref.read(syncServiceProvider).setBackgroundMode(!visible);
        }
      } catch (_) {}
    });
  }

  void _log(String message) {
    try {
      final base = Platform.environment['LOCALAPPDATA'];
      if (base == null) return;
      final dir = Directory('$base${Platform.pathSeparator}T5Plan');
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}desktop-init.log').writeAsStringSync(
        '${DateTime.now().toUtc().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _setupTray() async {
    trayManager.addListener(this);
    await trayManager.setIcon('assets/tray_icon.png');
    await trayManager.setToolTip('T5 决策与待办');
    await _refreshTrayMenu();
  }

  Future<void> _refreshTrayMenu() async {
    final prefs = ref.read(appPreferencesProvider);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: '打开 T5', onClick: (_) => showWindow()),
      MenuItem(
        key: 'capture',
        label: '快速记录',
        onClick: (_) {
          showWindow();
          ref.read(quickCaptureTickerProvider.notifier).trigger();
        },
      ),
      MenuItem.separator(),
      MenuItem.checkbox(
        key: 'pause',
        label: '暂停同步',
        checked: prefs.syncPaused,
        onClick: (_) async {
          final next = !prefs.syncPaused;
          prefs.syncPaused = next;
          ref.read(syncServiceProvider).setPaused(next);
          await _refreshTrayMenu();
        },
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'exit',
        label: '彻底退出',
        onClick: (_) => _quit(),
      ),
    ]));
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
    ref.read(syncServiceProvider).setBackgroundMode(false);
  }

  Future<void> _quit() async {
    _quitting = true;
    await trayManager.destroy();
    await hotKeyManager.unregisterAll();
    await windowManager.destroy();
    exit(0);
  }

  Future<void> setAutoStart(bool enabled) async {
    if (!Platform.isWindows) return;
    final ok = enabled ? await launchAtStartup.enable() : await launchAtStartup.disable();
    if (!ok) throw StateError('操作系统拒绝修改开机启动设置');
  }

  Future<void> registerHotkey(String spec) async {
    if (!Platform.isWindows) return;
    final parts = spec
        .toLowerCase()
        .split('+')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) throw const FormatException('快捷键不能为空');
    final keyName = parts.removeLast();
    final modifiers = <HotKeyModifier>[];
    for (final p in parts) {
      switch (p) {
        case 'ctrl' || 'control':
          modifiers.add(HotKeyModifier.control);
        case 'alt':
          modifiers.add(HotKeyModifier.alt);
        case 'shift':
          modifiers.add(HotKeyModifier.shift);
        case 'meta' || 'win':
          modifiers.add(HotKeyModifier.meta);
      }
    }
    final key = _keyForName(keyName);
    if (key == null) throw FormatException('不支持的按键：$keyName');
    await hotKeyManager.unregisterAll();
    _hotkey = HotKey(
      identifier: 't5-quick-capture',
      key: key,
      modifiers: modifiers,
      scope: HotKeyScope.system,
    );
    await hotKeyManager.register(
      _hotkey!,
      keyDownHandler: (_) {
        showWindow();
        ref.read(quickCaptureTickerProvider.notifier).trigger();
      },
    );
  }

  static const Map<String, LogicalKeyboardKey> _namedKeys = {
    'a': LogicalKeyboardKey.keyA,
    'b': LogicalKeyboardKey.keyB,
    'c': LogicalKeyboardKey.keyC,
    'd': LogicalKeyboardKey.keyD,
    'e': LogicalKeyboardKey.keyE,
    'f': LogicalKeyboardKey.keyF,
    'g': LogicalKeyboardKey.keyG,
    'h': LogicalKeyboardKey.keyH,
    'i': LogicalKeyboardKey.keyI,
    'j': LogicalKeyboardKey.keyJ,
    'k': LogicalKeyboardKey.keyK,
    'l': LogicalKeyboardKey.keyL,
    'm': LogicalKeyboardKey.keyM,
    'n': LogicalKeyboardKey.keyN,
    'o': LogicalKeyboardKey.keyO,
    'p': LogicalKeyboardKey.keyP,
    'q': LogicalKeyboardKey.keyQ,
    'r': LogicalKeyboardKey.keyR,
    's': LogicalKeyboardKey.keyS,
    't': LogicalKeyboardKey.keyT,
    'u': LogicalKeyboardKey.keyU,
    'v': LogicalKeyboardKey.keyV,
    'w': LogicalKeyboardKey.keyW,
    'x': LogicalKeyboardKey.keyX,
    'y': LogicalKeyboardKey.keyY,
    'z': LogicalKeyboardKey.keyZ,
    '0': LogicalKeyboardKey.digit0,
    '1': LogicalKeyboardKey.digit1,
    '2': LogicalKeyboardKey.digit2,
    '3': LogicalKeyboardKey.digit3,
    '4': LogicalKeyboardKey.digit4,
    '5': LogicalKeyboardKey.digit5,
    '6': LogicalKeyboardKey.digit6,
    '7': LogicalKeyboardKey.digit7,
    '8': LogicalKeyboardKey.digit8,
    '9': LogicalKeyboardKey.digit9,
    'f1': LogicalKeyboardKey.f1,
    'f2': LogicalKeyboardKey.f2,
    'f3': LogicalKeyboardKey.f3,
    'f4': LogicalKeyboardKey.f4,
    'f5': LogicalKeyboardKey.f5,
    'f6': LogicalKeyboardKey.f6,
    'f7': LogicalKeyboardKey.f7,
    'f8': LogicalKeyboardKey.f8,
    'f9': LogicalKeyboardKey.f9,
    'f10': LogicalKeyboardKey.f10,
    'f11': LogicalKeyboardKey.f11,
    'f12': LogicalKeyboardKey.f12,
    'space': LogicalKeyboardKey.space,
    'enter': LogicalKeyboardKey.enter,
    'tab': LogicalKeyboardKey.tab,
    'escape': LogicalKeyboardKey.escape,
    'esc': LogicalKeyboardKey.escape,
  };

  LogicalKeyboardKey? _keyForName(String name) => _namedKeys[name];

  @override
  void onWindowClose() {
    if (_quitting) return;
    unawaited(windowManager.hide());
    ref.read(syncServiceProvider).setBackgroundMode(true);
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {}
}
