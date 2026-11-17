import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/domain.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_service.dart';
import '../theme/app_theme.dart';

class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(syncSnapshotProvider);
    final snap = async.value ?? const SyncSnapshot();
    final (icon, label, color) = switch (snap.phase) {
      SyncPhase.pushing || SyncPhase.pulling || SyncPhase.bootstrap => (
          Icons.sync,
          '同步中',
          AppColors.blue
        ),
      SyncPhase.paused => (Icons.pause_circle_outline, '同步已暂停', AppColors.muted),
      SyncPhase.error => (Icons.cloud_off_outlined, '待重试', AppColors.warning),
      SyncPhase.offline => (Icons.cloud_off_outlined, '离线', AppColors.muted),
      _ when snap.pending > 0 => (Icons.cloud_upload_outlined, '已保存到本机', AppColors.warning),
      _ => (Icons.cloud_done_outlined, '已同步', AppColors.success),
    };
    return Tooltip(
      message: snap.lastError ??
          (snap.lastSyncedAt == null ? '本地优先，不等待网络' : '上次同步 ${_relative(snap.lastSyncedAt!)}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            if (!compact) ...[
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }

  String _relative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 10) return '刚刚';
    if (diff.inMinutes < 1) return '${diff.inSeconds} 秒前';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    return '${diff.inHours} 小时前';
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Material(
      color: color ?? Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: content,
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.muted)),
                ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 5),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.muted),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    );
  }
}

class PriorityDot extends StatelessWidget {
  const PriorityDot(this.priority, {super.key});
  final TaskPriority priority;

  @override
  Widget build(BuildContext context) {
    final color = switch (priority) {
      TaskPriority.high => AppColors.danger,
      TaskPriority.medium => AppColors.warning,
      TaskPriority.low => AppColors.blue,
      TaskPriority.none => Colors.transparent,
    };
    if (priority == TaskPriority.none) return const SizedBox(width: 10);
    return Tooltip(
      message: '优先级：${priority.label}',
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class TaskCheck extends StatelessWidget {
  const TaskCheck({
    super.key,
    required this.done,
    required this.onChanged,
    this.size = 19,
  });
  final bool done;
  final ValueChanged<bool?> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: Checkbox(
        value: done,
        onChanged: onChanged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        side: BorderSide(color: Theme.of(context).colorScheme.outline),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

Future<void> showError(BuildContext context, Object error) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(error.toString()),
    backgroundColor: AppColors.danger,
  ));
}

Future<void> showNotice(BuildContext context, String message) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String friendlyDate(String? date, {bool withWeekday = false}) {
  if (date == null || date.isEmpty) return '无日期';
  final d = DateTime.tryParse(date);
  if (d == null) return date;
  final today = DateTime.now();
  final diff = DateTime(d.year, d.month, d.day)
      .difference(DateTime(today.year, today.month, today.day))
      .inDays;
  final label = switch (diff) {
    0 => '今天',
    1 => '明天',
    -1 => '昨天',
    _ => '${d.month}月${d.day}日',
  };
  if (!withWeekday) return label;
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  return '$label · 周${weekdays[d.weekday - 1]}';
}
