import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:t5_plan/core/db/database.dart';
import 'package:t5_plan/core/db/repository.dart';
import 'package:t5_plan/core/export/export_service.dart';
import 'package:t5_plan/core/models/domain.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late TaskRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(db: db, deviceId: '11111111-1111-4111-8111-111111111111');
  });

  tearDown(() async => db.close());

  test('daily focus enforces the maximum of five without auto-filling', () async {
    final today = todayBusinessDate();
    for (var i = 0; i < 6; i++) {
      final task = await repo.createTask(title: '任务 $i', dueDate: today);
      if (i < 5) {
        await repo.addFocusTask(today, task.id);
      } else {
        expect(() => repo.addFocusTask(today, task.id), throwsStateError);
      }
    }
    final rows = await db.select(db.dailyFoci).get();
    expect(rows.where((e) => !e.deleted), hasLength(5));
  });

  test('overlapping focus records keep full duration but de-duplicate effective time', () async {
    final start = DateTime.utc(2026, 11, 16, 2, 0);
    final first = await repo.addFocusRecord(
      startedAt: start,
      endedAt: start.add(const Duration(minutes: 25)),
    );
    final second = await repo.addFocusRecord(
      startedAt: start.add(const Duration(minutes: 10)),
      endedAt: start.add(const Duration(minutes: 35)),
    );
    expect(first.durationSeconds, 25 * 60);
    expect(first.effectiveSeconds, 25 * 60);
    expect(second.durationSeconds, 25 * 60);
    expect(second.effectiveSeconds, 10 * 60);
    expect(second.overlapFlag, isTrue);
  });

  test('recurring month-end instance uses a stable deterministic ID', () async {
    final task = await repo.createTask(
      title: '月末复盘',
      dueDate: '2026-01-31',
      recurrence: 'monthly',
    );
    await repo.setTaskStatus(task.id, TaskStatus.done);
    final rows = await db.select(db.tasks).get();
    final next = rows.singleWhere((e) => e.id != task.id);
    final expected = const Uuid().v5(Namespace.url.value, 't5:series:${task.id}:2026-02-28');
    expect(next.id, expected);
    expect(next.dueDate, '2026-02-28');
    expect(next.status, TaskStatus.todo.value);
    expect(next.seriesId, task.id);
  });

  test('parent/child delete and restore stay as one recoverable group', () async {
    final parent = await repo.createTask(title: '父任务');
    final child = await repo.createTask(title: '子任务', parentId: parent.id);
    await repo.deleteTaskGroup(parent.id);
    expect((await repo.getTask(parent.id))!.deleted, isTrue);
    expect((await repo.getTask(child.id))!.deleted, isTrue);
    await repo.restoreTaskGroup(parent.id);
    expect((await repo.getTask(parent.id))!.deleted, isFalse);
    expect((await repo.getTask(child.id))!.deleted, isFalse);
  });

  test('JSON restore creates new IDs and never overwrites existing rows', () async {
    final original = await repo.createTask(title: '原始任务', dueDate: '2026-11-16');
    final exporter = ExportService(db, repo);
    final data = await exporter.buildJsonExport();
    final count = await exporter.importAsNew(data);
    expect(count, greaterThan(0));
    final rows = await db.select(db.tasks).get();
    expect(rows, hasLength(2));
    expect(rows.where((e) => e.id == original.id), hasLength(1));
    expect(rows.where((e) => e.title == '原始任务'), hasLength(2));
    expect(rows.map((e) => e.id).toSet(), hasLength(2));
  });
}
