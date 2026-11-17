import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:t5_plan/core/db/database.dart';
import 'package:t5_plan/core/db/repository.dart';

/// This is a database-only benchmark. It is intentionally gated so normal test
/// runs stay fast. Run with:
///   T5_PERF=1 flutter test test/performance_db_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('10k tasks / 5k decisions / 50k focus records read benchmark', () async {
    if (Platform.environment['T5_PERF'] != '1') {
      return;
    }
    final dir = await Directory.systemTemp.createTemp('t5_perf_');
    final file = File('${dir.path}/t5-perf.sqlite');
    final db = AppDatabase(NativeDatabase(file));
    final repo = TaskRepository(
      db: db,
      deviceId: '11111111-1111-4111-8111-111111111111',
    );
    final now = DateTime.now().toUtc();
    final today = DateTime(now.year, now.month, now.day);
    final stopwatch = Stopwatch()..start();

    for (var batchStart = 0; batchStart < 10000; batchStart += 500) {
      await db.batch((b) {
        b.insertAll(db.tasks, [
          for (var i = batchStart; i < batchStart + 500; i++)
            TasksCompanion.insert(
              id: 'task-$i',
              title: i % 11 == 0
                  ? '项目复盘 ${i % 97} mixed English $i'
                  : '${i % 7 == 0 ? '今天要完成' : '日常任务'} $i ${i % 13 == 0 ? '设计评审' : '执行'}',
              notes: Value(i % 5 == 0 ? '备注 $i 包含关键词 思考 与 AI' : ''),
              status: Value(i % 9 == 0 ? 2 : (i % 5 == 0 ? 1 : 0)),
              priority: Value(i % 4),
              dueDate: Value(_date(today.add(Duration(days: (i % 90) - 45)))),
              archived: Value(i % 37 == 0),
              completedAt: Value(i % 9 == 0 ? now : null),
              createdAt: now,
              updatedAt: now,
            ),
        ]);
      });
    }
    for (var batchStart = 0; batchStart < 5000; batchStart += 500) {
      await db.batch((b) {
        b.insertAll(db.decisions, [
          for (var i = batchStart; i < batchStart + 500; i++)
            DecisionsCompanion.insert(
              id: 'decision-$i',
              businessDate: _date(today.subtract(Duration(days: i % 365))),
              slot: i % 3 + 1,
              decisionText: Value('决策内容 $i：是否继续投入'),
              rationale: Value('依据 $i，权衡时间与收益'),
              aiParticipation: Value(i % 4),
              createdAt: now,
              updatedAt: now,
            ),
        ]);
      });
    }
    for (var batchStart = 0; batchStart < 50000; batchStart += 1000) {
      await db.batch((b) {
        b.insertAll(db.focusRecords, [
          for (var i = batchStart; i < batchStart + 1000; i++)
            FocusRecordsCompanion.insert(
              id: 'focus-$i',
              taskId: Value(i % 3 == 0 ? 'task-${i % 10000}' : null),
              label: Value('专注 $i'),
              startedAt: now.subtract(Duration(minutes: i * 7)),
              endedAt: now.subtract(Duration(minutes: i * 7 - 25)),
              durationSeconds: 1500,
              effectiveSeconds: const Value(1500),
              sourceDevice: const Value('perf'),
              createdAt: now,
              updatedAt: now,
            ),
        ]);
      });
    }
    final seedMs = stopwatch.elapsedMilliseconds;

    Future<int> p95Query(Future<void> Function() action) async {
      final values = <int>[];
      for (var i = 0; i < 21; i++) {
        final sw = Stopwatch()..start();
        await action();
        sw.stop();
        if (i > 0) values.add(sw.elapsedMilliseconds);
      }
      values.sort();
      return values[(values.length * 0.95).floor().clamp(0, values.length - 1)];
    }

    final todayP95 = await p95Query(() async {
      await repo.watchTodayDueTasks(_date(today)).first;
    });
    final pageP95 = await p95Query(() async {
      await repo.watchAllTasks(limit: 200).first;
    });
    final singleChineseP95 = await p95Query(() async {
      await repo.watchAllTasks(search: '思', limit: 100).first;
    });
    final doubleChineseP95 = await p95Query(() async {
      await repo.watchAllTasks(search: '思考', limit: 100).first;
    });
    final longPhraseP95 = await p95Query(() async {
      await repo.watchAllTasks(search: '今天要完成设计评审', limit: 100).first;
    });
    final mixedP95 = await p95Query(() async {
      await repo.watchAllTasks(search: '项目 mixed', limit: 100).first;
    });
    final focusAggregateStart = Stopwatch()..start();
    final days = await repo.focusByDay(
      today.subtract(const Duration(days: 30)),
      today.add(const Duration(days: 1)),
    );
    final focusAggregateMs = focusAggregateStart.elapsedMilliseconds;
    final count = await db
        .customSelect('SELECT COUNT(*) AS c FROM tasks', readsFrom: {db.tasks})
        .getSingle();
    final dbSize = await file.length();
    final out = {
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'rows': {
        'tasks': 10000,
        'decisions': 5000,
        'focus_records': 50000,
        'tasks_count_check': count.read<int>('c'),
      },
      'seed_ms': seedMs,
      'query_p95_ms': {
        'today_due': todayP95,
        'page_200': pageP95,
        'search_single_chinese': singleChineseP95,
        'search_double_chinese': doubleChineseP95,
        'search_long_phrase': longPhraseP95,
        'search_mixed': mixedP95,
      },
      'search_with_300ms_debounce_p95_ms': {
        'single_chinese': singleChineseP95 + 300,
        'double_chinese': doubleChineseP95 + 300,
        'long_phrase': longPhraseP95 + 300,
        'mixed': mixedP95 + 300,
      },
      'focus_aggregate_ms': focusAggregateMs,
      'focus_aggregate_days': days.length,
      'database_bytes': dbSize,
      'notes': [
        'Database-only benchmark; not a UI scroll or app startup measurement.',
        'Search P95 includes the configured 300ms debounce in the second map.',
      ],
    };
    final output = const JsonEncoder.withIndent('  ').convert(out);
    print(output);
    final artifact = File('../artifacts/performance-client-db.json');
    await artifact.parent.create(recursive: true);
    await artifact.writeAsString(output);
    expect(todayP95, lessThan(400));
    expect(singleChineseP95 + 300, lessThanOrEqualTo(400));
    expect(mixedP95 + 300, lessThanOrEqualTo(400));
    await db.close();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
