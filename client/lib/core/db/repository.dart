import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../models/domain.dart';
import '../sync/entity_codec.dart';
import 'database.dart';

typedef MutationCallback = void Function();

class TaskRepository {
  TaskRepository({
    required this.db,
    required this.deviceId,
    this.onMutation,
  });

  final AppDatabase db;
  final String deviceId;
  final MutationCallback? onMutation;
  static const _uuid = Uuid();

  String _id() => _uuid.v4();
  DateTime _now() => DateTime.now().toUtc();

  // ---------------------------------------------------------------------------
  // Tasks

  Stream<List<Task>> watchTodayDueTasks(String businessDate) {
    final sql = '''
      SELECT t.* FROM tasks t
      WHERE t.deleted = 0 AND t.archived = 0 AND t.status != 2
        AND t.due_date IS NOT NULL AND t.due_date <= ?
      ORDER BY
        CASE WHEN t.due_date < ? THEN 0 ELSE 1 END,
        t.priority DESC, t.due_time IS NULL, t.due_time, t.sort_order, t.created_at
    ''';
    return db
        .customSelect(sql,
            variables: [Variable.withString(businessDate), Variable.withString(businessDate)],
            readsFrom: {db.tasks})
        .watch()
        .map((rows) => rows.map((r) => db.tasks.map(r.data)).toList());
  }

  Stream<List<Task>> watchFocusTasks(String businessDate) {
    final sql = '''
      SELECT t.* FROM daily_foci f JOIN tasks t ON t.id = f.task_id
      WHERE f.business_date = ? AND f.deleted = 0 AND t.deleted = 0
      ORDER BY f.sort_order, f.created_at
    ''';
    return db
        .customSelect(sql,
            variables: [Variable.withString(businessDate)],
            readsFrom: {db.dailyFoci, db.tasks})
        .watch()
        .map((rows) => rows.map((r) => db.tasks.map(r.data)).toList());
  }

  Stream<List<Task>> watchAllTasks({
    String? status,
    String? listId,
    String? search,
    int limit = 200,
    int offset = 0,
    bool includeDone = true,
    bool trash = false,
  }) {
    final where = <String>['t.deleted = ${trash ? 1 : 0}'];
    final vars = <Variable>[];
    if (!trash) where.add('t.archived = 0');
    if (status != null && status.isNotEmpty) {
      final s = int.tryParse(status);
      if (s != null) {
        where.add('t.status = ?');
        vars.add(Variable.withInt(s));
      }
    } else if (!includeDone && !trash) {
      where.add('t.status != 2');
    }
    if (listId != null && listId.isNotEmpty) {
      where.add('t.list_id = ?');
      vars.add(Variable.withString(listId));
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(t.title LIKE ? OR t.notes LIKE ?)');
      final q = '%${search.trim()}%';
      vars.add(Variable.withString(q));
      vars.add(Variable.withString(q));
    }
    vars.add(Variable.withInt(limit));
    vars.add(Variable.withInt(offset));
    final sql = '''
      SELECT t.* FROM tasks t WHERE ${where.join(' AND ')}
      ORDER BY t.status, t.priority DESC, t.due_date IS NULL, t.due_date, t.sort_order, t.created_at
      LIMIT ? OFFSET ?
    ''';
    return db
        .customSelect(sql, variables: vars, readsFrom: {db.tasks})
        .watch()
        .map((rows) => rows.map((r) => db.tasks.map(r.data)).toList());
  }

  Stream<List<Task>> watchTasksInRange(String startDate, String endDate) {
    return db
        .customSelect(
          'SELECT * FROM tasks WHERE deleted=0 AND archived=0 AND due_date IS NOT NULL '
          'AND due_date >= ? AND due_date <= ? ORDER BY due_date, due_time, priority DESC',
          variables: [Variable.withString(startDate), Variable.withString(endDate)],
          readsFrom: {db.tasks},
        )
        .watch()
        .map((rows) => rows.map((r) => db.tasks.map(r.data)).toList());
  }

  Future<void> reorderFocusTasksByTaskIds(String date, List<String> taskIds) async {
    for (var i = 0; i < taskIds.length; i++) {
      final id = _uuid.v5(Namespace.url.value, 't5:daily-focus:$date:${taskIds[i]}');
      final row = await (db.select(db.dailyFoci)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (row == null) continue;
      final c = row.copyWith(sortOrder: i, updatedAt: _now());
      await db.transaction(() async {
        await db.into(db.dailyFoci).insertOnConflictUpdate(c);
        await _enqueueEntity('daily_focus', id, dailyFocusToJson(c));
      });
    }
    onMutation?.call();
  }

  Stream<Task?> watchTask(String id) {
    return (db.select(db.tasks)..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  Future<Task?> getTask(String id) {
    return (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<List<Task>> subtasks(String parentId) {
    return (db.select(db.tasks)
          ..where((t) => t.parentId.equals(parentId) & t.deleted.equals(false)))
        .get();
  }

  Future<bool> hasIncompleteSubtasks(String parentId) async {
    final children = await subtasks(parentId);
    return children.any((t) => t.status != TaskStatus.done.value);
  }

  Future<Task> createTask({
    required String title,
    String notes = '',
    String? listId,
    TaskStatus status = TaskStatus.todo,
    TaskPriority priority = TaskPriority.none,
    String? dueDate,
    String? dueTime,
    DateTime? reminderAt,
    String? recurrence,
    String? parentId,
  }) async {
    final now = _now();
    final row = Task(
      id: _id(),
      title: title.trim(),
      notes: notes,
      listId: listId,
      status: status.value,
      priority: priority.value,
      dueDate: dueDate,
      dueTime: dueTime,
      reminderAt: reminderAt?.toUtc(),
      recurrence: recurrence,
      seriesId: recurrence == null ? null : null,
      occurrenceDate: recurrence == null ? null : dueDate,
      parentId: parentId,
      sortOrder: 0,
      archived: false,
      deleted: false,
      completedAt: status == TaskStatus.done ? now : null,
      createdAt: now,
      updatedAt: now,
    );
    final withSeries = recurrence == null ? row : row.copyWith(seriesId: Value(row.id));
    await db.transaction(() async {
      await db.into(db.tasks).insert(withSeries);
      await _enqueueEntity('task', withSeries.id, taskToJson(withSeries));
    });
    onMutation?.call();
    return withSeries;
  }

  Future<void> updateTask(Task task) async {
    final updated = task.copyWith(updatedAt: _now());
    await db.transaction(() async {
      await db.into(db.tasks).insertOnConflictUpdate(updated);
      await _enqueueEntity('task', updated.id, taskToJson(updated));
    });
    onMutation?.call();
  }

  Future<void> setTaskStatus(
    String id,
    TaskStatus status, {
    bool completeChildren = false,
  }) async {
    final task = await getTask(id);
    if (task == null) return;
    final now = _now();
    final completedAt = status == TaskStatus.done ? now : null;
    final updated = task.copyWith(status: status.value, completedAt: Value(completedAt), updatedAt: now);
    await db.transaction(() async {
      await db.into(db.tasks).insertOnConflictUpdate(updated);
      await _enqueueEntity('task', updated.id, taskToJson(updated));
      if (status == TaskStatus.done) {
        final children = await subtasks(id);
        for (final child in children) {
          if (child.status == TaskStatus.done.value) continue;
          if (!completeChildren) {
            throw StateError('incomplete_subtasks');
          }
          final c = child.copyWith(status: 2, completedAt: Value(now), updatedAt: now);
          await db.into(db.tasks).insertOnConflictUpdate(c);
          await _enqueueEntity('task', c.id, taskToJson(c));
        }
        await _createNextRecurrence(updated);
      }
    });
    onMutation?.call();
  }

  Future<void> _createNextRecurrence(Task task) async {
    if (task.recurrence == null || task.recurrence!.isEmpty) return;
    final base = task.occurrenceDate ?? task.dueDate;
    if (base == null) return;
    final next = nextRecurrenceDate(DateTime.parse(base), task.recurrence!);
    final date = businessDateOf(next);
    final seriesId = task.seriesId ?? task.id;
    final nextId = _uuid.v5(Namespace.url.value, 't5:series:$seriesId:$date');
    final existing = await getTask(nextId);
    if (existing != null) return;
    final now = _now();
    final instance = Task(
      id: nextId,
      title: task.title,
      notes: task.notes,
      listId: task.listId,
      status: TaskStatus.todo.value,
      priority: task.priority,
      dueDate: date,
      dueTime: task.dueTime,
      reminderAt: null,
      recurrence: task.recurrence,
      seriesId: seriesId,
      occurrenceDate: date,
      parentId: task.parentId,
      sortOrder: task.sortOrder,
      archived: false,
      deleted: false,
      completedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    await db.into(db.tasks).insert(instance);
    await _enqueueEntity('task', instance.id, taskToJson(instance));
  }

  Future<void> batchComplete(List<String> ids) async {
    final now = _now();
    await db.transaction(() async {
      for (final id in ids) {
        final task = await getTask(id);
        if (task == null || task.status == 2) continue;
        final c = task.copyWith(status: 2, completedAt: Value(now), updatedAt: now);
        await db.into(db.tasks).insertOnConflictUpdate(c);
        await _enqueueEntity('task', id, taskToJson(c));
        await _createNextRecurrence(c);
      }
    });
    onMutation?.call();
  }

  Future<void> archiveTasks(List<String> ids) async {
    final now = _now();
    await db.transaction(() async {
      for (final id in ids) {
        final task = await getTask(id);
        if (task == null) continue;
        final c = task.copyWith(archived: true, updatedAt: now);
        await db.into(db.tasks).insertOnConflictUpdate(c);
        await _enqueueEntity('task', id, taskToJson(c));
      }
    });
    onMutation?.call();
  }

  Future<void> deleteTaskGroup(String id) async {
    final now = _now();
    await db.transaction(() async {
      final all = [
        if (await getTask(id) case final t?) t,
        ...await subtasks(id),
      ];
      for (final task in all) {
        final c = task.copyWith(deleted: true, updatedAt: now);
        await db.into(db.tasks).insertOnConflictUpdate(c);
        await _enqueueEntity('task', c.id, taskToJson(c), deleted: true);
      }
    });
    onMutation?.call();
  }

  Future<void> restoreTaskGroup(String id) async {
    final now = _now();
    await db.transaction(() async {
      final rows = await (db.select(db.tasks)
            ..where((t) => t.id.equals(id) | t.parentId.equals(id)))
          .get();
      for (final task in rows) {
        final c = task.copyWith(deleted: false, updatedAt: now);
        await db.into(db.tasks).insertOnConflictUpdate(c);
        await _enqueueEntity('task', c.id, taskToJson(c));
      }
    });
    onMutation?.call();
  }

  Future<void> deleteTaskPermanently(String id) async {
    // Local-only permanent removal. Synced replicas keep the tombstone.
    await (db.delete(db.tasks)..where((t) => t.id.equals(id))).go();
  }

  Future<void> addFocusTask(String businessDate, String taskId) async {
    final count = await (db.selectOnly(db.dailyFoci)
          ..addColumns([db.dailyFoci.id.count()])
          ..where(db.dailyFoci.businessDate.equals(businessDate) &
              db.dailyFoci.deleted.equals(false)))
        .map((r) => r.read(db.dailyFoci.id.count()) ?? 0)
        .getSingle();
    if (count >= 5) throw StateError('today_focus_limit');
    final id = _uuid.v5(Namespace.url.value, 't5:daily-focus:$businessDate:$taskId');
    final row = DailyFociData(
      id: id,
      businessDate: businessDate,
      taskId: taskId,
      sortOrder: count,
      deleted: false,
      createdAt: _now(),
      updatedAt: _now(),
    );
    await db.transaction(() async {
      await db.into(db.dailyFoci).insertOnConflictUpdate(row);
      await _enqueueEntity('daily_focus', id, dailyFocusToJson(row));
    });
    onMutation?.call();
  }

  Future<void> removeFocusTask(String id) async {
    final row = await (db.select(db.dailyFoci)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    final c = row.copyWith(deleted: true, updatedAt: _now());
    await db.transaction(() async {
      await db.into(db.dailyFoci).insertOnConflictUpdate(c);
      await _enqueueEntity('daily_focus', id, dailyFocusToJson(c), deleted: true);
    });
    onMutation?.call();
  }

  Future<void> reorderFocus(List<String> ids) async {
    await db.transaction(() async {
      for (var i = 0; i < ids.length; i++) {
        final row = await (db.select(db.dailyFoci)..where((t) => t.id.equals(ids[i])))
            .getSingleOrNull();
        if (row == null) continue;
        final c = row.copyWith(sortOrder: i, updatedAt: _now());
        await db.into(db.dailyFoci).insertOnConflictUpdate(c);
        await _enqueueEntity('daily_focus', c.id, dailyFocusToJson(c));
      }
    });
    onMutation?.call();
  }

  Stream<List<(DailyFociData, Task)>> watchFocusWithRows(String businessDate) {
    final sql = '''
      SELECT f.id AS f_id, f.business_date AS f_date, f.task_id AS f_task_id,
             f.sort_order AS f_sort, f.deleted AS f_deleted,
             f.created_at AS f_created, f.updated_at AS f_updated,
             t.id AS t_id, t.title AS t_title, t.notes AS t_notes, t.list_id AS t_list_id,
             t.status AS t_status, t.priority AS t_priority, t.due_date AS t_due_date,
             t.due_time AS t_due_time, t.reminder_at AS t_reminder_at, t.recurrence AS t_recurrence,
             t.series_id AS t_series_id, t.occurrence_date AS t_occurrence_date,
             t.parent_id AS t_parent_id, t.sort_order AS t_sort_order, t.archived AS t_archived,
             t.deleted AS t_deleted, t.completed_at AS t_completed_at,
             t.created_at AS t_created, t.updated_at AS t_updated
      FROM daily_foci f JOIN tasks t ON t.id = f.task_id
      WHERE f.business_date = ? AND f.deleted = 0 AND t.deleted = 0
      ORDER BY f.sort_order, f.created_at
    ''';
    return db
        .customSelect(sql,
            variables: [Variable.withString(businessDate)],
            readsFrom: {db.dailyFoci, db.tasks})
        .watch()
        .map((rows) => rows.map((r) {
              final d = r.data;
              final focus = DailyFociData(
                id: d['f_id'] as String,
                businessDate: d['f_date'] as String,
                taskId: d['f_task_id'] as String,
                sortOrder: d['f_sort'] as int,
                deleted: (d['f_deleted'] as int) != 0,
                createdAt: DateTime.fromMillisecondsSinceEpoch((d['f_created'] as int) * 1000, isUtc: true),
                updatedAt: DateTime.fromMillisecondsSinceEpoch((d['f_updated'] as int) * 1000, isUtc: true),
              );
              final task = Task(
                id: d['t_id'] as String,
                title: d['t_title'] as String,
                notes: d['t_notes'] as String,
                listId: d['t_list_id'] as String?,
                status: d['t_status'] as int,
                priority: d['t_priority'] as int,
                dueDate: d['t_due_date'] as String?,
                dueTime: d['t_due_time'] as String?,
                reminderAt: d['t_reminder_at'] == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch((d['t_reminder_at'] as int) * 1000, isUtc: true),
                recurrence: d['t_recurrence'] as String?,
                seriesId: d['t_series_id'] as String?,
                occurrenceDate: d['t_occurrence_date'] as String?,
                parentId: d['t_parent_id'] as String?,
                sortOrder: d['t_sort_order'] as int,
                archived: (d['t_archived'] as int) != 0,
                deleted: (d['t_deleted'] as int) != 0,
                completedAt: d['t_completed_at'] == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch((d['t_completed_at'] as int) * 1000, isUtc: true),
                createdAt: DateTime.fromMillisecondsSinceEpoch((d['t_created'] as int) * 1000, isUtc: true),
                updatedAt: DateTime.fromMillisecondsSinceEpoch((d['t_updated'] as int) * 1000, isUtc: true),
              );
              return (focus, task);
            }).toList());
  }

  // ---------------------------------------------------------------------------
  // Lists and tags

  Stream<List<TaskList>> watchLists() => (db.select(db.taskLists)
        ..where((t) => t.deleted.equals(false) & t.archived.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
      .watch();

  Future<TaskList> createList(String name, {String color = '#4F7DF3'}) async {
    final now = _now();
    final row = TaskList(
      id: _id(),
      name: name.trim(),
      color: color,
      sortOrder: 0,
      archived: false,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.taskLists).insert(row);
      await _enqueueEntity('task_list', row.id, taskListToJson(row));
    });
    onMutation?.call();
    return row;
  }

  Stream<List<Tag>> watchTags() =>
      (db.select(db.tags)..where((t) => t.deleted.equals(false))).watch();

  Future<Tag> createTag(String name, {String color = '#7A8CA6'}) async {
    final now = _now();
    final row = Tag(
      id: _id(),
      name: name.trim(),
      color: color,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.tags).insert(row);
      await _enqueueEntity('tag', row.id, tagToJson(row));
    });
    onMutation?.call();
    return row;
  }

  Future<List<TaskTag>> tagsForTask(String taskId) =>
      (db.select(db.taskTags)..where((t) => t.taskId.equals(taskId) & t.deleted.equals(false))).get();

  Future<void> setTaskTags(String taskId, List<String> tagIds) async {
    final now = _now();
    await db.transaction(() async {
      final existing = await (db.select(db.taskTags)..where((t) => t.taskId.equals(taskId))).get();
      for (final row in existing) {
        if (!tagIds.contains(row.tagId) && !row.deleted) {
          final c = row.copyWith(deleted: true, updatedAt: now);
          await db.into(db.taskTags).insertOnConflictUpdate(c);
          await _enqueueEntity(
              'task_tag', _taskTagEntityId(taskId, row.tagId), taskTagToJson(c), deleted: true);
        }
      }
      for (final tagId in tagIds) {
        final row = TaskTag(
            taskId: taskId, tagId: tagId, deleted: false, createdAt: now, updatedAt: now);
        await db.into(db.taskTags).insertOnConflictUpdate(row);
        await _enqueueEntity('task_tag', _taskTagEntityId(taskId, tagId), taskTagToJson(row));
      }
    });
    onMutation?.call();
  }

  String _taskTagEntityId(String taskId, String tagId) =>
      _uuid.v5(Namespace.url.value, 't5:task-tag:$taskId:$tagId');

  // ---------------------------------------------------------------------------
  // Decisions and daily reflection

  Stream<List<Decision>> watchDecisions(String date) => (db.select(db.decisions)
        ..where((t) => t.businessDate.equals(date) & t.deleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.slot)]))
      .watch();

  Future<void> saveDecision({
    required String date,
    required int slot,
    required String decisionText,
    required String rationale,
    required AiParticipation participation,
    String? linkedTaskId,
    String? linkedIssueId,
    String outcomeReflection = '',
  }) async {
    final id = _uuid.v5(Namespace.url.value, 't5:decision:$date:$slot');
    final existing = await (db.select(db.decisions)..where((t) => t.id.equals(id))).getSingleOrNull();
    final now = _now();
    final row = Decision(
      id: id,
      businessDate: date,
      slot: slot,
      decisionText: decisionText,
      rationale: rationale,
      aiParticipation: participation.value,
      linkedTaskId: linkedTaskId,
      linkedIssueId: linkedIssueId,
      outcomeReflection: outcomeReflection,
      deleted: false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.decisions).insertOnConflictUpdate(row);
      await _enqueueEntity('decision', id, decisionToJson(row));
    });
    onMutation?.call();
  }

  Future<void> saveDecisionReflection(String id, String reflection) async {
    final row = await (db.select(db.decisions)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    final c = row.copyWith(outcomeReflection: reflection, updatedAt: _now());
    await db.transaction(() async {
      await db.into(db.decisions).insertOnConflictUpdate(c);
      await _enqueueEntity('decision', c.id, decisionToJson(c));
    });
    onMutation?.call();
  }

  Stream<DailyReview?> watchDailyReview(String date) =>
      (db.select(db.dailyReviews)..where((t) => t.businessDate.equals(date) & t.deleted.equals(false)))
          .watchSingleOrNull();

  Future<void> saveDailyReview(
      {required String date, required String aiHelped, required String aiOverreliance}) async {
    final id = _uuid.v5(Namespace.url.value, 't5:daily-review:$date');
    final existing =
        await (db.select(db.dailyReviews)..where((t) => t.id.equals(id))).getSingleOrNull();
    final now = _now();
    final row = DailyReview(
      id: id,
      businessDate: date,
      aiHelped: aiHelped,
      aiOverreliance: aiOverreliance,
      deleted: false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.dailyReviews).insertOnConflictUpdate(row);
      await _enqueueEntity('daily_review', id, dailyReviewToJson(row));
    });
    onMutation?.call();
  }

  // ---------------------------------------------------------------------------
  // Issues

  Stream<List<Issue>> watchIssues({IssueStatus? status}) {
    final q = db.select(db.issues)..where((t) => t.deleted.equals(false));
    if (status != null) q.where((t) => t.status.equals(status.value));
    q.orderBy([
      (t) => OrderingTerm.asc(t.status),
      (t) => OrderingTerm.desc(t.updatedAt),
    ]);
    return q.watch();
  }

  Future<Issue> createIssue({
    required String title,
    String context = '',
    String initialJudgment = '',
    IssueStatus status = IssueStatus.thinking,
  }) async {
    final now = _now();
    final row = Issue(
      id: _id(),
      title: title.trim(),
      context: context,
      initialJudgment: initialJudgment,
      status: status.value,
      resolvedAt: null,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.issues).insert(row);
      await _enqueueEntity('issue', row.id, issueToJson(row));
    });
    onMutation?.call();
    return row;
  }

  Future<void> updateIssue(Issue issue) async {
    final now = _now();
    final resolvedAt =
        issue.status == IssueStatus.resolved.value ? (issue.resolvedAt ?? now) : null;
    final c = issue.copyWith(resolvedAt: Value(resolvedAt), updatedAt: now);
    await db.transaction(() async {
      await db.into(db.issues).insertOnConflictUpdate(c);
      await _enqueueEntity('issue', c.id, issueToJson(c));
    });
    onMutation?.call();
  }

  Future<void> setIssueStatus(String id, IssueStatus status) async {
    final row = await (db.select(db.issues)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;
    await updateIssue(row.copyWith(
      status: status.value,
      resolvedAt: Value(status == IssueStatus.resolved ? _now() : null),
    ));
  }

  Stream<Issue?> watchIssue(String id) =>
      (db.select(db.issues)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Issue> saveDailyOpenQuestion({
    required String date,
    required String title,
    required String initialJudgment,
  }) async {
    final id = _uuid.v5(Namespace.url.value, 't5:daily-question:$date');
    final existing = await getIssue(id);
    final now = _now();
    final row = Issue(
      id: id,
      title: title.trim(),
      context: '每日未想清楚的问题 · $date',
      initialJudgment: initialJudgment,
      status: existing?.status ?? IssueStatus.thinking.value,
      resolvedAt: existing?.resolvedAt,
      deleted: false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.issues).insertOnConflictUpdate(row);
      await _enqueueEntity('issue', id, issueToJson(row));
    });
    onMutation?.call();
    return row;
  }

  Future<Issue?> getIssue(String id) =>
      (db.select(db.issues)..where((t) => t.id.equals(id))).getSingleOrNull();

  // ---------------------------------------------------------------------------
  // Focus records and statistics

  Future<FocusRecord> addFocusRecord({
    String? taskId,
    String label = '',
    required DateTime startedAt,
    required DateTime endedAt,
    String? sharedSessionId,
    bool independent = true,
    int? focusedDurationSeconds,
  }) async {
    final start = startedAt.toUtc();
    final end = endedAt.toUtc();
    final duration = focusedDurationSeconds ?? math.max(0, end.difference(start).inSeconds);
    final overlap = await _overlapSeconds(start, end);
    final now = _now();
    final row = FocusRecord(
      id: _id(),
      taskId: taskId,
      label: label,
      startedAt: start,
      endedAt: end,
      durationSeconds: duration,
      effectiveSeconds: math.max(0, duration - overlap),
      sharedSessionId: sharedSessionId,
      sourceDevice: deviceId,
      independent: independent,
      overlapFlag: overlap > 0,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    );
    await db.transaction(() async {
      await db.into(db.focusRecords).insert(row);
      await _enqueueEntity('focus_record', row.id, focusRecordToJson(row));
    });
    onMutation?.call();
    return row;
  }

  Future<int> _overlapSeconds(DateTime start, DateTime end) async {
    final rows = await (db.select(db.focusRecords)
          ..where((t) =>
              t.deleted.equals(false) &
              t.startedAt.isSmallerThanValue(end) &
              t.endedAt.isBiggerThanValue(start))
          ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
        .get();
    if (rows.isEmpty) return 0;
    // Merge the union of existing intervals first, then intersect it with the
    // new interval. This prevents double-counting overlapping old records.
    var cursor = start;
    var overlap = Duration.zero;
    for (final row in rows) {
      final rowStart = row.startedAt.isAfter(start) ? row.startedAt : start;
      final rowEnd = row.endedAt.isBefore(end) ? row.endedAt : end;
      if (!rowEnd.isAfter(rowStart)) continue;
      final from = rowStart.isAfter(cursor) ? rowStart : cursor;
      if (rowEnd.isAfter(from)) {
        overlap += rowEnd.difference(from);
        cursor = rowEnd;
      }
    }
    return overlap.inSeconds;
  }

  Stream<int> watchTodayFocusSeconds() {
    final start = startOfLocalDay(DateTime.now()).toUtc();
    final end = start.add(const Duration(days: 1));
    return db
        .customSelect(
          'SELECT COALESCE(SUM(effective_seconds),0) AS s FROM focus_records '
          'WHERE deleted = 0 AND started_at >= ? AND started_at < ?',
          variables: [Variable.withDateTime(start), Variable.withDateTime(end)],
          readsFrom: {db.focusRecords},
        )
        .watchSingle()
        .map((r) => r.read<int>('s'));
  }

  Stream<int> watchTodayCompletedCount() {
    final now = DateTime.now();
    final start = startOfLocalDay(now).toUtc();
    final end = start.add(const Duration(days: 1));
    return db
        .customSelect(
          'SELECT COUNT(*) AS c FROM tasks WHERE deleted=0 AND status=2 '
          'AND completed_at >= ? AND completed_at < ?',
          variables: [Variable.withDateTime(start), Variable.withDateTime(end)],
          readsFrom: {db.tasks},
        )
        .watchSingle()
        .map((r) => r.read<int>('c'));
  }

  Future<List<Map<String, Object?>>> focusByDay(DateTime start, DateTime end) {
    return db.customSelect(
      "SELECT date(started_at,'unixepoch','localtime') AS day, "
      'SUM(effective_seconds) AS seconds FROM focus_records '
      'WHERE deleted=0 AND started_at >= ? AND started_at < ? GROUP BY day ORDER BY day',
      variables: [Variable.withDateTime(start.toUtc()), Variable.withDateTime(end.toUtc())],
      readsFrom: {db.focusRecords},
    ).get().then((rows) => rows.map((r) => r.data).toList());
  }

  Future<List<Map<String, Object?>>> focusByTask(DateTime start, DateTime end) {
    return db.customSelect(
      'SELECT task_id, COALESCE(SUM(effective_seconds),0) AS seconds FROM focus_records '
      'WHERE deleted=0 AND started_at >= ? AND started_at < ? GROUP BY task_id ORDER BY seconds DESC',
      variables: [Variable.withDateTime(start.toUtc()), Variable.withDateTime(end.toUtc())],
      readsFrom: {db.focusRecords},
    ).get().then((rows) => rows.map((r) => r.data).toList());
  }

  // ---------------------------------------------------------------------------
  // Sync support

  Future<void> _enqueueEntity(
    String entityType,
    String entityId,
    Map<String, dynamic> payload, {
    bool deleted = false,
  }) async {
    final now = _now();
    final meta = await (db.select(db.entityMeta)
          ..where((t) => t.entityType.equals(entityType) & t.entityId.equals(entityId)))
        .getSingleOrNull();
    final localRevision = (meta?.localRevision ?? 0) + 1;
    await db.into(db.entityMeta).insertOnConflictUpdate(EntityMetaCompanion(
          entityType: Value(entityType),
          entityId: Value(entityId),
          serverVersion: Value(meta?.serverVersion ?? 0),
          localRevision: Value(localRevision),
          dirty: const Value(true),
          hasConflict: Value(meta?.hasConflict ?? false),
          deleted: Value(deleted),
          lastServerAt: Value(meta?.lastServerAt),
        ));
    if (meta?.hasConflict == true) return;
    final unsent = await (db.select(db.syncOperations)
          ..where((t) =>
              t.entityType.equals(entityType) &
              t.entityId.equals(entityId) &
              t.state.equals(0))
          ..limit(1))
        .getSingleOrNull();
    if (unsent != null) {
      await (db.update(db.syncOperations)..where((t) => t.operationId.equals(unsent.operationId)))
          .write(SyncOperationsCompanion(
        payload: Value(jsonEncode(payload)),
        baseVersion: Value(meta?.serverVersion ?? 0),
        localRevision: Value(localRevision),
        deleted: Value(deleted),
      ));
      return;
    }
    final sent = await (db.select(db.syncOperations)
          ..where((t) =>
              t.entityType.equals(entityType) &
              t.entityId.equals(entityId) &
              t.state.equals(1))
          ..limit(1))
        .getSingleOrNull();
    if (sent != null) return;
    await db.into(db.syncOperations).insert(SyncOperationsCompanion.insert(
      operationId: _id(),
      entityType: entityType,
      entityId: entityId,
      baseVersion: meta?.serverVersion ?? 0,
      payload: jsonEncode(payload),
      deleted: Value(deleted),
      localRevision: localRevision,
      state: const Value(0),
      createdAt: now,
    ));
  }

  Future<void> enqueueRawEntities(
      List<({String type, String id, Map<String, dynamic> payload, bool deleted})> items) async {
    await db.transaction(() async {
      for (final item in items) {
        await _enqueueEntity(item.type, item.id, item.payload, deleted: item.deleted);
      }
    });
    onMutation?.call();
  }

  Future<void> deleteLocalDataForImport() async {
    await db.transaction(() async {
      await db.delete(db.taskTags).go();
      await db.delete(db.dailyFoci).go();
      await db.delete(db.decisions).go();
      await db.delete(db.dailyReviews).go();
      await db.delete(db.focusRecords).go();
      await db.delete(db.issues).go();
      await db.delete(db.tasks).go();
      await db.delete(db.tags).go();
      await db.delete(db.taskLists).go();
      await db.delete(db.conflictCopies).go();
      await db.delete(db.syncOperations).go();
      await db.delete(db.entityMeta).go();
    });
  }

  static DateTime nextRecurrenceDate(DateTime base, String recurrence) {
    switch (recurrence) {
      case 'daily':
        return DateTime(base.year, base.month, base.day + 1);
      case 'weekly':
        return DateTime(base.year, base.month, base.day + 7);
      case 'monthly':
        final month = base.month + 1;
        final year = base.year + (month - 1) ~/ 12;
        final m = (month - 1) % 12 + 1;
        final lastDay = DateTime(year, m + 1, 0).day;
        return DateTime(year, m, math.min(base.day, lastDay));
      default:
        return base;
    }
  }
}
