import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:workmanager/workmanager.dart';

import '../api/api_client.dart';
import '../db/database.dart';
import '../db/repository.dart';
import '../settings/preferences.dart';
import 'sync_service.dart';

const backgroundSyncTask = 't5.background.sync';

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != backgroundSyncTask) return true;
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    tzdata.initializeTimeZones();
    AppDatabase? db;
    try {
      final prefs = await AppPreferences.load();
      final token = await prefs.readToken();
      if (token == null || token.isEmpty) return true;
      final deviceId = await prefs.ensureDeviceId();
      db = await openAppDatabase();
      final api = ApiClient(baseUrl: prefs.baseUrl, token: token);
      late TaskRepository repo;
      late SyncService sync;
      repo = TaskRepository(db: db, deviceId: deviceId, onMutation: () {});
      sync = SyncService(
        db: db,
        api: api,
        prefs: prefs,
        repository: repo,
        deviceId: deviceId,
      );
      await sync.initialize();
      await sync.syncNow(silent: true);
      sync.dispose();
      api.close();
      return true;
    } catch (_) {
      return false;
    } finally {
      await db?.close();
    }
  });
}

Future<void> registerPeriodicBackgroundSync() async {
  await Workmanager().initialize(backgroundCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    't5-periodic-sync',
    backgroundSyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 5),
  );
}

Future<void> requestOneOffBackgroundSync() async {
  await Workmanager().registerOneOffTask(
    't5-once-sync',
    backgroundSyncTask,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 1),
  );
}
