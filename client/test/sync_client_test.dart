import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:t5_plan/core/api/api_client.dart';
import 'package:t5_plan/core/db/database.dart';
import 'package:t5_plan/core/db/repository.dart';
import 'package:t5_plan/core/settings/preferences.dart';
import 'package:t5_plan/core/sync/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late AppPreferences prefs;
  late TaskRepository repo;
  late SyncService sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPreferences.load();
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(db: db, deviceId: '11111111-1111-4111-8111-111111111111');
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  SyncService makeSync(MockClient client) {
    final api = ApiClient(
      baseUrl: 'https://sync.test',
      token: 'device-token',
      client: client,
    );
    return SyncService(
      db: db,
      api: api,
      prefs: prefs,
      repository: repo,
      deviceId: '11111111-1111-4111-8111-111111111111',
      tokenReader: () async => 'device-token',
      pausedReader: () => false,
    );
  }

  test('offline save creates an immutable pending operation and sync clears it', () async {
    final task = await repo.createTask(title: '离线任务', dueDate: '2026-11-16');
    final ops = await db.select(db.syncOperations).get();
    expect(ops, hasLength(1));
    expect(ops.single.baseVersion, 0);
    sync = makeSync(MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/sync/bootstrap')) {
        return http.Response(jsonEncode({
          'generation': 'gen-1',
          'server_time': DateTime.now().toUtc().toIso8601String(),
          'snapshot_seq': 0,
          'entities': [],
          'has_more': false,
        }), 200);
      }
      if (path.endsWith('/sync/push')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final operations = (body['operations'] as List).cast<Map<String, dynamic>>();
        return http.Response(jsonEncode({
          'results': [
            for (final op in operations)
              {
                'operation_id': op['operation_id'],
                'accepted': true,
                'conflict': false,
                'server_version': 1,
              }
          ]
        }), 200);
      }
      if (path.endsWith('/sync/changes')) {
        return http.Response(jsonEncode({
          'generation': 'gen-1',
          'server_time': DateTime.now().toUtc().toIso8601String(),
          'changes': [],
          'next_cursor': 0,
          'has_more': false,
        }), 200);
      }
      return http.Response('{}', 404);
    }));
    final snapshot = await sync.syncNow();
    expect(snapshot.lastError, isNull);
    expect(await db.select(db.syncOperations).get(), isEmpty);
    final meta = await (db.select(db.entityMeta)
          ..where((t) => t.entityType.equals('task') & t.entityId.equals(task.id)))
        .getSingle();
    expect(meta.serverVersion, 1);
    expect(meta.dirty, isFalse);
  });

  test('editing after a request is sent is not overwritten by the old response', () async {
    final task = await repo.createTask(title: '初稿', dueDate: '2026-11-16');
    final pushStarted = Completer<void>();
    final releasePush = Completer<void>();
    var pushCount = 0;
    sync = makeSync(MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/sync/bootstrap')) {
        return http.Response(jsonEncode({
          'generation': 'gen-1',
          'server_time': DateTime.now().toUtc().toIso8601String(),
          'snapshot_seq': 0,
          'entities': [],
          'has_more': false,
        }), 200);
      }
      if (path.endsWith('/sync/push')) {
        pushCount++;
        if (pushCount == 1) {
          pushStarted.complete();
          await releasePush.future;
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final operations = (body['operations'] as List).cast<Map<String, dynamic>>();
        return http.Response(jsonEncode({
          'results': [
            for (final op in operations)
              {
                'operation_id': op['operation_id'],
                'accepted': true,
                'conflict': false,
                'server_version': pushCount,
              }
          ]
        }), 200);
      }
      if (path.endsWith('/sync/changes')) {
        return http.Response(jsonEncode({
          'generation': 'gen-1',
          'server_time': DateTime.now().toUtc().toIso8601String(),
          'changes': [],
          'next_cursor': 0,
          'has_more': false,
        }), 200);
      }
      return http.Response('{}', 404);
    }));
    final future = sync.syncNow();
    await pushStarted.future;
    final current = await repo.getTask(task.id);
    await repo.updateTask(current!.copyWith(title: '同步期间继续编辑'));
    releasePush.complete();
    await future;

    final row = await repo.getTask(task.id);
    expect(row!.title, '同步期间继续编辑');
    final meta = await (db.select(db.entityMeta)
          ..where((t) => t.entityType.equals('task') & t.entityId.equals(task.id)))
        .getSingle();
    expect(meta.serverVersion, greaterThanOrEqualTo(1));
    final pending = await db.select(db.syncOperations).get();
    if (pending.isNotEmpty) {
      expect(meta.dirty, isTrue);
      expect(pending.single.baseVersion, meta.serverVersion);
      expect(pending.single.payload, contains('同步期间继续编辑'));
    } else {
      expect(meta.dirty, isFalse);
    }
  });

  test('version conflict is preserved for user resolution', () async {
    final task = await repo.createTask(title: '本地', dueDate: '2026-11-16');
    sync = makeSync(MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/sync/bootstrap')) {
        return http.Response(jsonEncode({
          'generation': 'gen-1',
          'server_time': DateTime.now().toUtc().toIso8601String(),
          'snapshot_seq': 0,
          'entities': [],
          'has_more': false,
        }), 200);
      }
      if (path.endsWith('/sync/push')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final op = (body['operations'] as List).first as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(jsonEncode({
          'results': [
            {
              'operation_id': op['operation_id'],
              'accepted': false,
              'conflict': true,
              'server_version': 3,
              'entity': {
                'entity_type': 'task',
                'entity_id': task.id,
                'version': 3,
                'deleted': false,
                'data': {
                  'id': task.id,
                  'title': '云端版本',
                  'due_date': '2026-11-16',
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                },
                'server_updated_at': DateTime.now().toUtc().toIso8601String(),
              }
            }
          ]
        })), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (path.endsWith('/sync/changes')) {
        return http.Response(jsonEncode({
          'generation': 'gen-1',
          'server_time': DateTime.now().toUtc().toIso8601String(),
          'changes': [],
          'next_cursor': 0,
          'has_more': false,
        }), 200);
      }
      return http.Response('{}', 404);
    }));
    await sync.syncNow();
    final conflicts = await db.select(db.conflictCopies).get();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.localJson, contains('本地'));
    expect(conflicts.single.serverJson, contains('云端版本'));
    final local = await repo.getTask(task.id);
    expect(local!.title, '本地');
    final meta = await (db.select(db.entityMeta)
          ..where((t) => t.entityType.equals('task') & t.entityId.equals(task.id)))
        .getSingle();
    expect(meta.hasConflict, isTrue);
  });
}
