import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/db/database.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/task_editor.dart';
import '../widgets/task_picker.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});
  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  String _query = '';
  int _view = 0;
  int? _statusFilter;
  String? _listFilter;
  bool _trash = false;
  bool _selectionMode = false;
  Set<String> _selected = {};
  String? _detailId;
  int _limit = 120;
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  bool _weekView = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            openTaskEditor(context, ref),
        const SingleActivator(LogicalKeyboardKey.slash): () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_selectionMode) {
            setState(() {
              _selectionMode = false;
              _selected.clear();
            });
          } else {
            setState(() => _detailId = null);
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            _header(context),
            _toolbar(context),
            if (_selectionMode) _batchBar(context),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final main = switch (_view) {
                  1 => _BoardView(
                      query: _query,
                      status: _statusFilter,
                      listId: _listFilter,
                      onOpen: (task) => _open(task),
                      onSelected: (task) => setState(() => _detailId = task.id),
                      onStatus: (task, status) => _changeStatus(task, status),
                    ),
                  2 => _CalendarView(
                      weekView: _weekView,
                      month: _calendarMonth,
                      onViewChanged: (week) => setState(() => _weekView = week),
                      onMonthChanged: (m) => setState(() => _calendarMonth = m),
                      onOpen: (task) => _open(task),
                      onReschedule: (task, date) =>
                          ref.read(taskRepositoryProvider).updateTask(
                                task.copyWith(
                                  dueDate: Value(date),
                                  occurrenceDate: Value(task.recurrence == null ? task.occurrenceDate : date),
                                ),
                              ),
                    ),
                  _ => _ListView(
                      query: _query,
                      status: _statusFilter,
                      listId: _listFilter,
                      trash: _trash,
                      limit: _limit,
                      selected: _selected,
                      selectionMode: _selectionMode,
                      selectedDetail: _detailId,
                      onToggle: (task) => _toggleSelect(task),
                      onOpen: (task) => _open(task),
                      onDetail: (task) => setState(() => _detailId = task.id),
                      onCompleted: (task) => completeTaskWithPrompt(context, ref, task),
                      onLoadMore: () => setState(() => _limit += 120),
                    ),
                };
                if (!wide || _detailId == null) return main;
                return Row(
                  children: [
                    Expanded(child: main),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 360,
                      child: TaskDetailPane(
                        taskId: _detailId!,
                        onClose: () => setState(() => _detailId = null),
                        onEdit: (task) => _open(task),
                        onCompleted: (task) => completeTaskWithPrompt(context, ref, task),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_trash ? '回收站' : '待办',
                    style: Theme.of(context).textTheme.headlineLarge),
                const SizedBox(height: 3),
                Text(
                  _trash ? '删除的任务保留在原处，可恢复' : '列表、看板、日历共享同一批任务',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SyncStatusChip(),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: () => openTaskEditor(context, ref),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建待办'),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final lists = ref.watch(listsProvider).value ?? [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.view_list_outlined, size: 17), label: Text('列表')),
              ButtonSegment(value: 1, icon: Icon(Icons.view_kanban_outlined, size: 17), label: Text('看板')),
              ButtonSegment(value: 2, icon: Icon(Icons.calendar_month_outlined, size: 17), label: Text('日历')),
            ],
            selected: {_view},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() {
              _view = v.first;
              _selectionMode = false;
              _selected.clear();
            }),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12.5)),
            ),
          ),
          SizedBox(
            width: 250,
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  if (mounted) setState(() => _query = v);
                });
              },
              decoration: InputDecoration(
                hintText: '搜索标题或备注',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close, size: 16),
                      ),
              ),
            ),
          ),
          DropdownButton<int?>(
            value: _statusFilter,
            hint: const Text('状态'),
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem<int?>(value: null, child: Text('全部状态')),
              DropdownMenuItem<int?>(value: 0, child: Text('未开始')),
              DropdownMenuItem<int?>(value: 1, child: Text('进行中')),
              DropdownMenuItem<int?>(value: 2, child: Text('已完成')),
            ],
            onChanged: (v) => setState(() => _statusFilter = v),
          ),
          DropdownButton<String?>(
            value: _listFilter,
            hint: const Text('清单'),
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('全部清单')),
              for (final l in lists) DropdownMenuItem<String?>(value: l.id, child: Text(l.name)),
            ],
            onChanged: (v) => setState(() => _listFilter = v),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _trash = !_trash;
              _view = 0;
              _detailId = null;
            }),
            icon: Icon(_trash ? Icons.arrow_back : Icons.delete_outline, size: 16),
            label: Text(_trash ? '返回' : '回收站'),
          ),
          if (!_trash)
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _selectionMode = !_selectionMode;
                _selected.clear();
              }),
              icon: const Icon(Icons.checklist, size: 16),
              label: const Text('批量'),
            ),
        ],
      ),
    );
  }

  Widget _batchBar(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.blueSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text('已选择 ${_selected.length} 项',
              style: const TextStyle(fontSize: 12.5, color: AppColors.blue)),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _selected.clear()),
            child: const Text('清空'),
          ),
          TextButton.icon(
            onPressed: _selected.isEmpty ? null : _batchComplete,
            icon: const Icon(Icons.check, size: 16),
            label: const Text('完成'),
          ),
          TextButton.icon(
            onPressed: _selected.isEmpty ? null : _batchArchive,
            icon: const Icon(Icons.archive_outlined, size: 16),
            label: const Text('归档'),
          ),
          TextButton.icon(
            onPressed: _selected.isEmpty ? null : _batchDelete,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('删除'),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          ),
        ],
      ),
    );
  }

  Future<void> _open(Task task) async {
    setState(() => _detailId = task.id);
    await openTaskEditor(context, ref, task: task);
  }

  Future<void> _toggleSelect(Task task) async {
    setState(() {
      _selectionMode = true;
      if (_selected.contains(task.id)) {
        _selected.remove(task.id);
      } else {
        _selected.add(task.id);
      }
    });
  }

  Future<void> _changeStatus(Task task, TaskStatus status) async {
    if (status == TaskStatus.done && task.status != TaskStatus.done.value) {
      await completeTaskWithPrompt(context, ref, task);
    } else {
      await ref.read(taskRepositoryProvider).setTaskStatus(task.id, status);
    }
  }

  Future<void> _batchComplete() async {
    final tasks = await Future.wait(_selected.map(ref.read(taskRepositoryProvider).getTask));
    for (final task in tasks.whereType<Task>()) {
      if (await ref.read(taskRepositoryProvider).hasIncompleteSubtasks(task.id)) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('部分任务含有未完成子任务'),
            content: const Text('批量完成会同时完成所有子任务，是否继续？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续')),
            ],
          ),
        );
        if (ok != true) return;
        break;
      }
    }
    await ref.read(taskRepositoryProvider).batchComplete(_selected.toList());
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  Future<void> _batchArchive() async {
    await ref.read(taskRepositoryProvider).archiveTasks(_selected.toList());
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  Future<void> _batchDelete() async {
    for (final id in _selected.toList()) {
      await ref.read(taskRepositoryProvider).deleteTaskGroup(id);
    }
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }
}

class _ListView extends ConsumerWidget {
  const _ListView({
    required this.query,
    required this.status,
    required this.listId,
    required this.trash,
    required this.limit,
    required this.selected,
    required this.selectionMode,
    required this.selectedDetail,
    required this.onToggle,
    required this.onOpen,
    required this.onDetail,
    required this.onCompleted,
    required this.onLoadMore,
  });
  final String query;
  final int? status;
  final String? listId;
  final bool trash;
  final int limit;
  final Set<String> selected;
  final bool selectionMode;
  final String? selectedDetail;
  final ValueChanged<Task> onToggle;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onDetail;
  final ValueChanged<Task> onCompleted;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stream = ref.watch(taskRepositoryProvider).watchAllTasks(
          search: query,
          status: status?.toString(),
          listId: listId,
          limit: limit,
          trash: trash,
        );
    return StreamBuilder<List<Task>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final tasks = snapshot.data ?? [];
        if (tasks.isEmpty) {
          return EmptyState(
            icon: trash ? Icons.delete_outline : Icons.task_alt,
            title: trash ? '回收站为空' : (query.isEmpty ? '还没有待办' : '没有匹配的任务'),
            message: query.isEmpty && !trash ? '用顶部快速添加，或按 Ctrl+N 新建' : null,
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 300 && tasks.length >= limit) onLoadMore();
            return false;
          },
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: tasks.length,
            itemBuilder: (context, i) {
              final t = tasks[i];
              return _TaskRow(
                task: t,
                selected: selectedDetail == t.id,
                checked: selected.contains(t.id),
                selectionMode: selectionMode,
                trash: trash,
                onToggle: () => onToggle(t),
                onOpen: () => onOpen(t),
                onDetail: () => onDetail(t),
                onCompleted: () => onCompleted(t),
                onRestore: () => ref.read(taskRepositoryProvider).restoreTaskGroup(t.id),
              );
            },
          ),
        );
      },
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.selected,
    required this.checked,
    required this.selectionMode,
    required this.trash,
    required this.onToggle,
    required this.onOpen,
    required this.onDetail,
    required this.onCompleted,
    required this.onRestore,
  });
  final Task task;
  final bool selected;
  final bool checked;
  final bool selectionMode;
  final bool trash;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onDetail;
  final VoidCallback onCompleted;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final status = TaskStatus.fromValue(task.status);
    final done = status == TaskStatus.done;
    return Material(
      color: selected ? AppColors.blueSoft.withValues(alpha: 0.65) : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: selectionMode ? onToggle : onDetail,
        onDoubleTap: onOpen,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Row(
            children: [
              if (selectionMode)
                Checkbox(
                  value: checked,
                  onChanged: (_) => onToggle(),
                  visualDensity: VisualDensity.compact,
                )
              else if (!trash)
                TaskCheck(done: done, onChanged: (_) => onCompleted())
              else
                const SizedBox(width: 30),
              PriorityDot(TaskPriority.fromValue(task.priority)),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        decoration: done ? TextDecoration.lineThrough : null,
                        color: done ? AppColors.muted : null,
                      ),
                    ),
                    if (task.dueDate != null || task.recurrence != null || task.notes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          [
                            if (task.dueDate != null)
                              '${friendlyDate(task.dueDate)}${task.dueTime == null ? '' : ' ${task.dueTime}'}',
                            if (task.recurrence != null) _recurrenceLabel(task.recurrence),
                            if (task.notes.isNotEmpty) task.notes.replaceAll('\n', ' '),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.muted),
                        ),
                      ),
                  ],
                ),
              ),
              if (status == TaskStatus.doing)
                const StatusPill(label: '进行中', color: AppColors.blue),
              if (trash)
                TextButton(onPressed: onRestore, child: const Text('恢复'))
              else
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (value) async {
                    if (value == 'edit') onOpen();
                    if (value == 'complete') onCompleted();
                    if (value == 'doing') {
                      await refSetStatus(context, task, TaskStatus.doing);
                    }
                    if (value == 'archive') {
                      // ignore: use_build_context_synchronously
                      final ref = ProviderScope.containerOf(context);
                      await ref.read(taskRepositoryProvider).archiveTasks([task.id]);
                    }
                    if (value == 'delete') {
                      final ref = ProviderScope.containerOf(context);
                      await ref.read(taskRepositoryProvider).deleteTaskGroup(task.id);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    if (!done) const PopupMenuItem(value: 'complete', child: Text('完成')),
                    if (status == TaskStatus.todo)
                      const PopupMenuItem(value: 'doing', child: Text('标记进行中')),
                    const PopupMenuItem(value: 'archive', child: Text('归档')),
                    const PopupMenuItem(value: 'delete', child: Text('移到回收站')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _recurrenceLabel(String? r) => switch (r) {
        'daily' => '每天',
        'weekly' => '每周',
        'monthly' => '每月',
        _ => '',
      };

  static Future<void> refSetStatus(BuildContext context, Task task, TaskStatus status) async {
    final container = ProviderScope.containerOf(context);
    await container.read(taskRepositoryProvider).setTaskStatus(task.id, status);
  }
}

class _BoardView extends ConsumerWidget {
  const _BoardView({
    required this.query,
    required this.status,
    required this.listId,
    required this.onOpen,
    required this.onSelected,
    required this.onStatus,
  });
  final String query;
  final int? status;
  final String? listId;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onSelected;
  final void Function(Task, TaskStatus) onStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stream = ref.watch(taskRepositoryProvider).watchAllTasks(
          search: query,
          listId: listId,
          limit: 500,
        );
    return StreamBuilder<List<Task>>(
      stream: stream,
      builder: (context, snapshot) {
        final tasks = snapshot.data ?? [];
        return LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 850;
          final columns = TaskStatus.values.map((s) {
            final items = tasks.where((t) => t.status == s.value).toList();
            return _BoardColumn(
              status: s,
              tasks: items,
              compact: compact,
              onOpen: onOpen,
              onSelected: onSelected,
              onStatus: onStatus,
            );
          }).toList();
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final c in columns) ...[
                  SizedBox(width: compact ? 280 : (constraints.maxWidth - 80) / 3, child: c),
                  if (c != columns.last) const SizedBox(width: 12),
                ],
              ],
            ),
          );
        });
      },
    );
  }
}

class _BoardColumn extends StatelessWidget {
  const _BoardColumn({
    required this.status,
    required this.tasks,
    required this.compact,
    required this.onOpen,
    required this.onSelected,
    required this.onStatus,
  });
  final TaskStatus status;
  final List<Task> tasks;
  final bool compact;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onSelected;
  final void Function(Task, TaskStatus) onStatus;

  @override
  Widget build(BuildContext context) {
    return DragTarget<Task>(
      onAcceptWithDetails: (details) => onStatus(details.data, status),
      builder: (context, candidate, rejected) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: candidate.isNotEmpty
                ? AppColors.blueSoft.withValues(alpha: 0.6)
                : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: candidate.isNotEmpty
                  ? AppColors.blue.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    switch (status) {
                      TaskStatus.todo => Icons.radio_button_unchecked,
                      TaskStatus.doing => Icons.timelapse,
                      TaskStatus.done => Icons.check_circle_outline,
                    },
                    size: 16,
                    color: status == TaskStatus.doing ? AppColors.blue : AppColors.muted,
                  ),
                  const SizedBox(width: 7),
                  Text(status.label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const Spacer(),
                  Text('${tasks.length}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                ],
              ),
              const SizedBox(height: 8),
              if (tasks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('拖动任务到这里',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: AppColors.muted)),
                )
              else
                for (final task in tasks)
                  Draggable<Task>(
                    data: task,
                    feedback: Material(
                      elevation: 8,
                      borderRadius: BorderRadius.circular(9),
                      child: Container(
                        width: compact ? 250 : 300,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(task.title, maxLines: 2),
                      ),
                    ),
                    childWhenDragging: Opacity(opacity: 0.35, child: _BoardCard(task: task, onOpen: onOpen, onSelected: onSelected)),
                    child: _BoardCard(task: task, onOpen: onOpen, onSelected: onSelected),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _BoardCard extends StatelessWidget {
  const _BoardCard({required this.task, required this.onOpen, required this.onSelected});
  final Task task;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onSelected;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 7),
      child: InkWell(
        onTap: () => onSelected(task),
        onDoubleTap: () => onOpen(task),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.title, maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 7),
              Row(
                children: [
                  PriorityDot(TaskPriority.fromValue(task.priority)),
                  if (task.dueDate != null) ...[
                    const SizedBox(width: 4),
                    Text(friendlyDate(task.dueDate),
                        style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                  ],
                  const Spacer(),
                  if (task.recurrence != null)
                    const Icon(Icons.repeat, size: 13, color: AppColors.muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarView extends ConsumerWidget {
  const _CalendarView({
    required this.weekView,
    required this.month,
    required this.onViewChanged,
    required this.onMonthChanged,
    required this.onOpen,
    required this.onReschedule,
  });
  final bool weekView;
  final DateTime month;
  final ValueChanged<bool> onViewChanged;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<Task> onOpen;
  final void Function(Task, String) onReschedule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final start = weekView ? _startOfWeek(DateTime.now()) : DateTime(month.year, month.month, 1);
    final end = weekView ? start.add(const Duration(days: 6)) : DateTime(month.year, month.month + 1, 0);
    final stream = ref
        .watch(taskRepositoryProvider)
        .watchTasksInRange(businessDateOf(start), businessDateOf(end));
    return StreamBuilder<List<Task>>(
      stream: stream,
      builder: (context, snapshot) {
        final tasks = snapshot.data ?? [];
        final byDay = <String, List<Task>>{};
        for (final t in tasks) {
          if (t.dueDate != null) byDay.putIfAbsent(t.dueDate!, () => []).add(t);
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => onMonthChanged(
                        weekView ? start.subtract(const Duration(days: 7)) : DateTime(month.year, month.month - 1)),
                    icon: const Icon(Icons.chevron_left, size: 18),
                  ),
                  Text(
                    weekView
                        ? '${start.month}月${start.day}日 – ${end.month}月${end.day}日'
                        : '${month.year} 年 ${month.month} 月',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  IconButton(
                    onPressed: () => onMonthChanged(
                        weekView ? start.add(const Duration(days: 7)) : DateTime(month.year, month.month + 1)),
                    icon: const Icon(Icons.chevron_right, size: 18),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => onMonthChanged(DateTime.now()),
                    child: const Text('今天'),
                  ),
                  const Spacer(),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('月')),
                      ButtonSegment(value: true, label: Text('周')),
                    ],
                    selected: {weekView},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => onViewChanged(v.first),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: weekView
                    ? _WeekGrid(start: start, byDay: byDay, onOpen: onOpen, onReschedule: onReschedule)
                    : _MonthGrid(month: month, byDay: byDay, onOpen: onOpen, onReschedule: onReschedule),
              ),
            ),
          ],
        );
      },
    );
  }

  static DateTime _startOfWeek(DateTime d) {
    final local = DateTime(d.year, d.month, d.day);
    return local.subtract(Duration(days: local.weekday - 1));
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.byDay,
    required this.onOpen,
    required this.onReschedule,
  });
  final DateTime month;
  final Map<String, List<Task>> byDay;
  final ValueChanged<Task> onOpen;
  final void Function(Task, String) onReschedule;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final gridStart = first.subtract(Duration(days: first.weekday - 1));
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Column(
      children: [
        Row(
          children: [
            for (final w in weekdays)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(w,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                ),
              ),
          ],
        ),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 5,
              mainAxisSpacing: 5,
              childAspectRatio: 1.15,
            ),
            itemCount: 42,
            itemBuilder: (context, i) {
              final date = gridStart.add(Duration(days: i));
              final key = businessDateOf(date);
              final tasks = byDay[key] ?? [];
              final inMonth = date.month == month.month;
              return DragTarget<Task>(
                onAcceptWithDetails: (d) => onReschedule(d.data, key),
                builder: (context, candidate, rejected) => Container(
                  decoration: BoxDecoration(
                    color: !inMonth
                        ? Colors.transparent
                        : date.day == DateTime.now().day && date.month == DateTime.now().month
                            ? AppColors.blueSoft
                            : Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: candidate.isNotEmpty
                          ? AppColors.blue
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  padding: const EdgeInsets.all(5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${date.day}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: date.day == DateTime.now().day ? FontWeight.w700 : FontWeight.w500,
                            color: inMonth ? null : AppColors.muted.withValues(alpha: 0.5),
                          )),
                      const SizedBox(height: 2),
                      for (final t in tasks.take(3))
                        GestureDetector(
                          onTap: () => onOpen(t),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: (t.status == 2 ? AppColors.muted : AppColors.blue)
                                  .withValues(alpha: 0.11),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: t.status == 2 ? AppColors.muted : AppColors.blue,
                                  decoration: t.status == 2 ? TextDecoration.lineThrough : null,
                                )),
                          ),
                        ),
                      if (tasks.length > 3)
                        Text('+${tasks.length - 3}',
                            style: const TextStyle(fontSize: 9, color: AppColors.muted)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WeekGrid extends StatelessWidget {
  const _WeekGrid({
    required this.start,
    required this.byDay,
    required this.onOpen,
    required this.onReschedule,
  });
  final DateTime start;
  final Map<String, List<Task>> byDay;
  final ValueChanged<Task> onOpen;
  final void Function(Task, String) onReschedule;

  @override
  Widget build(BuildContext context) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < 7; i++) ...[
          Expanded(
            child: DragTarget<Task>(
              onAcceptWithDetails: (d) => onReschedule(d.data, businessDateOf(start.add(Duration(days: i)))),
              builder: (context, candidate, rejected) {
                final date = start.add(Duration(days: i));
                final key = businessDateOf(date);
                final tasks = byDay[key] ?? [];
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: candidate.isNotEmpty
                        ? AppColors.blueSoft
                        : Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${weekdays[i]} ${date.month}/${date.day}',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final t in tasks)
                              Card(
                                margin: const EdgeInsets.only(bottom: 5),
                                child: InkWell(
                                  onTap: () => onOpen(t),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.all(7),
                                    child: Text(t.title,
                                        maxLines: 3,
                                        style: const TextStyle(fontSize: 11)),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class TaskDetailPane extends ConsumerWidget {
  const TaskDetailPane({
    super.key,
    required this.taskId,
    required this.onClose,
    required this.onEdit,
    required this.onCompleted,
  });
  final String taskId;
  final VoidCallback onClose;
  final ValueChanged<Task> onEdit;
  final ValueChanged<Task> onCompleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<Task?>(
      stream: ref.watch(taskRepositoryProvider).watchTask(taskId),
      builder: (context, snapshot) {
        final task = snapshot.data;
        if (task == null) {
          return const EmptyState(icon: Icons.task_alt, title: '任务不存在');
        }
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('任务详情', style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
              ],
            ),
            const SizedBox(height: 12),
            Text(task.title, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 10),
            if (task.notes.isNotEmpty)
              Text(task.notes, style: const TextStyle(fontSize: 13, height: 1.5)),
            const SizedBox(height: 16),
            _DetailLine(icon: Icons.circle_outlined, text: TaskStatus.fromValue(task.status).label),
            _DetailLine(icon: Icons.flag_outlined, text: '优先级：${TaskPriority.fromValue(task.priority).label}'),
            _DetailLine(
              icon: Icons.event_outlined,
              text: task.dueDate == null
                  ? '无截止日期'
                  : '${friendlyDate(task.dueDate, withWeekday: true)}${task.dueTime == null ? '' : ' ${task.dueTime}'}',
            ),
            if (task.recurrence != null)
              _DetailLine(icon: Icons.repeat, text: '重复：${task.recurrence}'),
            if (task.reminderAt != null)
              _DetailLine(
                  icon: Icons.notifications_none,
                  text: '提醒：${ref.watch(clockProvider).formatDateTime(task.reminderAt!)}'),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => onCompleted(task),
                    child: Text(task.status == 2 ? '重新打开' : '完成'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => onEdit(task),
                  child: const Text('编辑'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}
