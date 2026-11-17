import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:t5_plan/core/api/api_client.dart';
import 'package:t5_plan/core/db/database.dart';
import 'package:t5_plan/core/db/repository.dart';
import 'package:t5_plan/core/export/export_service.dart';
import 'package:t5_plan/core/notifications/reminder_service.dart';
import 'package:t5_plan/core/providers.dart';
import 'package:t5_plan/core/settings/preferences.dart';
import 'package:t5_plan/core/sync/sync_service.dart';
import 'package:t5_plan/ui/screens/focus_screen.dart';
import 'package:t5_plan/ui/screens/issues_screen.dart';
import 'package:t5_plan/ui/screens/review_screen.dart';
import 'package:t5_plan/ui/screens/settings_screen.dart';
import 'package:t5_plan/ui/screens/tasks_screen.dart';
import 'package:t5_plan/ui/screens/today_screen.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late AppPreferences prefs;
  late TaskRepository repo;
  late ApiClient api;
  late SyncService sync;
  late ReminderService reminder;
  late ExportService exportService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.load();
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(db: db, deviceId: '11111111-1111-4111-8111-111111111111');
    api = ApiClient(
      baseUrl: 'http://127.0.0.1:9',
      client: MockClient((request) async => http.Response('{"error":"offline"}', 503)),
    );
    sync = SyncService(
      db: db,
      api: api,
      prefs: prefs,
      repository: repo,
      deviceId: '11111111-1111-4111-8111-111111111111',
      tokenReader: () async => null,
      pausedReader: () => false,
    );
    reminder = ReminderService(db, 'Asia/Shanghai');
    exportService = ExportService(db, repo);
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  Widget wrap(Widget child) => ProviderScope(
        overrides: [
          appPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(api),
          deviceIdProvider.overrideWithValue('11111111-1111-4111-8111-111111111111'),
          taskRepositoryProvider.overrideWithValue(repo),
          syncServiceProvider.overrideWithValue(sync),
          reminderServiceProvider.overrideWithValue(reminder),
          exportServiceProvider.overrideWithValue(exportService),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<void> checkPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(wrap(page));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  testWidgets('Today screen mounts', (tester) async {
    await checkPage(tester, TodayScreen(onNavigate: (_) {}));
  });

  testWidgets('Tasks screen mounts', (tester) async {
    await checkPage(tester, const TasksScreen());
  });

  testWidgets('Issues screen mounts', (tester) async {
    await checkPage(tester, const IssuesScreen());
  });

  testWidgets('Review screen mounts', (tester) async {
    await checkPage(tester, const ReviewScreen());
  });

  testWidgets('Focus screen mounts', (tester) async {
    await checkPage(tester, const FocusScreen());
  });

  testWidgets('Settings screen mounts', (tester) async {
    await checkPage(tester, const SettingsScreen());
  });
}
