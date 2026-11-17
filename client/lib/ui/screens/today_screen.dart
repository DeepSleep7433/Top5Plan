import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/task_editor.dart';
import '../widgets/task_picker.dart';

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({
    super.key,
    required this.onNavigate,
    this.embedded = false,
  });
  final ValueChanged<int> onNavigate;
  final bool embedded;

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  final _quickAdd = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _quickAdd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(clockProvider);
    final date = ref.watch(todayProvider);
    final focusAsync = ref.watch(focusTasksProvider(date));
    final dueAsync = ref.watch(todayDueProvider(date));
    final seconds = ref.watch(todayFocusSecondsProvider).value ?? 0;
    final completed = ref.watch(todayCompletedProvider).value ?? 0;
    final decisions = ref.watch(decisionsProvider(date)).value ?? [];

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('今日',
                              style: Theme.of(context).textTheme.headlineLarge),
                          const SizedBox(height: 4),
                          Text(
                            '${clock.now().month} 月 ${clock.now().day} 日 · ${clock.weekday(date)}',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    const SyncStatusChip(),
                  ],
                ),
                const SizedBox(height: 18),
                _QuickAdd(
                  controller: _quickAdd,
                  busy: _adding,
                  onAdd: _addQuick,
                  onIssue: _quickIssue,
                ),
                const SizedBox(height: 14),
                _MiniStats(
                  seconds: seconds,
                  completed: completed,
                  onFocus: () => widget.onNavigate(4),
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 860;
              final focusCard = _FocusCard(
                date: date,
                tasks: focusAsync.value ?? [],
                loading: focusAsync.isLoading,
                onPick: () => _pickFocus(date),
                onCompleted: (task) => completeTaskWithPrompt(context, ref, task),
                onRemove: (focusId) =>
                    ref.read(taskRepositoryProvider).removeFocusTask(focusId),
                onOpen: (task) => openTaskEditor(context, ref, task: task),
                onReorder: (oldIndex, newIndex) {
                  final ids = (focusAsync.value ?? []).map((e) => e.id).toList();
                  if (newIndex > oldIndex) newIndex -= 1;
                  final id = ids.removeAt(oldIndex);
                  ids.insert(newIndex, id);
                  ref.read(taskRepositoryProvider).reorderFocusTasksByTaskIds(date, ids);
                },
              );
              final dueCard = _DueCard(
                tasks: dueAsync.value ?? [],
                focusedIds: (focusAsync.value ?? []).map((e) => e.id).toSet(),
                onCompleted: (task) => completeTaskWithPrompt(context, ref, task),
                onOpen: (task) => openTaskEditor(context, ref, task: task),
                onCreate: () => openTaskEditor(context, ref, initialDueDate: date),
              );
              final side = Column(
                children: [
                  _ReviewEntry(
                    date: date,
                    filled: decisions.where((d) => d.decisionText.trim().isNotEmpty).length,
                    onOpen: () => widget.onNavigate(3),
                  ),
                  const SizedBox(height: 14),
                  _YesterdayCandidates(
                    date: date,
                    onAdd: (task) => _addFocus(date, task),
                  ),
                ],
              );
              if (!wide) {
                return Column(
                  children: [
                    focusCard,
                    const SizedBox(height: 14),
                    dueCard,
                    const SizedBox(height: 14),
                    side,
                    const SizedBox(height: 24),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(children: [focusCard, const SizedBox(height: 14), dueCard]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: side),
                ],
              );
            }),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 30)),
      ],
    );
  }

  Future<void> _addQuick() async {
    final title = _quickAdd.text.trim();
    if (title.isEmpty) return;
    setState(() => _adding = true);
    try {
      final date = ref.read(todayProvider);
      await ref.read(taskRepositoryProvider).createTask(title: title, dueDate: date);
      _quickAdd.clear();
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _pickFocus(String date) async {
    final task = await showTaskPicker(context, ref, title: '加入今日重点');
    if (task == null) return;
    await _addFocus(date, task);
  }

  Future<void> _addFocus(String date, Task task) async {
    try {
      await ref.read(taskRepositoryProvider).addFocusTask(date, task.id);
    } on StateError catch (e) {
      if (mounted) {
        await showNotice(context, e.message == 'today_focus_limit' ? '今日重点最多 5 项' : e.toString());
      }
    }
  }

  Future<void> _quickIssue() async {
    final title = TextEditingController();
    final contextText = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('记下一个问题'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(hintText: '问题标题（只需这一项也可保存）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contextText,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(hintText: '补充背景（可选）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (result == true && title.text.trim().isNotEmpty) {
      await ref.read(taskRepositoryProvider).createIssue(
            title: title.text.trim(),
            context: contextText.text.trim(),
          );
    }
    title.dispose();
    contextText.dispose();
  }
}

class _QuickAdd extends StatelessWidget {
  const _QuickAdd({
    required this.controller,
    required this.busy,
    required this.onAdd,
    required this.onIssue,
  });
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback onIssue;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 5, 7, 5),
      child: Row(
        children: [
          const Icon(Icons.add_circle_outline, size: 20, color: AppColors.blue),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: controller,
              onSubmitted: (_) => onAdd(),
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: '快速记录一个待办，回车保存到本机',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          IconButton(
            onPressed: onIssue,
            tooltip: '记入问题箱',
            icon: const Icon(Icons.help_outline, size: 19),
          ),
          FilledButton(
            onPressed: busy ? null : onAdd,
            child: busy
                ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('添加'),
          ),
        ],
      ),
    );
  }
}

class _MiniStats extends StatelessWidget {
  const _MiniStats({required this.seconds, required this.completed, required this.onFocus});
  final int seconds;
  final int completed;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _MiniStat(
          icon: Icons.timer_outlined,
          value: formatDuration(seconds),
          label: '今日专注',
          onTap: onFocus,
        ),
        const SizedBox(width: 10),
        _MiniStat(
          icon: Icons.check_circle_outline,
          value: '$completed',
          label: '今日完成',
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.icon, required this.value, required this.label, this.onTap});
  final IconData icon;
  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: AppColors.muted),
            const SizedBox(width: 6),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}

class _FocusCard extends StatelessWidget {
  const _FocusCard({
    required this.date,
    required this.tasks,
    required this.loading,
    required this.onPick,
    required this.onCompleted,
    required this.onRemove,
    required this.onOpen,
    required this.onReorder,
  });
  final String date;
  final List<Task> tasks;
  final bool loading;
  final VoidCallback onPick;
  final ValueChanged<Task> onCompleted;
  final ValueChanged<String> onRemove;
  final ValueChanged<Task> onOpen;
  final ReorderCallback onReorder;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(
            '今日重点',
            subtitle: '从待办中选择最多 5 项，不自动占满',
            trailing: TextButton.icon(
              onPressed: tasks.length >= 5 ? null : onPick,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('选择'),
            ),
          ),
          const SizedBox(height: 10),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (tasks.isEmpty)
            InkWell(
              onTap: onPick,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(
                  color: AppColors.blueSoft.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.filter_alt_outlined, color: AppColors.blue, size: 22),
                    SizedBox(height: 6),
                    Text('选择今天真正重要的 1–5 件事',
                        style: TextStyle(fontSize: 12.5, color: AppColors.blue)),
                  ],
                ),
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: true,
              onReorder: onReorder,
              children: [
                for (var i = 0; i < tasks.length; i++)
                  _FocusRow(
                    key: ValueKey(tasks[i].id),
                    index: i,
                    task: tasks[i],
                    onCompleted: () => onCompleted(tasks[i]),
                    onRemove: () => onRemove(tasks[i].id),
                    onOpen: () => onOpen(tasks[i]),
                  ),
              ],
            ),
          if (tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${tasks.length} / 5',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            ),
        ],
      ),
    );
  }
}

class _FocusRow extends StatelessWidget {
  const _FocusRow({
    super.key,
    required this.index,
    required this.task,
    required this.onCompleted,
    required this.onRemove,
    required this.onOpen,
  });
  final int index;
  final Task task;
  final VoidCallback onCompleted;
  final VoidCallback onRemove;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done.value;
    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.only(right: 0),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Text('${index + 1}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.muted, fontWeight: FontWeight.w600)),
          ),
          TaskCheck(done: done, onChanged: (_) => onCompleted()),
          PriorityDot(TaskPriority.fromValue(task.priority)),
          const SizedBox(width: 6),
          Expanded(
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? AppColors.muted : null,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 15),
            tooltip: '移出今日重点',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _DueCard extends StatelessWidget {
  const _DueCard({
    required this.tasks,
    required this.focusedIds,
    required this.onCompleted,
    required this.onOpen,
    required this.onCreate,
  });
  final List<Task> tasks;
  final Set<String> focusedIds;
  final ValueChanged<Task> onCompleted;
  final ValueChanged<Task> onOpen;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final remaining = tasks.where((t) => !focusedIds.contains(t.id)).toList();
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(
            '到期与逾期',
            subtitle: '${remaining.length} 项未完成',
            trailing: IconButton(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 19),
              tooltip: '新建待办',
            ),
          ),
          const SizedBox(height: 6),
          if (remaining.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text('今天没有额外的到期任务',
                    style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
              ),
            )
          else
            for (final task in remaining.take(8))
              _DueRow(
                task: task,
                onCompleted: () => onCompleted(task),
                onOpen: () => onOpen(task),
              ),
          if (remaining.length > 8)
            TextButton(
              onPressed: () {},
              child: Text('还有 ${remaining.length - 8} 项，前往待办查看'),
            ),
        ],
      ),
    );
  }
}

class _DueRow extends StatelessWidget {
  const _DueRow({required this.task, required this.onCompleted, required this.onOpen});
  final Task task;
  final VoidCallback onCompleted;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final overdue = task.dueDate != null && task.dueDate!.compareTo(todayBusinessDate()) < 0;
    return Row(
      children: [
        TaskCheck(done: false, onChanged: (_) => onCompleted()),
        PriorityDot(TaskPriority.fromValue(task.priority)),
        const SizedBox(width: 6),
        Expanded(
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Text(task.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
            ),
          ),
        ),
        if (task.dueDate != null)
          Text(
            overdue ? '逾期' : (task.dueTime ?? '今天'),
            style: TextStyle(
              fontSize: 11,
              color: overdue ? AppColors.danger : AppColors.muted,
              fontWeight: overdue ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
      ],
    );
  }
}

class _ReviewEntry extends StatelessWidget {
  const _ReviewEntry({required this.date, required this.filled, required this.onOpen});
  final String date;
  final int filled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.blueSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.auto_awesome_outlined, size: 18, color: AppColors.blue),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('今日复盘', style: Theme.of(context).textTheme.titleMedium),
                    Text('3 个关键决策 + 1 个未想清楚的问题',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.muted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.muted),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: filled / 3,
              minHeight: 5,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Text('$filled / 3 个决策已记录',
              style: const TextStyle(fontSize: 11, color: AppColors.muted)),
        ],
      ),
    );
  }
}

class _YesterdayCandidates extends StatelessWidget {
  const _YesterdayCandidates({required this.date, required this.onAdd});
  final String date;
  final ValueChanged<Task> onAdd;

  @override
  Widget build(BuildContext context) {
    final yesterday = DateTime.parse(date).subtract(const Duration(days: 1));
    final yDate = businessDateOf(yesterday);
    return Consumer(builder: (context, ref, _) {
      return StreamBuilder<List<Task>>(
        stream: ref.watch(taskRepositoryProvider).watchFocusTasks(yDate),
        builder: (context, snapshot) {
          final rows = (snapshot.data ?? [])
              .where((t) => t.status != TaskStatus.done.value)
              .toList();
          if (rows.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionTitle('昨天未完成重点', subtitle: '由你决定是否继续，不自动占位'),
                  const SizedBox(height: 8),
                  for (final task in rows)
                    Row(
                      children: [
                        Expanded(
                          child: Text(task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5)),
                        ),
                        TextButton(onPressed: () => onAdd(task), child: const Text('加入今天')),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}
