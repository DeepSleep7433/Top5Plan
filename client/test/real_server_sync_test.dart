import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:t5_plan/core/api/api_client.dart';
import 'package:t5_plan/core/db/database.dart';
import 'package:t5_plan/core/db/repository.dart';
import 'package:t5_plan/core/settings/preferences.dart';
import 'package:t5_plan/core/sync/sync_service.dart';

class _Client {
  _Client(this.db, this.repo, this.sync, this.api);
  final AppDatabase db;
  final TaskRepository repo;
  final SyncService sync;
  final ApiClient api;

  static Future<_Client> create(String baseUrl, String token, String deviceId) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AppPreferences.load();
    final db = AppDatabase(NativeDatabase.memory());
    final repo = TaskRepository(db: db, deviceId: deviceId);
    final api = ApiClient(baseUrl: baseUrl, token: token);
    final sync = SyncService(
      db: db,
      api: api,
      prefs: prefs,
      repository: repo,
      deviceId: deviceId,
      tokenReader: () async => token,
      pausedReader: () => false,
    );
    return _Client(db, repo, sync, api);
  }

  Future<void> close() async {
    sync.dispose();
    await db.close();
    api.close();
  }
}

/// Requires a real running t5d and paired device tokens:
///   T5_REAL_SERVER_URL=http://127.0.0.1:8088 \
///   T5_REAL_TOKEN=... T5_REAL_TOKEN2=... \
///   flutter test test/real_server_sync_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('real HTTP server round-trip uploads an offline task', () async {
    final baseUrl = Platform.environment['T5_REAL_SERVER_URL'];
    final token = Platform.environment['T5_REAL_TOKEN'];
    if (baseUrl == null || token == null) return;
    final c = await _Client.create(
        baseUrl, token, '11111111-1111-4111-8111-111111111111');
    final task = await c.repo.createTask(
      title: '真实客户端到服务器同步 ${DateTime.now().microsecondsSinceEpoch}',
      dueDate: '2026-11-16',
    );
    final snapshot = await c.sync.syncNow();
    expect(snapshot.lastError, isNull);
    final bootstrap = await c.api.bootstrap(limit: 500);
    final entities = (bootstrap['entities'] as List).cast<Map<String, dynamic>>();
    expect(
      entities.any((e) => e['entity_type'] == 'task' && e['entity_id'] == task.id),
      isTrue,
    );
    await c.close();
  });

  test('two real devices preserve both edits and converge after conflict resolution', () async {
    final baseUrl = Platform.environment['T5_REAL_SERVER_URL'];
    final token1 = Platform.environment['T5_REAL_TOKEN'];
    final token2 = Platform.environment['T5_REAL_TOKEN2'];
    if (baseUrl == null || token1 == null || token2 == null) return;
    final a = await _Client.create(baseUrl, token1, '11111111-1111-4111-8111-111111111111');
    final b = await _Client.create(baseUrl, token2, '22222222-2222-4222-8222-222222222222');
    await a.sync.syncNow();
    await b.sync.syncNow();
    final task = await a.repo.createTask(
      title: '双设备初始版本 ${DateTime.now().microsecondsSinceEpoch}',
      dueDate: '2026-11-16',
    );
    await a.sync.syncNow();
    await b.sync.syncNow();
    final seenByB = await b.repo.getTask(task.id);
    expect(seenByB, isNotNull);

    await a.repo.updateTask((await a.repo.getTask(task.id))!.copyWith(title: '设备 A 的修改'));
    await a.sync.syncNow();

    await b.repo.updateTask(seenByB!.copyWith(title: '设备 B 的离线修改'));
    final bSnapshot = await b.sync.syncNow();
    expect(bSnapshot.lastError, isNull);
    final conflicts = await b.db.select(b.db.conflictCopies).get();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.localJson, contains('设备 B 的离线修改'));
    expect(conflicts.single.serverJson, contains('设备 A 的修改'));
    expect((await b.repo.getTask(task.id))!.title, '设备 B 的离线修改');

    await b.sync.resolveKeepLocal(conflicts.single);
    expect(
      (await b.db.select(b.db.conflictCopies).get()).where((e) => e.resolvedAt == null),
      isEmpty,
    );
    await a.sync.syncNow();
    expect((await a.repo.getTask(task.id))!.title, '设备 B 的离线修改');
    expect((await b.repo.getTask(task.id))!.title, '设备 B 的离线修改');
    await a.close();
    await b.close();
  });
}
