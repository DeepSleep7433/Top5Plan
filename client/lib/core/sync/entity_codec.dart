import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../models/domain.dart';

Map<String, dynamic> taskToJson(Task t) => {
      'id': t.id,
      'title': t.title,
      'notes': t.notes,
      'list_id': t.listId,
      'status': t.status,
      'priority': t.priority,
      'due_date': t.dueDate,
      'due_time': t.dueTime,
      'reminder_at': t.reminderAt?.toUtc().toIso8601String(),
      'recurrence': t.recurrence,
      'series_id': t.seriesId,
      'occurrence_date': t.occurrenceDate,
      'parent_id': t.parentId,
      'sort_order': t.sortOrder,
      'archived': t.archived,
      'deleted': t.deleted,
      'completed_at': t.completedAt?.toUtc().toIso8601String(),
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> taskListToJson(TaskList t) => {
      'id': t.id,
      'name': t.name,
      'color': t.color,
      'sort_order': t.sortOrder,
      'archived': t.archived,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> tagToJson(Tag t) => {
      'id': t.id,
      'name': t.name,
      'color': t.color,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> taskTagToJson(TaskTag t) => {
      'task_id': t.taskId,
      'tag_id': t.tagId,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> dailyFocusToJson(DailyFociData t) => {
      'id': t.id,
      'business_date': t.businessDate,
      'task_id': t.taskId,
      'sort_order': t.sortOrder,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> decisionToJson(Decision t) => {
      'id': t.id,
      'business_date': t.businessDate,
      'slot': t.slot,
      'decision_text': t.decisionText,
      'rationale': t.rationale,
      'ai_participation': t.aiParticipation,
      'linked_task_id': t.linkedTaskId,
      'linked_issue_id': t.linkedIssueId,
      'outcome_reflection': t.outcomeReflection,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> issueToJson(Issue t) => {
      'id': t.id,
      'title': t.title,
      'context': t.context,
      'initial_judgment': t.initialJudgment,
      'status': t.status,
      'resolved_at': t.resolvedAt?.toUtc().toIso8601String(),
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> dailyReviewToJson(DailyReview t) => {
      'id': t.id,
      'business_date': t.businessDate,
      'ai_helped': t.aiHelped,
      'ai_overreliance': t.aiOverreliance,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

Map<String, dynamic> focusRecordToJson(FocusRecord t) => {
      'id': t.id,
      'task_id': t.taskId,
      'label': t.label,
      'started_at': t.startedAt.toUtc().toIso8601String(),
      'ended_at': t.endedAt.toUtc().toIso8601String(),
      'duration_seconds': t.durationSeconds,
      'effective_seconds': t.effectiveSeconds,
      'shared_session_id': t.sharedSessionId,
      'source_device': t.sourceDevice,
      'independent': t.independent,
      'overlap_flag': t.overlapFlag,
      'deleted': t.deleted,
      'created_at': t.createdAt.toUtc().toIso8601String(),
      'updated_at': t.updatedAt.toUtc().toIso8601String(),
    };

String? _str(Map m, String k) => m[k] == null ? null : m[k].toString();
int _int(Map m, String k, [int fallback = 0]) {
  final v = m[k];
  if (v is int) return v;
  return int.tryParse(v?.toString() ?? '') ?? fallback;
}

bool _bool(Map m, String k, [bool fallback = false]) {
  final v = m[k];
  if (v is bool) return v;
  if (v is num) return v != 0;
  return fallback;
}

DateTime? _date(Map m, String k) {
  final v = _str(m, k);
  if (v == null || v.isEmpty) return null;
  return DateTime.tryParse(v)?.toUtc();
}

DateTime _dateOrNow(Map m, String k) => _date(m, k) ?? DateTime.now().toUtc();

Map<String, dynamic> decodeJsonObject(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is String && raw.isNotEmpty) {
    final v = jsonDecode(raw);
    if (v is Map<String, dynamic>) return v;
  }
  return <String, dynamic>{};
}

/// Apply an entity received from the server. The caller is responsible for
/// opening the transaction and updating EntityMeta + the sync cursor.
Future<void> applyServerEntity(
  AppDatabase db,
  String entityType,
  String entityId,
  Map<String, dynamic> data, {
  required bool deleted,
  required DateTime serverUpdatedAt,
}) async {
  final now = serverUpdatedAt;
  switch (entityType) {
    case 'task':
      if (deleted) {
        await (db.update(db.tasks)..where((t) => t.id.equals(entityId)))
            .write(TasksCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.tasks).insertOnConflictUpdate(TasksCompanion(
            id: Value(entityId),
            title: Value(_str(data, 'title') ?? ''),
            notes: Value(_str(data, 'notes') ?? ''),
            listId: Value(_str(data, 'list_id')),
            status: Value(_int(data, 'status')),
            priority: Value(_int(data, 'priority')),
            dueDate: Value(_str(data, 'due_date')),
            dueTime: Value(_str(data, 'due_time')),
            reminderAt: Value(_date(data, 'reminder_at')),
            recurrence: Value(_str(data, 'recurrence')),
            seriesId: Value(_str(data, 'series_id')),
            occurrenceDate: Value(_str(data, 'occurrence_date')),
            parentId: Value(_str(data, 'parent_id')),
            sortOrder: Value(_int(data, 'sort_order')),
            archived: Value(_bool(data, 'archived')),
            deleted: Value(false),
            completedAt: Value(_date(data, 'completed_at')),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'task_list':
      if (deleted) {
        await (db.update(db.taskLists)..where((t) => t.id.equals(entityId)))
            .write(TaskListsCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.taskLists).insertOnConflictUpdate(TaskListsCompanion(
            id: Value(entityId),
            name: Value(_str(data, 'name') ?? ''),
            color: Value(_str(data, 'color') ?? '#4F7DF3'),
            sortOrder: Value(_int(data, 'sort_order')),
            archived: Value(_bool(data, 'archived')),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'tag':
      if (deleted) {
        await (db.update(db.tags)..where((t) => t.id.equals(entityId)))
            .write(TagsCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.tags).insertOnConflictUpdate(TagsCompanion(
            id: Value(entityId),
            name: Value(_str(data, 'name') ?? ''),
            color: Value(_str(data, 'color') ?? '#7A8CA6'),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'task_tag':
      final taskId = _str(data, 'task_id') ?? '';
      final tagId = _str(data, 'tag_id') ?? '';
      if (taskId.isEmpty || tagId.isEmpty) return;
      if (deleted) {
        await (db.delete(db.taskTags)
              ..where((t) => t.taskId.equals(taskId) & t.tagId.equals(tagId)))
            .go();
        return;
      }
      await db.into(db.taskTags).insertOnConflictUpdate(TaskTagsCompanion(
            taskId: Value(taskId),
            tagId: Value(tagId),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'daily_focus':
      if (deleted) {
        await (db.update(db.dailyFoci)..where((t) => t.id.equals(entityId)))
            .write(DailyFociCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.dailyFoci).insertOnConflictUpdate(DailyFociCompanion(
            id: Value(entityId),
            businessDate: Value(_str(data, 'business_date') ?? todayBusinessDate()),
            taskId: Value(_str(data, 'task_id') ?? ''),
            sortOrder: Value(_int(data, 'sort_order')),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'decision':
      if (deleted) {
        await (db.update(db.decisions)..where((t) => t.id.equals(entityId)))
            .write(DecisionsCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.decisions).insertOnConflictUpdate(DecisionsCompanion(
            id: Value(entityId),
            businessDate: Value(_str(data, 'business_date') ?? todayBusinessDate()),
            slot: Value(_int(data, 'slot', 1)),
            decisionText: Value(_str(data, 'decision_text') ?? ''),
            rationale: Value(_str(data, 'rationale') ?? ''),
            aiParticipation: Value(_int(data, 'ai_participation')),
            linkedTaskId: Value(_str(data, 'linked_task_id')),
            linkedIssueId: Value(_str(data, 'linked_issue_id')),
            outcomeReflection: Value(_str(data, 'outcome_reflection') ?? ''),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'issue':
      if (deleted) {
        await (db.update(db.issues)..where((t) => t.id.equals(entityId)))
            .write(IssuesCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.issues).insertOnConflictUpdate(IssuesCompanion(
            id: Value(entityId),
            title: Value(_str(data, 'title') ?? ''),
            context: Value(_str(data, 'context') ?? ''),
            initialJudgment: Value(_str(data, 'initial_judgment') ?? ''),
            status: Value(_int(data, 'status')),
            resolvedAt: Value(_date(data, 'resolved_at')),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'daily_review':
      if (deleted) {
        await (db.update(db.dailyReviews)..where((t) => t.id.equals(entityId)))
            .write(DailyReviewsCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      await db.into(db.dailyReviews).insertOnConflictUpdate(DailyReviewsCompanion(
            id: Value(entityId),
            businessDate: Value(_str(data, 'business_date') ?? todayBusinessDate()),
            aiHelped: Value(_str(data, 'ai_helped') ?? ''),
            aiOverreliance: Value(_str(data, 'ai_overreliance') ?? ''),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
    case 'focus_record':
      if (deleted) {
        await (db.update(db.focusRecords)..where((t) => t.id.equals(entityId)))
            .write(FocusRecordsCompanion(deleted: const Value(true), updatedAt: Value(now)));
        return;
      }
      final started = _date(data, 'started_at') ?? now;
      await db.into(db.focusRecords).insertOnConflictUpdate(FocusRecordsCompanion(
            id: Value(entityId),
            taskId: Value(_str(data, 'task_id')),
            label: Value(_str(data, 'label') ?? ''),
            startedAt: Value(started),
            endedAt: Value(_date(data, 'ended_at') ?? started),
            durationSeconds: Value(_int(data, 'duration_seconds')),
            effectiveSeconds: Value(_int(data, 'effective_seconds', _int(data, 'duration_seconds'))),
            sharedSessionId: Value(_str(data, 'shared_session_id')),
            sourceDevice: Value(_str(data, 'source_device') ?? ''),
            independent: Value(_bool(data, 'independent', true)),
            overlapFlag: Value(_bool(data, 'overlap_flag')),
            deleted: Value(false),
            createdAt: Value(_dateOrNow(data, 'created_at')),
            updatedAt: Value(_dateOrNow(data, 'updated_at')),
          ));
  }
}
