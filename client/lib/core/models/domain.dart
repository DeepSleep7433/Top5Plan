enum TaskStatus {
  todo(0, '未开始'),
  doing(1, '进行中'),
  done(2, '已完成');

  const TaskStatus(this.value, this.label);
  final int value;
  final String label;

  static TaskStatus fromValue(int value) =>
      values.firstWhere((e) => e.value == value, orElse: () => todo);
}

enum TaskPriority {
  none(0, '无'),
  low(1, '低'),
  medium(2, '中'),
  high(3, '高');

  const TaskPriority(this.value, this.label);
  final int value;
  final String label;

  static TaskPriority fromValue(int value) =>
      values.firstWhere((e) => e.value == value, orElse: () => none);
}

enum IssueStatus {
  thinking(0, '待思考'),
  queued(1, '待集中处理'),
  resolved(2, '已解决'),
  archived(3, '已归档');

  const IssueStatus(this.value, this.label);
  final int value;
  final String label;

  static IssueStatus fromValue(int value) =>
      values.firstWhere((e) => e.value == value, orElse: () => thinking);
}

enum AiParticipation {
  none(0, '未使用'),
  assisted(1, '辅助分析'),
  primary(2, '主要依赖 AI'),
  mixed(3, '混合');

  const AiParticipation(this.value, this.label);
  final int value;
  final String label;

  static AiParticipation fromValue(int value) =>
      values.firstWhere((e) => e.value == value, orElse: () => none);
}

enum EntitySyncState { synced, pending, syncing, conflict, failed }

extension TaskStatusX on TaskStatus {
  bool get isDone => this == TaskStatus.done;
}

String todayBusinessDate([DateTime? now]) {
  final d = now ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime startOfLocalDay(DateTime d) => DateTime(d.year, d.month, d.day);

String businessDateOf(DateTime d) => todayBusinessDate(d);

String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
