import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'core/api/api_client.dart';
import 'core/db/database.dart';
import 'core/db/repository.dart';
import 'core/export/export_service.dart';
import 'core/notifications/reminder_service.dart';
import 'core/providers.dart';
import 'core/settings/preferences.dart';
import 'core/sync/background_sync.dart';
import 'core/sync/sync_service.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  final prefs = await AppPreferences.load();
  try {
    tz.setLocalLocation(tz.getLocation(prefs.timezone));
  } catch (_) {
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  }
  final db = await openAppDatabase();
  final deviceId = await prefs.ensureDeviceId();
  final token = await prefs.readToken();
  final api = ApiClient(baseUrl: prefs.baseUrl, token: token);
  late SyncService sync;
  final reminder = ReminderService(db, prefs.timezone);
  final repository = TaskRepository(
    db: db,
    deviceId: deviceId,
    onMutation: () {
      sync.requestSyncSoon();
      unawaited(reminder.rescheduleAll().catchError((_) {}));
    },
  );
  sync = SyncService(
    db: db,
    api: api,
    prefs: prefs,
    repository: repository,
    deviceId: deviceId,
  );
  await sync.initialize();
  final exportService = ExportService(db, repository);
  runApp(
    ProviderScope(
      overrides: [
        appPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(api),
        deviceIdProvider.overrideWithValue(deviceId),
        taskRepositoryProvider.overrideWithValue(repository),
        syncServiceProvider.overrideWithValue(sync),
        reminderServiceProvider.overrideWithValue(reminder),
        exportServiceProvider.overrideWithValue(exportService),
      ],
      child: const T5App(),
    ),
  );
  if (Platform.isAndroid && token != null && token.isNotEmpty) {
    unawaited(registerPeriodicBackgroundSync().catchError((_) {}));
  }
}

class T5App extends ConsumerWidget {
  const T5App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'T5 决策与待办',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: mode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      scrollBehavior: const _DesktopScrollBehavior(),
      home: const AppShell(),
    );
  }
}

class _DesktopScrollBehavior extends MaterialScrollBehavior {
  const _DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}
