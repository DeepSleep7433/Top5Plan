import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/task_picker.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});
  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  late String _date = ref.read(todayProvider);

  @override
  Widget build(BuildContext context) {
    final clock = ref.watch(clockProvider);
    final decisions = ref.watch(decisionsProvider(_date)).value ?? [];
    final review = ref.watch(dailyReviewProvider(_date)).value;
    final filled = decisions.where((d) => d.decisionText.trim().isNotEmpty).length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('每日复盘', style: Theme.of(context).textTheme.headlineLarge),
                          const SizedBox(height: 3),
                          Text('用约 5 分钟记录关键判断，不追求凑满',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: AppColors.muted)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => _changeDate(-1),
                      icon: const Icon(Icons.chevron_left),
                      tooltip: '前一天',
                    ),
                    TextButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event_outlined, size: 17),
                      label: Text('${_date.substring(5, 7)} 月 ${_date.substring(8, 10)} 日 · ${clock.weekday(_date)}'),
                    ),
                    IconButton(
                      onPressed: _date == clock.today() ? null : () => _changeDate(1),
                      icon: const Icon(Icons.chevron_right),
                      tooltip: '后一天',
                    ),
                    if (_date != clock.today())
                      TextButton(
                        onPressed: () => setState(() => _date = clock.today()),
                        child: const Text('回到今天'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _ReviewSummary(filled: filled, review: review),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          sliver: SliverList.list(
            children: [
              for (var slot = 1; slot <= 3; slot++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DecisionCard(
                    key: ValueKey('$_date-$slot'),
                    date: _date,
                    slot: slot,
                    initial: decisions.where((d) => d.slot == slot).firstOrNull,
                  ),
                ),
              _OpenQuestionCard(key: ValueKey('question-$_date'), date: _date),
              const SizedBox(height: 12),
              _ReflectionCard(
                key: ValueKey('reflection-$_date'),
                date: _date,
                initial: review,
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _changeDate(int days) async {
    setState(() => _date = businessDateOf(DateTime.parse(_date).add(Duration(days: days))));
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_date),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = businessDateOf(d));
  }
}

class _ReviewSummary extends StatelessWidget {
  const _ReviewSummary({required this.filled, required this.review});
  final int filled;
  final DailyReview? review;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      color: AppColors.blueSoft.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.lightbulb_outline, size: 20, color: AppColors.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              filled == 0
                  ? '今天可以记录 1–3 个真正影响行动的判断；留空也完全没问题。'
                  : '已记录 $filled 个关键决策${review == null ? '' : '，并写下今日 AI 反思'}。',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _DecisionCard extends ConsumerStatefulWidget {
  const _DecisionCard({
    super.key,
    required this.date,
    required this.slot,
    this.initial,
  });
  final String date;
  final int slot;
  final Decision? initial;

  @override
  ConsumerState<_DecisionCard> createState() => _DecisionCardState();
}

class _DecisionCardState extends ConsumerState<_DecisionCard> {
  late final TextEditingController _decision;
  late final TextEditingController _rationale;
  late final TextEditingController _reflection;
  late AiParticipation _participation;
  String? _taskId;
  String? _issueId;
  bool _saving = false;
  bool _showReflection = false;

  @override
  void initState() {
    super.initState();
    _decision = TextEditingController(text: widget.initial?.decisionText ?? '');
    _rationale = TextEditingController(text: widget.initial?.rationale ?? '');
    _reflection = TextEditingController(text: widget.initial?.outcomeReflection ?? '');
    _participation = AiParticipation.fromValue(widget.initial?.aiParticipation ?? 0);
    _taskId = widget.initial?.linkedTaskId;
    _issueId = widget.initial?.linkedIssueId;
  }

  @override
  void dispose() {
    _decision.dispose();
    _rationale.dispose();
    _reflection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = _decision.text.trim().isNotEmpty;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: filled ? AppColors.blue : Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text('${widget.slot}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: filled ? Colors.white : AppColors.muted)),
              ),
              const SizedBox(width: 9),
              Text('关键决策 ${widget.slot}', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (widget.initial != null)
                TextButton(
                  onPressed: () => setState(() => _showReflection = !_showReflection),
                  child: Text(_showReflection ? '收起回看' : '补充结果/反思'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _decision,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '我做出了什么决定',
              hintText: '可以留空；只记真正关键的决定',
            ),
          ),
          const SizedBox(height: 9),
          TextField(
            controller: _rationale,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '我当时为什么这样判断',
              hintText: '当时的依据、权衡、担忧或直觉',
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<AiParticipation>(
                  initialValue: _participation,
                  decoration: const InputDecoration(labelText: 'AI 是否参与'),
                  items: [
                    for (final v in AiParticipation.values)
                      DropdownMenuItem(value: v, child: Text(v.label)),
                  ],
                  onChanged: (v) => setState(() => _participation = v ?? AiParticipation.none),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _pickTask,
                icon: const Icon(Icons.link, size: 15),
                label: Text(_taskId == null ? '关联任务' : '已关联任务'),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: _pickIssue,
                icon: const Icon(Icons.help_outline, size: 15),
                label: Text(_issueId == null ? '关联问题' : '已关联问题'),
              ),
            ],
          ),
          if (_showReflection) ...[
            const SizedBox(height: 9),
            TextField(
              controller: _reflection,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '后续回看：结果与反思',
                hintText: '过一段时间再补充，不必现在填',
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if ((_taskId != null || _issueId != null) && !_showReflection)
                TextButton(
                  onPressed: () => setState(() {
                    _taskId = null;
                    _issueId = null;
                  }),
                  child: const Text('清除关联'),
                ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.initial == null ? '保存此决策' : '保存修改'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickTask() async {
    final t = await showTaskPicker(context, ref, title: '关联任务');
    if (t != null) setState(() => _taskId = t.id);
  }

  Future<void> _pickIssue() async {
    final issues = await ref.read(taskRepositoryProvider).watchIssues().first;
    if (!mounted) return;
    final picked = await showDialog<Issue>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('关联问题'),
        children: [
          for (final i in issues)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Text(i.title),
            ),
        ],
      ),
    );
    if (picked != null) setState(() => _issueId = picked.id);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(taskRepositoryProvider).saveDecision(
            date: widget.date,
            slot: widget.slot,
            decisionText: _decision.text.trim(),
            rationale: _rationale.text.trim(),
            participation: _participation,
            linkedTaskId: _taskId,
            linkedIssueId: _issueId,
            outcomeReflection: _reflection.text.trim(),
          );
      if (mounted) await showNotice(context, '决策已保存到本机');
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _OpenQuestionCard extends ConsumerStatefulWidget {
  const _OpenQuestionCard({super.key, required this.date});
  final String date;

  @override
  ConsumerState<_OpenQuestionCard> createState() => _OpenQuestionCardState();
}

class _OpenQuestionCardState extends ConsumerState<_OpenQuestionCard> {
  final _title = TextEditingController();
  final _judgment = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  String get _id => const Uuid().v5(Namespace.url.value, 't5:daily-question:${widget.date}');

  @override
  void dispose() {
    _title.dispose();
    _judgment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Issue?>(
      stream: ref.watch(taskRepositoryProvider).watchIssue(_id),
      builder: (context, snapshot) {
        final issue = snapshot.data;
        if (!_loaded && issue != null) {
          _title.text = issue.title;
          _judgment.text = issue.initialJudgment;
          _loaded = true;
        }
        return SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle(
                '一个还没想清楚的问题',
                subtitle: '记录它，不必现在调用 AI；之后去问题箱集中处理',
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '问题',
                  hintText: '例如：这个项目继续投入的判断标准是什么？',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _judgment,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '我的初步判断（可选）',
                  hintText: '先写下自己的直觉和依据',
                ),
              ),
              const SizedBox(height: 9),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () async {
                      final id = _id;
                      final issue = await ref.read(taskRepositoryProvider).getIssue(id);
                      if (issue != null && context.mounted) {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('问题详情')),
                            body: Center(child: Text(issue.title)),
                          ),
                        ));
                      }
                    },
                    child: const Text('查看问题箱'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('保存问题'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      await showNotice(context, '先写下问题，哪怕只有一句');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(taskRepositoryProvider).saveDailyOpenQuestion(
            date: widget.date,
            title: _title.text,
            initialJudgment: _judgment.text,
          );
      if (mounted) await showNotice(context, '已保存到问题箱');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ReflectionCard extends ConsumerStatefulWidget {
  const _ReflectionCard({super.key, required this.date, this.initial});
  final String date;
  final DailyReview? initial;

  @override
  ConsumerState<_ReflectionCard> createState() => _ReflectionCardState();
}

class _ReflectionCardState extends ConsumerState<_ReflectionCard> {
  late final TextEditingController _helped;
  late final TextEditingController _overreliance;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _helped = TextEditingController(text: widget.initial?.aiHelped ?? '');
    _overreliance = TextEditingController(text: widget.initial?.aiOverreliance ?? '');
  }

  @override
  void dispose() {
    _helped.dispose();
    _overreliance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('每日 AI 反思', subtitle: '由你自己记录，不根据调用次数推断依赖程度'),
          const SizedBox(height: 10),
          TextField(
            controller: _helped,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '今天 AI 帮我完成了什么？',
              hintText: '具体到任务或判断，不必评价好坏',
            ),
          ),
          const SizedBox(height: 9),
          TextField(
            controller: _overreliance,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '今天哪些地方，我把本应自己完成的思考交给了 AI？',
              hintText: '如果没有，可以留空',
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存反思'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(taskRepositoryProvider).saveDailyReview(
            date: widget.date,
            aiHelped: _helped.text.trim(),
            aiOverreliance: _overreliance.text.trim(),
          );
      if (mounted) await showNotice(context, '反思已保存到本机');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
