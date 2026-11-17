import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/api/api_client.dart';
import '../../core/db/database.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class IssuesScreen extends ConsumerStatefulWidget {
  const IssuesScreen({super.key});
  @override
  ConsumerState<IssuesScreen> createState() => _IssuesScreenState();
}

class _IssuesScreenState extends ConsumerState<IssuesScreen> {
  final _quick = TextEditingController();
  final _search = TextEditingController();
  int? _status;
  String _query = '';
  Set<String> _selected = {};
  bool _selecting = false;

  @override
  void dispose() {
    _quick.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stream = ref.watch(taskRepositoryProvider).watchIssues(
          status: _status == null ? null : IssueStatus.fromValue(_status!),
        );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('问题箱', style: Theme.of(context).textTheme.headlineLarge),
                        const SizedBox(height: 3),
                        Text('遇到问题先记下，在固定时间集中处理；不必立刻调用 AI',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.muted)),
                      ],
                    ),
                  ),
                  const SyncStatusChip(),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _editIssue(null),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建问题'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.help_outline, size: 19, color: AppColors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _quick,
                        onSubmitted: (_) => _quickAdd(),
                        decoration: const InputDecoration(
                          hintText: '随手记下一个问题，只需标题也能保存',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                    FilledButton(onPressed: _quickAdd, child: const Text('保存')),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _status == null,
                    onSelected: (_) => setState(() => _status = null),
                  ),
                  for (final s in IssueStatus.values)
                    ChoiceChip(
                      label: Text(s.label),
                      selected: _status == s.value,
                      onSelected: (_) => setState(() => _status = s.value),
                    ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 210,
                    child: TextField(
                      controller: _search,
                      onChanged: (v) => setState(() => _query = v.trim()),
                      decoration: const InputDecoration(
                        hintText: '搜索问题',
                        prefixIcon: Icon(Icons.search, size: 17),
                      ),
                    ),
                  ),
                  if (_selecting)
                    TextButton(
                      onPressed: () => setState(() {
                        _selecting = false;
                        _selected.clear();
                      }),
                      child: const Text('取消批量'),
                    )
                  else
                    TextButton.icon(
                      onPressed: () => setState(() => _selecting = true),
                      icon: const Icon(Icons.checklist, size: 16),
                      label: const Text('批量处理'),
                    ),
                ],
              ),
              if (_selecting)
                Container(
                  margin: const EdgeInsets.only(top: 9),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.blueSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Text('已选 ${_selected.length} 个问题',
                          style: const TextStyle(color: AppColors.blue, fontSize: 12.5)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _selected.isEmpty ? null : _openAssist,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('生成集中提问'),
                      ),
                      TextButton.icon(
                        onPressed: _selected.isEmpty ? null : _batchResolve,
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('标记已解决'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Issue>>(
            stream: stream,
            builder: (context, snapshot) {
              var issues = snapshot.data ?? [];
              if (_query.isNotEmpty) {
                issues = issues
                    .where((i) =>
                        i.title.contains(_query) ||
                        i.context.contains(_query) ||
                        i.initialJudgment.contains(_query))
                    .toList();
              }
              if (issues.isEmpty) {
                return const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '问题箱是空的',
                  message: '把还没想清楚的问题先记下来，之后再集中处理',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                itemCount: issues.length,
                itemBuilder: (context, index) {
                  final issue = issues[index];
                  return _IssueRow(
                    issue: issue,
                    selected: _selected.contains(issue.id),
                    selecting: _selecting,
                    onSelect: () => setState(() {
                      if (!_selected.add(issue.id)) _selected.remove(issue.id);
                    }),
                    onOpen: () => _editIssue(issue),
                    onAssist: () {
                      setState(() => _selected = {issue.id});
                      _openAssist();
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _quickAdd() async {
    if (_quick.text.trim().isEmpty) return;
    await ref.read(taskRepositoryProvider).createIssue(title: _quick.text);
    _quick.clear();
  }

  Future<void> _editIssue(Issue? issue) async {
    final title = TextEditingController(text: issue?.title ?? '');
    final contextText = TextEditingController(text: issue?.context ?? '');
    final judgment = TextEditingController(text: issue?.initialJudgment ?? '');
    var status = IssueStatus.fromValue(issue?.status ?? 0);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(issue == null ? '记录问题' : '问题详情'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: issue == null,
                    decoration: const InputDecoration(labelText: '问题标题'),
                  ),
                  const SizedBox(height: 9),
                  TextField(
                    controller: contextText,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(labelText: '补充背景'),
                  ),
                  const SizedBox(height: 9),
                  TextField(
                    controller: judgment,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '我的初步判断',
                      hintText: '先写自己的判断；允许跳过',
                    ),
                  ),
                  const SizedBox(height: 9),
                  DropdownButtonFormField<IssueStatus>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: '状态'),
                    items: [
                      for (final s in IssueStatus.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                    onChanged: (v) => setLocal(() => status = v ?? IssueStatus.thinking),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                if (issue == null) {
                  await ref.read(taskRepositoryProvider).createIssue(
                        title: title.text,
                        context: contextText.text,
                        initialJudgment: judgment.text,
                        status: status,
                      );
                } else {
                  await ref.read(taskRepositoryProvider).updateIssue(issue.copyWith(
                    title: title.text.trim(),
                    context: contextText.text,
                    initialJudgment: judgment.text,
                    status: status.value,
                    resolvedAt: Value(status == IssueStatus.resolved ? (issue.resolvedAt ?? DateTime.now().toUtc()) : null),
                  ));
                }
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    contextText.dispose();
    judgment.dispose();
    if (saved == true) {
      // The underlying watch stream refreshes automatically.
    }
  }

  Future<void> _batchResolve() async {
    for (final id in _selected.toList()) {
      await ref.read(taskRepositoryProvider).setIssueStatus(id, IssueStatus.resolved);
    }
    setState(() => _selected.clear());
  }

  Future<void> _openAssist() async {
    final issues = <Issue>[];
    for (final id in _selected) {
      final i = await ref.read(taskRepositoryProvider).getIssue(id);
      if (i != null) issues.add(i);
    }
    if (issues.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AIAssistDialog(issues: issues),
    );
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({
    required this.issue,
    required this.selected,
    required this.selecting,
    required this.onSelect,
    required this.onOpen,
    required this.onAssist,
  });
  final Issue issue;
  final bool selected;
  final bool selecting;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final VoidCallback onAssist;

  @override
  Widget build(BuildContext context) {
    final status = IssueStatus.fromValue(issue.status);
    final color = switch (status) {
      IssueStatus.thinking => AppColors.warning,
      IssueStatus.queued => AppColors.blue,
      IssueStatus.resolved => AppColors.success,
      IssueStatus.archived => AppColors.muted,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? AppColors.blueSoft.withValues(alpha: 0.5) : null,
      child: InkWell(
        onTap: selecting ? onSelect : onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          child: Row(
            children: [
              if (selecting)
                Checkbox(value: selected, onChanged: (_) => onSelect())
              else
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(issue.title,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                    if (issue.initialJudgment.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('我的判断：${issue.initialJudgment}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                      ),
                  ],
                ),
              ),
              StatusPill(label: status.label, color: color),
              const SizedBox(width: 6),
              IconButton(
                onPressed: onAssist,
                icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                tooltip: '用 AI 协助分析',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AIAssistDialog extends ConsumerStatefulWidget {
  const AIAssistDialog({super.key, required this.issues});
  final List<Issue> issues;

  @override
  ConsumerState<AIAssistDialog> createState() => _AIAssistDialogState();
}

class _AIAssistDialogState extends ConsumerState<AIAssistDialog> {
  final _instruction = TextEditingController();
  final _judgment = TextEditingController();
  Map<String, dynamic>? _preview;
  Map<String, dynamic>? _job;
  String? _error;
  bool _previewing = false;
  bool _submitting = false;
  bool _savingJudgment = false;

  @override
  void dispose() {
    _instruction.dispose();
    _judgment.dispose();
    super.dispose();
  }

  List<Map<String, String>> get _sources => [
        for (final i in widget.issues) {'entity_type': 'issue', 'entity_id': i.id},
      ];

  @override
  Widget build(BuildContext context) {
    final status = _job?['status']?.toString();
    final result = _job?['result_text']?.toString() ?? '';
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 780),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 20, color: AppColors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('集中处理问题', style: Theme.of(context).textTheme.titleLarge),
                        Text('先看自己的判断，再决定是否发送给 AI',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.muted)),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 19)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionTitle('发送范围', subtitle: '只包含下面这些已同步到服务器的记录'),
                    const SizedBox(height: 8),
                    for (final i in widget.issues)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(i.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                            if (i.initialJudgment.isNotEmpty)
                              Text('我的初步判断：${i.initialJudgment}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _judgment,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '我自己的初步判断（可跳过，会先保存到第一个问题）',
                        hintText: '不强制填写，也不阻止你继续使用',
                      ),
                    ),
                    const SizedBox(height: 9),
                    TextField(
                      controller: _instruction,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '希望 AI 帮你分析什么（可选）',
                        hintText: '例如：找出我论证中的漏洞，并给出可验证的下一步',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _previewing ? null : _loadPreview,
                          icon: const Icon(Icons.visibility_outlined, size: 17),
                          label: const Text('预览发送内容'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _preview == null
                              ? null
                              : () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: _preview!['prompt']?.toString() ?? ''));
                                  if (context.mounted) await showNotice(context, '提问文本已复制');
                                },
                          icon: const Icon(Icons.copy, size: 17),
                          label: const Text('复制到外部 AI'),
                        ),
                        FilledButton.icon(
                          onPressed: _submitting || _preview == null ? null : _submit,
                          icon: const Icon(Icons.send_outlined, size: 17),
                          label: const Text('在应用内调用 AI'),
                        ),
                      ],
                    ),
                    if (_preview != null) ...[
                      const SizedBox(height: 14),
                      SectionCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('预览 · ${_preview!['source_count']} 条来源 · ${_preview!['prompt_chars']} 字符',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 7),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 220),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  _preview!['prompt']?.toString() ?? '',
                                  style: const TextStyle(fontSize: 11.5, height: 1.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_job != null) ...[
                      const SizedBox(height: 16),
                      _JobStatus(
                        job: _job!,
                        onRefresh: status == 'queued' || status == 'running' ? _pollOnce : null,
                      ),
                      if (status == 'completed' && result.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: SectionTitle('AI 结果', subtitle: '结果不会自动修改任何记录'),
                                  ),
                                  Text('${_job!['model'] ?? ''}',
                                      style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              MarkdownBody(data: result, selectable: true),
                              const Divider(height: 24),
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () => _adoptTask(result),
                                    icon: const Icon(Icons.add_task, size: 17),
                                    label: const Text('采纳为任务'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () => _adoptDecision(result),
                                    icon: const Icon(Icons.lightbulb_outline, size: 17),
                                    label: const Text('采纳为决策'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.danger.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveJudgmentIfAny() async {
    if (_judgment.text.trim().isEmpty || widget.issues.isEmpty) return;
    _savingJudgment = true;
    final first = widget.issues.first;
    await ref.read(taskRepositoryProvider).updateIssue(
          first.copyWith(initialJudgment: _judgment.text.trim()),
        );
    _savingJudgment = false;
  }

  Future<void> _loadPreview() async {
    setState(() {
      _previewing = true;
      _error = null;
    });
    try {
      await _saveJudgmentIfAny();
      final api = ref.read(apiClientProvider);
      final out = await api.previewAssist(_instruction.text.trim(), _sources);
      if (mounted) setState(() => _preview = out);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.code == 'source_not_available'
            ? '选中记录尚未同步到服务器，请先等待同步完成。'
            : e.message);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _saveJudgmentIfAny();
      final api = ref.read(apiClientProvider);
      final job = await api.createAIJob(
        instruction: _instruction.text.trim(),
        sources: _sources,
      );
      if (!mounted) return;
      setState(() => _job = job);
      _pollJob(job['id'].toString());
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = switch (e.code) {
              'ai_not_configured' => '服务器尚未配置并启用 AI 模型。基础功能仍可正常使用。',
              'daily_limit' => '已达到今天的 AI 调用上限。',
              'source_not_available' => '记录尚未同步到服务器。',
              _ => e.message,
            });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _pollJob(String id) async {
    for (var i = 0; i < 90; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final job = await ref.read(apiClientProvider).getAIJob(id);
        if (!mounted) return;
        setState(() => _job = job);
        final s = job['status'];
        if (s == 'completed' || s == 'failed' || s == 'uncertain') return;
      } on ApiException catch (e) {
        if (!mounted) return;
        setState(() => _error = e.message);
        return;
      }
    }
  }

  Future<void> _pollOnce() async {
    final id = _job?['id']?.toString();
    if (id == null) return;
    try {
      final job = await ref.read(apiClientProvider).getAIJob(id);
      if (mounted) setState(() => _job = job);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _adoptTask(String result) async {
    final firstLine = result
        .split('\n')
        .map((e) => e.replaceAll(RegExp(r'^[#>\-*\s]+'), '').trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => 'AI 建议的行动');
    await ref.read(taskRepositoryProvider).createTask(
          title: firstLine.length > 80 ? firstLine.substring(0, 80) : firstLine,
          notes: '来自 AI 辅助结果（已由用户手动采纳）\n\n$result',
          dueDate: ref.read(todayProvider),
        );
    if (mounted) {
      await showNotice(context, '已创建任务。AI 没有修改原始问题。');
    }
  }

  Future<void> _adoptDecision(String result) async {
    final firstLine = result
        .split('\n')
        .map((e) => e.replaceAll(RegExp(r'^[#>\-*\s]+'), '').trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => 'AI 辅助后的判断');
    await ref.read(taskRepositoryProvider).saveDecision(
          date: ref.read(todayProvider),
          slot: 1,
          decisionText: firstLine.length > 120 ? firstLine.substring(0, 120) : firstLine,
          rationale: '用户明确采纳的 AI 辅助建议；原始问题保留。',
          participation: AiParticipation.assisted,
          linkedIssueId: widget.issues.length == 1 ? widget.issues.first.id : null,
          outcomeReflection: result,
        );
    if (mounted) {
      await showNotice(context, '已保存为今日决策草稿。原始记录未被自动修改。');
    }
  }
}

class _JobStatus extends StatelessWidget {
  const _JobStatus({required this.job, this.onRefresh});
  final Map<String, dynamic> job;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final status = job['status']?.toString() ?? 'queued';
    final (label, color, icon) = switch (status) {
      'queued' => ('排队中', AppColors.warning, Icons.schedule),
      'running' => ('AI 正在处理', AppColors.blue, Icons.sync),
      'completed' => ('已完成', AppColors.success, Icons.check_circle_outline),
      'uncertain' => ('结果不确定', AppColors.warning, Icons.help_outline),
      _ => ('失败', AppColors.danger, Icons.error_outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status == 'uncertain'
                  ? '${job['error_message'] ?? '无法确认供应商是否已处理；未自动重试。'}'
                  : status == 'failed'
                      ? '${job['error_code'] ?? '失败'}：${job['error_message'] ?? ''}'
                      : label,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
          if (onRefresh != null)
            IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh, size: 17)),
        ],
      ),
    );
  }
}
