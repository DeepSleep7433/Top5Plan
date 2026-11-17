import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/db/database.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../theme/app_theme.dart';
import 'common.dart';

Future<void> openTaskEditor(
  BuildContext context,
  WidgetRef ref, {
  Task? task,
  String? initialDueDate,
  String? parentId,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final size = MediaQuery.sizeOf(context);
      return Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: size.width > 700 ? 40 : 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760),
          child: TaskEditor(task: task, initialDueDate: initialDueDate, parentId: parentId),
        ),
      );
    },
  );
}

class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({super.key, this.task, this.initialDueDate, this.parentId});
  final Task? task;
  final String? initialDueDate;
  final String? parentId;

  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  late TextEditingController _title;
  late TextEditingController _notes;
  late TextEditingController _subtask;
  late TaskStatus _status;
  late TaskPriority _priority;
  String? _listId;
  String? _dueDate;
  String? _dueTime;
  DateTime? _reminderAt;
  String? _recurrence;
  Set<String> _tagIds = {};
  List<Task> _subtasks = [];
  bool _saving = false;
  bool _initializedTags = false;

  bool get isNew => widget.task == null;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? '');
    _notes = TextEditingController(text: t?.notes ?? '');
    _subtask = TextEditingController();
    _status = TaskStatus.fromValue(t?.status ?? 0);
    _priority = TaskPriority.fromValue(t?.priority ?? 0);
    _listId = t?.listId;
    _dueDate = t?.dueDate ?? widget.initialDueDate;
    _dueTime = t?.dueTime;
    _reminderAt = t?.reminderAt;
    _recurrence = t?.recurrence;
    if (t != null) _loadSubtasks(t.id);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _subtask.dispose();
    super.dispose();
  }

  Future<void> _loadSubtasks(String id) async {
    final rows = await ref.read(taskRepositoryProvider).subtasks(id);
    if (mounted) setState(() => _subtasks = rows);
  }

  Future<void> _loadTags(String id) async {
    final rows = await ref.read(taskRepositoryProvider).tagsForTask(id);
    if (mounted) {
      setState(() => _tagIds = rows.map((e) => e.tagId).toSet());
      _initializedTags = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.task != null && !_initializedTags) {
      _initializedTags = true;
      Future.microtask(() => _loadTags(widget.task!.id));
    }
    final lists = ref.watch(listsProvider).value ?? [];
    final tags = ref.watch(tagsProvider).value ?? [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(isNew ? '新建待办' : '编辑待办',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              if (!isNew)
                TextButton.icon(
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('删除'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 19),
                tooltip: '关闭',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _title,
                  autofocus: isNew,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: '要做什么？',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(hintText: '备注'),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ChoiceChip<TaskStatus>(
                      value: _status,
                      values: TaskStatus.values,
                      label: (v) => v.label,
                      onChanged: (v) => setState(() => _status = v),
                    ),
                    _ChoiceChip<TaskPriority>(
                      value: _priority,
                      values: TaskPriority.values,
                      label: (v) => '优先级 ${v.label}',
                      onChanged: (v) => setState(() => _priority = v),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: _listId,
                        decoration: const InputDecoration(
                          labelText: '清单',
                          prefixIcon: Icon(Icons.inbox_outlined, size: 18),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('无清单')),
                          for (final l in lists)
                            DropdownMenuItem<String?>(value: l.id, child: Text(l.name)),
                        ],
                        onChanged: (v) => setState(() => _listId = v),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: _recurrence,
                        decoration: const InputDecoration(
                          labelText: '重复',
                          prefixIcon: Icon(Icons.repeat, size: 18),
                        ),
                        items: const [
                          DropdownMenuItem<String?>(value: null, child: Text('不重复')),
                          DropdownMenuItem<String?>(value: 'daily', child: Text('每天')),
                          DropdownMenuItem<String?>(value: 'weekly', child: Text('每周')),
                          DropdownMenuItem<String?>(value: 'monthly', child: Text('每月')),
                        ],
                        onChanged: (v) => setState(() => _recurrence = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SectionCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    children: [
                      _FieldRow(
                        icon: Icons.event_outlined,
                        label: _dueDate == null ? '截止日期' : friendlyDate(_dueDate, withWeekday: true),
                        onTap: _pickDueDate,
                        trailing: _dueDate == null
                            ? null
                            : IconButton(
                                onPressed: () => setState(() => _dueDate = null),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                      ),
                      const Divider(),
                      _FieldRow(
                        icon: Icons.schedule_outlined,
                        label: _dueTime == null ? '具体时间（可选）' : _dueTime!,
                        onTap: _pickDueTime,
                        trailing: _dueTime == null
                            ? null
                            : IconButton(
                                onPressed: () => setState(() => _dueTime = null),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                      ),
                      const Divider(),
                      _FieldRow(
                        icon: Icons.notifications_none,
                        label: _reminderAt == null
                            ? '提醒（可选）'
                            : '提醒 ${_formatReminder(_reminderAt!)}',
                        onTap: _pickReminder,
                        trailing: _reminderAt == null
                            ? null
                            : IconButton(
                                onPressed: () => setState(() => _reminderAt = null),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (tags.isNotEmpty) ...[
                  Text('标签', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in tags)
                        FilterChip(
                          selected: _tagIds.contains(t.id),
                          label: Text(t.name),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _tagIds.add(t.id);
                            } else {
                              _tagIds.remove(t.id);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                if (widget.task != null && widget.task!.parentId == null) ...[
                  Text('子任务', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  for (final child in _subtasks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          TaskCheck(
                            done: child.status == TaskStatus.done.value,
                            onChanged: (v) async {
                              await ref
                                  .read(taskRepositoryProvider)
                                  .setTaskStatus(child.id, (v ?? false) ? TaskStatus.done : TaskStatus.todo);
                              await _loadSubtasks(widget.task!.id);
                            },
                          ),
                          Expanded(child: Text(child.title)),
                          IconButton(
                            onPressed: () async {
                              await ref.read(taskRepositoryProvider).deleteTaskGroup(child.id);
                              await _loadSubtasks(widget.task!.id);
                            },
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _subtask,
                          decoration: const InputDecoration(hintText: '添加子任务'),
                          onSubmitted: (_) => _addSubtask(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(onPressed: _addSubtask, icon: const Icon(Icons.add)),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(isNew ? '添加' : '保存'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addSubtask() async {
    final title = _subtask.text.trim();
    if (title.isEmpty || widget.task == null) return;
    await ref.read(taskRepositoryProvider).createTask(
          title: title,
          parentId: widget.task!.id,
          dueDate: _dueDate,
        );
    _subtask.clear();
    await _loadSubtasks(widget.task!.id);
  }

  Future<void> _pickDueDate() async {
    final initial = _dueDate == null ? DateTime.now() : DateTime.tryParse(_dueDate!) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _dueDate = businessDateOf(picked));
    }
  }

  Future<void> _pickDueTime() async {
    final initial = _dueTime == null
        ? TimeOfDay.now()
        : TimeOfDay(
            hour: int.parse(_dueTime!.split(':')[0]),
            minute: int.parse(_dueTime!.split(':')[1]),
          );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() {
        _dueTime =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
        if (_reminderAt == null && _dueDate != null) {
          final d = DateTime.parse(_dueDate!);
          _reminderAt = DateTime(d.year, d.month, d.day, picked.hour, picked.minute).toUtc();
        }
      });
    }
  }

  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final initial = _reminderAt?.toLocal() ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    setState(() {
      _reminderAt = DateTime(date.year, date.month, date.day, time.hour, time.minute).toUtc();
    });
  }

  String _formatReminder(DateTime d) {
    final l = d.toLocal();
    return '${l.month}月${l.day}日 ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      await showNotice(context, '请输入标题');
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(taskRepositoryProvider);
      final Task saved;
      if (isNew) {
        saved = await repo.createTask(
          title: title,
          notes: _notes.text.trim(),
          listId: _listId,
          status: _status,
          priority: _priority,
          dueDate: _dueDate,
          dueTime: _dueTime,
          reminderAt: _reminderAt,
          recurrence: _recurrence,
          parentId: widget.parentId,
        );
      } else {
        final t = widget.task!;
        saved = t.copyWith(
          title: title,
          notes: _notes.text.trim(),
          listId: Value(_listId),
          status: _status.value,
          priority: _priority.value,
          dueDate: Value(_dueDate),
          dueTime: Value(_dueTime),
          reminderAt: Value(_reminderAt),
          recurrence: Value(_recurrence),
        );
        await repo.updateTask(saved);
      }
      await repo.setTaskTags(saved.id, _tagIds.toList());
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (widget.task == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: const Text('父任务和子任务会作为一个可恢复的操作一起删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(taskRepositoryProvider).deleteTaskGroup(widget.task!.id);
    if (mounted) Navigator.pop(context);
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.muted),
            const SizedBox(width: 9),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _ChoiceChip<T> extends StatelessWidget {
  const _ChoiceChip({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final v in values) PopupMenuItem(value: v, child: Text(label(v))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label(value), style: const TextStyle(fontSize: 12.5)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 15),
          ],
        ),
      ),
    );
  }
}
