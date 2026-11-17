import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../db/repository.dart';
import '../models/domain.dart';
import '../sync/entity_codec.dart';

class ImportPreview {
  ImportPreview({
    required this.fileName,
    required this.exportedAt,
    required this.counts,
  });
  final String fileName;
  final String? exportedAt;
  final Map<String, int> counts;
}

class ExportService {
  ExportService(this.db, this.repository);
  final AppDatabase db;
  final TaskRepository repository;
  static const _uuid = Uuid();

  Future<Map<String, dynamic>> buildJsonExport() async {
    final tasks = await db.select(db.tasks).get();
    final lists = await db.select(db.taskLists).get();
    final tags = await db.select(db.tags).get();
    final taskTags = await db.select(db.taskTags).get();
    final dailyFoci = await db.select(db.dailyFoci).get();
    final decisions = await db.select(db.decisions).get();
    final issues = await db.select(db.issues).get();
    final reviews = await db.select(db.dailyReviews).get();
    final focus = await db.select(db.focusRecords).get();
    return {
      'format': 't5-json-export',
      'version': 1,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'tables': {
        'tasks': tasks.map(taskToJson).toList(),
        'task_lists': lists.map(taskListToJson).toList(),
        'tags': tags.map(tagToJson).toList(),
        'task_tags': taskTags.map(taskTagToJson).toList(),
        'daily_foci': dailyFoci.map(dailyFocusToJson).toList(),
        'decisions': decisions.map(decisionToJson).toList(),
        'issues': issues.map(issueToJson).toList(),
        'daily_reviews': reviews.map(dailyReviewToJson).toList(),
        'focus_records': focus.map(focusRecordToJson).toList(),
      },
    };
  }

  Future<String?> exportJson() async {
    final payload = await buildJsonExport();
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(payload));
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').substring(0, 19);
    return FilePicker.platform.saveFile(
      dialogTitle: '导出 T5 数据',
      fileName: 't5-export-$stamp.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
  }

  Future<String?> exportMarkdown() async {
    final decisions = await (db.select(db.decisions)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.businessDate), (t) => OrderingTerm.asc(t.slot)]))
        .get();
    final reviews = await (db.select(db.dailyReviews)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.businessDate)]))
        .get();
    final issues = await (db.select(db.issues)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    final b = StringBuffer('# T5 记录导出\n\n');
    b.writeln('导出时间（UTC）：${DateTime.now().toUtc().toIso8601String()}\n');
    b.writeln('## 关键决策\n');
    String? currentDate;
    for (final d in decisions) {
      if (d.businessDate != currentDate) {
        currentDate = d.businessDate;
        b.writeln('\n### $currentDate\n');
      }
      b.writeln('#### 决策 ${d.slot}');
      b.writeln(d.decisionText.isEmpty ? '（留空）' : d.decisionText);
      if (d.rationale.isNotEmpty) b.writeln('\n判断依据：${d.rationale}');
      b.writeln('\nAI 参与：${AiParticipation.fromValue(d.aiParticipation).label}');
      if (d.outcomeReflection.isNotEmpty) b.writeln('\n回看：${d.outcomeReflection}');
      b.writeln();
    }
    b.writeln('\n## 每日反思\n');
    for (final r in reviews) {
      b.writeln('### ${r.businessDate}');
      b.writeln('- AI 帮我完成：${r.aiHelped}');
      b.writeln('- 我交给了 AI 的思考：${r.aiOverreliance}\n');
    }
    b.writeln('\n## 问题箱\n');
    for (final i in issues) {
      b.writeln('### ${i.title}');
      if (i.context.isNotEmpty) b.writeln('\n背景：${i.context}');
      if (i.initialJudgment.isNotEmpty) b.writeln('\n初步判断：${i.initialJudgment}');
      b.writeln('\n状态：${IssueStatus.fromValue(i.status).label}\n');
    }
    final bytes = utf8.encode(b.toString());
    final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    return FilePicker.platform.saveFile(
      dialogTitle: '导出 Markdown 记录',
      fileName: 't5-records-$stamp.md',
      type: FileType.custom,
      allowedExtensions: ['md'],
      bytes: bytes,
    );
  }

  Future<(File, Map<String, dynamic>)?> pickImport() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 T5 JSON 导出文件',
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.single;
    final bytes = f.bytes ?? (f.path == null ? null : await File(f.path!).readAsBytes());
    if (bytes == null) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['format'] != 't5-json-export') {
      throw const FormatException('不是 T5 JSON 导出文件');
    }
    return (File(f.path ?? f.name), decoded);
  }

  ImportPreview preview(Map<String, dynamic> data, String fileName) {
    final tables = data['tables'] as Map<String, dynamic>? ?? const {};
    final counts = <String, int>{};
    for (final entry in tables.entries) {
      final v = entry.value;
      counts[entry.key] = v is List ? v.length : 0;
    }
    return ImportPreview(
      fileName: fileName,
      exportedAt: data['exported_at']?.toString(),
      counts: counts,
    );
  }

  /// Imports every record with a fresh UUID. Existing data is never
  /// overwritten. The whole import is one local transaction and is appended to
  /// the sync outbox.
  Future<int> importAsNew(Map<String, dynamic> data) async {
    final tables = data['tables'] as Map<String, dynamic>? ?? const {};
    List<Map<String, dynamic>> rows(String key) =>
        ((tables[key] as List?) ?? const []).cast<Map<String, dynamic>>();
    final listMap = <String, String>{};
    final tagMap = <String, String>{};
    final taskMap = <String, String>{};
    final issueMap = <String, String>{};
    final decisions = rows('decisions');
    final reviews = rows('daily_reviews');
    final focus = rows('focus_records');
    final dailyFoci = rows('daily_foci');
    final tasks = rows('tasks');
    final lists = rows('task_lists');
    final tags = rows('tags');
    final taskTags = rows('task_tags');
    final issues = rows('issues');
    for (final r in lists) {
      listMap[r['id']?.toString() ?? ''] = _uuid.v4();
    }
    for (final r in tags) {
      tagMap[r['id']?.toString() ?? ''] = _uuid.v4();
    }
    for (final r in tasks) {
      taskMap[r['id']?.toString() ?? ''] = _uuid.v4();
    }
    for (final r in issues) {
      issueMap[r['id']?.toString() ?? ''] = _uuid.v4();
    }
    final outbox = <({String type, String id, Map<String, dynamic> payload, bool deleted})>[];
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      for (final r in lists) {
        final old = r['id'].toString();
        final id = listMap[old]!;
        final row = TaskList(
          id: id,
          name: r['name']?.toString() ?? '导入清单',
          color: r['color']?.toString() ?? '#4F7DF3',
          sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
          archived: r['archived'] == true,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.taskLists).insert(row);
        outbox.add((type: 'task_list', id: id, payload: taskListToJson(row), deleted: false));
      }
      for (final r in tags) {
        final id = tagMap[r['id'].toString()]!;
        final row = Tag(
          id: id,
          name: r['name']?.toString() ?? '导入标签',
          color: r['color']?.toString() ?? '#7A8CA6',
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.tags).insert(row);
        outbox.add((type: 'tag', id: id, payload: tagToJson(row), deleted: false));
      }
      for (final r in tasks) {
        final old = r['id'].toString();
        final id = taskMap[old]!;
        final row = Task(
          id: id,
          title: r['title']?.toString() ?? '导入任务',
          notes: r['notes']?.toString() ?? '',
          listId: listMap[r['list_id']?.toString()],
          status: (r['status'] as num?)?.toInt() ?? 0,
          priority: (r['priority'] as num?)?.toInt() ?? 0,
          dueDate: r['due_date']?.toString(),
          dueTime: r['due_time']?.toString(),
          reminderAt: DateTime.tryParse(r['reminder_at']?.toString() ?? '')?.toUtc(),
          recurrence: r['recurrence']?.toString(),
          seriesId: taskMap[r['series_id']?.toString()],
          occurrenceDate: r['occurrence_date']?.toString(),
          parentId: taskMap[r['parent_id']?.toString()],
          sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
          archived: r['archived'] == true,
          deleted: false,
          completedAt: DateTime.tryParse(r['completed_at']?.toString() ?? '')?.toUtc(),
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.tasks).insert(row);
        outbox.add((type: 'task', id: id, payload: taskToJson(row), deleted: false));
      }
      for (final r in taskTags) {
        final taskId = taskMap[r['task_id']?.toString()];
        final tagId = tagMap[r['tag_id']?.toString()];
        if (taskId == null || tagId == null) continue;
        final row = TaskTag(
          taskId: taskId,
          tagId: tagId,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.taskTags).insert(row);
        final eid = _uuid.v5(Namespace.url.value, 't5:task-tag:$taskId:$tagId');
        outbox.add((type: 'task_tag', id: eid, payload: taskTagToJson(row), deleted: false));
      }
      for (final r in dailyFoci) {
        final taskId = taskMap[r['task_id']?.toString()];
        if (taskId == null) continue;
        final id = _uuid.v4();
        final row = DailyFociData(
          id: id,
          businessDate: r['business_date']?.toString() ?? todayBusinessDate(),
          taskId: taskId,
          sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.dailyFoci).insert(row);
        outbox.add((type: 'daily_focus', id: id, payload: dailyFocusToJson(row), deleted: false));
      }
      for (final r in decisions) {
        final id = _uuid.v4();
        final row = Decision(
          id: id,
          businessDate: r['business_date']?.toString() ?? todayBusinessDate(),
          slot: (r['slot'] as num?)?.toInt() ?? 1,
          decisionText: r['decision_text']?.toString() ?? '',
          rationale: r['rationale']?.toString() ?? '',
          aiParticipation: (r['ai_participation'] as num?)?.toInt() ?? 0,
          linkedTaskId: taskMap[r['linked_task_id']?.toString()],
          linkedIssueId: issueMap[r['linked_issue_id']?.toString()],
          outcomeReflection: r['outcome_reflection']?.toString() ?? '',
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.decisions).insert(row);
        outbox.add((type: 'decision', id: id, payload: decisionToJson(row), deleted: false));
      }
      for (final r in issues) {
        final id = issueMap[r['id'].toString()]!;
        final row = Issue(
          id: id,
          title: r['title']?.toString() ?? '导入问题',
          context: r['context']?.toString() ?? '',
          initialJudgment: r['initial_judgment']?.toString() ?? '',
          status: (r['status'] as num?)?.toInt() ?? 0,
          resolvedAt: DateTime.tryParse(r['resolved_at']?.toString() ?? '')?.toUtc(),
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.issues).insert(row);
        outbox.add((type: 'issue', id: id, payload: issueToJson(row), deleted: false));
      }
      for (final r in reviews) {
        final id = _uuid.v4();
        final row = DailyReview(
          id: id,
          businessDate: r['business_date']?.toString() ?? todayBusinessDate(),
          aiHelped: r['ai_helped']?.toString() ?? '',
          aiOverreliance: r['ai_overreliance']?.toString() ?? '',
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.dailyReviews).insert(row);
        outbox.add((type: 'daily_review', id: id, payload: dailyReviewToJson(row), deleted: false));
      }
      for (final r in focus) {
        final id = _uuid.v4();
        final start = DateTime.tryParse(r['started_at']?.toString() ?? '')?.toUtc() ?? now;
        final end = DateTime.tryParse(r['ended_at']?.toString() ?? '')?.toUtc() ?? start;
        final duration = (r['duration_seconds'] as num?)?.toInt() ?? end.difference(start).inSeconds;
        final row = FocusRecord(
          id: id,
          taskId: taskMap[r['task_id']?.toString()],
          label: r['label']?.toString() ?? '',
          startedAt: start,
          endedAt: end,
          durationSeconds: duration,
          effectiveSeconds: (r['effective_seconds'] as num?)?.toInt() ?? duration,
          sharedSessionId: null,
          sourceDevice: 'import',
          independent: r['independent'] != false,
          overlapFlag: r['overlap_flag'] == true,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        );
        await db.into(db.focusRecords).insert(row);
        outbox.add((type: 'focus_record', id: id, payload: focusRecordToJson(row), deleted: false));
      }
    });
    await repository.enqueueRawEntities(outbox);
    return outbox.length;
  }
}
