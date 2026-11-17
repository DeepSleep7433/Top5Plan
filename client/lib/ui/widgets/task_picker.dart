import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import 'common.dart';

Future<Task?> showTaskPicker(BuildContext context, WidgetRef ref, {String? title}) {
  return showDialog<Task>(
    context: context,
    builder: (context) => TaskPickerDialog(title: title ?? '选择任务'),
  );
}

class TaskPickerDialog extends ConsumerStatefulWidget {
  const TaskPickerDialog({super.key, required this.title});
  final String title;

  @override
  ConsumerState<TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends ConsumerState<TaskPickerDialog> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stream = ref.watch(taskRepositoryProvider).watchAllTasks(
          search: _query,
          includeDone: false,
          limit: 100,
        );
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索任务',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onChanged: (v) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 250), () {
                    if (mounted) setState(() => _query = v);
                  });
                },
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<Task>>(
                stream: stream,
                builder: (context, snapshot) {
                  final tasks = snapshot.data ?? [];
                  if (tasks.isEmpty) {
                    return const EmptyState(
                      icon: Icons.task_alt,
                      title: '没有可选任务',
                      message: '先创建一个未完成的任务',
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: tasks.length,
                    itemBuilder: (context, i) {
                      final t = tasks[i];
                      return ListTile(
                        dense: true,
                        leading: PriorityDot(TaskPriority.fromValue(t.priority)),
                        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (t.dueDate != null) friendlyDate(t.dueDate),
                            TaskStatus.fromValue(t.status).label,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => Navigator.pop(context, t),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> completeTaskWithPrompt(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  final repo = ref.read(taskRepositoryProvider);
  if (task.status == TaskStatus.done.value) {
    await repo.setTaskStatus(task.id, TaskStatus.todo);
    return;
  }
  final hasIncomplete = await repo.hasIncompleteSubtasks(task.id);
  if (!hasIncomplete) {
    await repo.setTaskStatus(task.id, TaskStatus.done);
    return;
  }
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('还有未完成的子任务'),
      content: const Text('要一并完成所有子任务吗？取消则本次不改变状态。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('一并完成')),
      ],
    ),
  );
  if (ok == true) {
    await repo.setTaskStatus(task.id, TaskStatus.done, completeChildren: true);
  }
}
