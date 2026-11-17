import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../theme/app_theme.dart';
import 'common.dart';

class ReportsDialog extends ConsumerStatefulWidget {
  const ReportsDialog({super.key});
  @override
  ConsumerState<ReportsDialog> createState() => _ReportsDialogState();
}

class _ReportsDialogState extends ConsumerState<ReportsDialog> {
  Map<String, dynamic>? _selected;
  String _kind = 'daily';
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(apiClientProvider).listReports(kind: _kind, limit: 30);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: SectionTitle('自动复盘版本',
                        subtitle: '原始记录与 AI 报告分开保存；重新生成会保留旧版本'),
                  ),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'daily', label: Text('日报')),
                      ButtonSegment(value: 'weekly', label: Text('周报')),
                    ],
                    selected: {_kind},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) {
                      setState(() {
                        _kind = v.first;
                        _selected = null;
                        _future = ref.read(apiClientProvider).listReports(kind: _kind, limit: 30);
                      });
                    },
                  ),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<Map<String, dynamic>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                  }
                  final reports = ((snapshot.data?['reports'] as List?) ?? const [])
                      .cast<Map<String, dynamic>>();
                  if (reports.isEmpty) {
                    return const EmptyState(
                      icon: Icons.article_outlined,
                      title: '还没有自动复盘',
                      message: '在服务器设置中启用日报或周报后，服务器会在设定时间生成',
                    );
                  }
                  if (_selected == null) {
                    return ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        for (final r in reports)
                          ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: Text(
                                '${r['kind'] == 'weekly' ? '周报' : '日报'} · ${r['id'].toString().substring(0, 8)}'),
                            subtitle: Text(
                              '数据截止 ${r['data_cutoff']} · 生成于 ${r['created_at']}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => setState(() => _selected = r),
                          ),
                      ],
                    );
                  }
                  final r = _selected!;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: () => setState(() => _selected = null),
                              icon: const Icon(Icons.arrow_back, size: 16),
                              label: const Text('返回列表'),
                            ),
                            const Spacer(),
                            finalSources(r),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () => _regenerate(r),
                              icon: const Icon(Icons.refresh, size: 15),
                              label: const Text('重新生成'),
                            ),
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
                              Wrap(
                                spacing: 10,
                                runSpacing: 4,
                                children: [
                                  Text('周期 ${r['period_start']} — ${r['period_end']}',
                                      style: const TextStyle(
                                          fontSize: 10.5, color: AppColors.muted)),
                                  Text('数据截止 ${r['data_cutoff']}',
                                      style: const TextStyle(
                                          fontSize: 10.5, color: AppColors.muted)),
                                  Text('来源 ${((r['sources'] as List?) ?? const []).length} 条',
                                      style: const TextStyle(
                                          fontSize: 10.5, color: AppColors.muted)),
                                ],
                              ),
                              const SizedBox(height: 10),
                              ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                title: const Text('查看来源记录 ID', style: TextStyle(fontSize: 12)),
                                children: [
                                  for (final src in ((r['sources'] as List?) ?? const []))
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        '${(src as Map)['entity_type']} · ${src['entity_id']}',
                                        style: const TextStyle(
                                            fontSize: 10.5, fontFamily: 'Consolas'),
                                      ),
                                    ),
                                ],
                              ),
                              const Divider(height: 20),
                              MarkdownBody(
                                data: r['result_text']?.toString() ?? '',
                                selectable: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget finalSources(Map<String, dynamic> report) {
    final count = ((report['sources'] as List?) ?? const []).length;
    return Text('$count 条来源',
        style: const TextStyle(fontSize: 10.5, color: AppColors.muted));
  }

  Future<void> _regenerate(Map<String, dynamic> report) async {
    try {
      await ref.read(apiClientProvider).regenerateReport(report['id'].toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已排队重新生成；旧报告版本会保留')),
        );
        setState(() {
          _selected = null;
          _future = ref.read(apiClientProvider).listReports(kind: _kind, limit: 30);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重新生成失败：$e')));
      }
    }
  }
}
